import AVFoundation
import AppKit
import SwiftUI

// MARK: - Model

/// The four parts Demucs splits a song into.
enum StemKind: Int, CaseIterable, Identifiable {
    case vocals, drums, bass, other
    var id: Int { rawValue }
    var file: String { ["vocals", "drums", "bass", "other"][rawValue] }
    var name: String { ["Vocals", "Drums", "Bass", "Instruments"][rawValue] }
    var symbol: String { ["music.mic", "light.beacon.max", "guitars", "pianokeys"][rawValue] }
    var color: Color {
        [Color(red: 1.0, green: 0.42, blue: 0.62), Color(red: 1.0, green: 0.66, blue: 0.25),
         Color(red: 0.32, green: 0.62, blue: 1.0), Color(red: 0.66, green: 0.48, blue: 1.0)][rawValue]
    }
}

/// Where one part sits: direction, how wide its stereo spreads, level, and whether it circles you.
struct StemPlacement: Equatable {
    var az: Double       // degrees, positive = left
    var el: Double       // degrees, positive = up
    var width: Double    // angle between its left and right channel
    var gain: Double = 1
    var orbit: Double = 0  // degrees per second
    var muted = false

    var spec: String {
        String(format: "%.1f:%.1f:%.1f:%.3f:%.1f", az, el, width, muted ? 0 : gain, orbit)
    }
}

enum MusicPreset: String, CaseIterable, Identifiable {
    case stage, frontRow, inside, orbit, sky
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stage: "On Stage"
        case .frontRow: "Front Row"
        case .inside: "Inside the Band"
        case .orbit: "Orbit"
        case .sky: "Sky"
        }
    }
    var detail: String {
        switch self {
        case .stage: "The band in front of you, the singer centre stage."
        case .frontRow: "Close and wide, like the front of a small club."
        case .inside: "Drums behind you, bass and instruments at your sides."
        case .orbit: "Drums and instruments slowly circle around you."
        case .sky: "Instruments float overhead, drums all around you."
        }
    }
    /// vocals, drums, bass, other
    var placements: [StemPlacement] {
        switch self {
        // like a real stage: singer front centre, drums on the riser behind, bass and the other
        // instruments either side
        case .stage: [.init(az: 0, el: 6, width: 20), .init(az: 0, el: 30, width: 70), .init(az: -30, el: -4, width: 25), .init(az: 34, el: 8, width: 90)]
        case .frontRow: [.init(az: 0, el: 4, width: 15), .init(az: 0, el: 20, width: 110), .init(az: -40, el: -6, width: 35), .init(az: 45, el: 10, width: 150)]
        case .inside: [.init(az: 0, el: 0, width: 15), .init(az: 180, el: 5, width: 110), .init(az: -100, el: -5, width: 30), .init(az: 95, el: 10, width: 70)]
        case .orbit: [.init(az: 0, el: 8, width: 20), .init(az: 0, el: 0, width: 60, orbit: 24), .init(az: 0, el: -6, width: 30), .init(az: 180, el: 30, width: 90, orbit: -16)]
        case .sky: [.init(az: 0, el: 10, width: 20), .init(az: 0, el: 0, width: 300), .init(az: 0, el: -10, width: 40), .init(az: 0, el: 70, width: 120)]
        }
    }
}

// MARK: - Separation engine

/// The private Python with Demucs that splits songs (installed on first use with uv).
enum StemsEngine {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spatialize/stems")
    }
    static var python: URL { folder.appendingPathComponent("bin/python") }
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    static var uv: URL? {
        let candidates = [Engine.root.appendingPathComponent("bin/uv").path,
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path,
                          "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Runs a tool and hands each line of its output to `onLine` on the main actor.
@MainActor
final class LineRunner {
    private var process: Process?
    var isRunning: Bool { process?.isRunning == true }

    func run(_ tool: URL, _ args: [String], env extra: [String: String] = [:],
             onLine: @escaping @MainActor (String) -> Void, done: @escaping @MainActor (Int32) -> Void) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Engine.root.path)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        extra.forEach { env[$0.key] = $0.value }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                buffer += text.replacingOccurrences(of: "\r", with: "\n")
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    if !line.isEmpty { onLine(line) }
                }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            let s = proc.terminationStatus
            Task { @MainActor in done(s) }
        }
        do { try p.run(); process = p } catch { done(-1) }
    }

    func stop() { if let p = process, p.isRunning { p.terminate() } }
}

// MARK: - Session

/// One song: separating it, placing its parts, hearing it live, exporting Spatial Audio.
@MainActor
final class MusicSession: ObservableObject {
    enum Phase: Equatable { case needsEngine, installing, separating, ready, failed(String) }
    enum Export: Equatable { case idle, running, done(URL), failed(String) }

    let url: URL
    let title: String
    let artist: String?
    let artwork: NSImage?
    let duration: Double

    @Published var phase: Phase = .needsEngine
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var log: [String] = []
    @Published var placements: [StemPlacement] = MusicPreset.stage.placements
    @Published var preset: MusicPreset? = .stage
    @Published var export: Export = .idle
    @Published var exportProgress: Double = 0
    @Published var player: StemPlayer?
    private(set) var stemsDir: URL?
    private let runner = LineRunner()

    init(url: URL, duration: Double) async {
        self.url = url
        self.duration = duration
        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else { return nil }
            return try? await item.load(.stringValue)
        }
        title = await string(.commonIdentifierTitle) ?? url.deletingPathExtension().lastPathComponent
        artist = await string(.commonIdentifierArtist)
        if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue) {
            artwork = NSImage(data: data)
        } else {
            artwork = nil
        }
    }

    var spec: String { placements.map(\.spec).joined(separator: ";") }

    func begin() {
        if StemsEngine.installed { separate() } else { phase = .needsEngine }
    }

    func apply(_ p: MusicPreset) {
        var next = p.placements
        for i in next.indices { next[i].muted = placements[i].muted; next[i].gain = placements[i].gain }
        placements = next
        preset = p
        player?.restartClock()
    }

    func edited() { preset = nil }

    // MARK: install

    func installEngine() {
        guard let uv = StemsEngine.uv else {
            phase = .failed("Spatialize needs uv to install the separation engine. Install it with: brew install uv")
            return
        }
        phase = .installing
        status = "Setting up Python"
        log = []
        let env = StemsEngine.folder.path
        try? FileManager.default.createDirectory(at: StemsEngine.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        runner.run(uv, ["venv", "--python", "3.11", env], onLine: { [weak self] in self?.log.append($0) }) { [weak self] code in
            guard let self else { return }
            guard code == 0 else { self.phase = .failed("Couldn't set up Python (uv exit \(code))."); return }
            self.status = "Downloading Demucs and PyTorch (about 700 MB)"
            self.runner.run(uv, ["pip", "install", "--python", StemsEngine.python.path, "demucs", "soundfile"],
                            onLine: { [weak self] line in
                                self?.log.append(line)
                                if line.contains("Downloading") || line.contains("Downloaded") || line.contains("Installed") {
                                    self?.status = line.trimmingCharacters(in: .whitespaces)
                                }
                            }) { [weak self] code in
                guard let self else { return }
                if code == 0 && StemsEngine.installed { self.separate() }
                else { self.phase = .failed("Installing the separation engine failed. Check your internet connection and try again.") }
            }
        }
    }

    // MARK: separate

    func separate() {
        phase = .separating
        progress = 0
        status = "Starting"
        runner.run(URL(fileURLWithPath: "/bin/zsh"),
                   [Engine.root.appendingPathComponent("music2spatial").path, url.path, "--separate-only", "--progress"],
                   onLine: { [weak self] line in self?.handle(line) }) { [weak self] code in
            guard let self, self.phase == .separating else { return }
            if code == 0, let dir = self.stemsDir { self.loadPlayer(dir) }
            else { self.phase = .failed(self.log.last(where: { !$0.hasPrefix("@") }) ?? "Separation failed.") }
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "@stage" where parts.count == 3: status = parts[2]
        case "@progress" where parts.count == 3:
            let v = Double(parts[2]) ?? 0
            if parts[1] == "stems" { progress = max(progress, v) } else { exportProgress = max(exportProgress, v) }
        case "@stems" where parts.count >= 2: stemsDir = URL(fileURLWithPath: String(line.dropFirst("@stems ".count)))
        case "@error": log.append(String(line.dropFirst(7)))
        default: if !line.hasPrefix("@") { log.append(line); if log.count > 300 { log.removeFirst() } }
        }
    }

    private func loadPlayer(_ dir: URL) {
        status = "Preparing the live player"
        Task {
            do {
                let p = try await StemPlayer.make(stems: dir, session: self)
                self.player = p
                self.phase = .ready
            } catch {
                self.phase = .failed("Couldn't open the separated parts: \(error.localizedDescription)")
            }
        }
    }

    // MARK: export

    func exportURL(folder: URL?) -> URL {
        let dir = folder ?? url.deletingLastPathComponent()
        return dir.appendingPathComponent("\(title) · Spatial.m4a")
    }

    func exportSpatial(to out: URL, hrtf: String) {
        export = .running
        exportProgress = 0
        let exporter = LineRunner()
        exporter.run(URL(fileURLWithPath: "/bin/zsh"),
                     [Engine.root.appendingPathComponent("music2spatial").path, url.path, out.path,
                      "--stems", spec, "--hrtf", hrtf, "--progress"],
                     onLine: { [weak self] line in self?.handle(line) }) { [weak self] code in
            guard let self else { return }
            self.export = code == 0 ? .done(out) : .failed(self.log.last(where: { !$0.hasPrefix("@") }) ?? "Export failed.")
            _ = exporter
        }
    }

    func close() {
        runner.stop()
        player?.stop()
    }
}

// MARK: - Live player

/// Plays the separated parts around your head with Apple's head model and AirPods head tracking.
/// Each part's left and right channel is its own source, so a part can be wide or a point.
@MainActor
final class StemPlayer: ObservableObject {
    @Published var playing = false
    @Published var position: Double = 0
    let duration: Double
    let head = HeadTracker()

    private let engine = AVAudioEngine()
    private let env = AVAudioEnvironmentNode()
    private var nodes: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []          // mono: vocals L, vocals R, drums L, …
    private let rate: Double
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private weak var session: MusicSession?
    /// Time the orbit motion is measured from (restarts with a preset so it begins where shown).
    private var clockZero: Double = 0

    /// Splits each stereo stem into two mono files once (kept next to the stems), then builds the graph.
    static func make(stems dir: URL, session: MusicSession) async throws -> StemPlayer {
        let monos = try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
            var out: [URL] = []
            for kind in StemKind.allCases {
                let src = dir.appendingPathComponent("\(kind.file).wav")
                let l = dir.appendingPathComponent("\(kind.file).L.caf"), r = dir.appendingPathComponent("\(kind.file).R.caf")
                if !FileManager.default.fileExists(atPath: r.path) {
                    let f = try AVAudioFile(forReading: src)
                    let mono = AVAudioFormat(standardFormatWithSampleRate: f.processingFormat.sampleRate, channels: 1)!
                    let fl = try AVAudioFile(forWriting: l, settings: mono.settings)
                    let fr = try AVAudioFile(forWriting: r, settings: mono.settings)
                    let chunk = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536)!
                    let ml = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 65536)!
                    let mr = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 65536)!
                    while f.framePosition < f.length {
                        try f.read(into: chunk)
                        let n = Int(chunk.frameLength)
                        if n == 0 { break }
                        memcpy(ml.floatChannelData![0], chunk.floatChannelData![0], n * 4)
                        memcpy(mr.floatChannelData![0], chunk.floatChannelData![min(1, Int(f.processingFormat.channelCount) - 1)], n * 4)
                        ml.frameLength = AVAudioFrameCount(n); mr.frameLength = AVAudioFrameCount(n)
                        try fl.write(from: ml); try fr.write(from: mr)
                    }
                }
                out += [l, r]
            }
            return out
        }.value
        return try StemPlayer(monos: monos, session: session)
    }

    private init(monos: [URL], session: MusicSession) throws {
        files = try monos.map { try AVAudioFile(forReading: $0) }
        rate = files[0].processingFormat.sampleRate
        duration = Double(files[0].length) / rate
        self.session = session
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        env.outputType = .headphones
        env.reverbParameters.enable = false
        env.distanceAttenuationParameters.referenceDistance = 10
        engine.attach(env)
        engine.connect(env, to: engine.mainMixerNode, format: stereo)
        for f in files {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: env, format: f.processingFormat)
            n.renderingAlgorithm = .HRTFHQ
            n.sourceMode = .pointSource
            nodes.append(n)
        }
        engine.prepare()
        update()
    }

    func togglePlay() { playing ? pause() : play() }

    /// Silences the output (self-test).
    func mute() { engine.mainMixerNode.outputVolume = 0 }

    func play() {
        guard !playing else { return }
        if startFrame >= files[0].length - 100 { startFrame = 0 }
        do { if !engine.isRunning { try engine.start() } } catch { return }
        let count = AVAudioFrameCount(max(0, files[0].length - startFrame))
        // start every part on the same future instant so they stay sample-aligned
        let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
        for (n, f) in zip(nodes, files) {
            n.stop()
            n.scheduleSegment(f, startingFrame: startFrame, frameCount: count, at: nil)
            n.play(at: at)
        }
        playing = true
        if head.available && !head.active && !SelfTest.active { head.start() }  // self-test: no sensors
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        startFrame = currentFrame
        nodes.forEach { $0.stop() }
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        engine.stop()
        head.stop()
    }

    func seek(to seconds: Double) {
        let was = playing
        if was { pause() }
        startFrame = AVAudioFramePosition(max(0, min(duration, seconds)) * rate)
        position = seconds
        update()
        if was { play() }
    }

    func restartClock() { clockZero = position; update() }

    private var currentFrame: AVAudioFramePosition {
        guard playing, let n = nodes.first, let last = n.lastRenderTime, let t = n.playerTime(forNodeTime: last) else { return startFrame }
        return startFrame + max(0, t.sampleTime)
    }

    private func tick() {
        position = Double(currentFrame) / rate
        if position >= duration - 0.05 { pause(); startFrame = 0; position = 0 }
        update()
    }

    /// Positions every source for the current time, placements and head turn.
    func update() {
        guard let s = session else { return }
        let t = position - clockZero
        for (i, p) in s.placements.enumerated() {
            for side in 0..<2 {
                let node = nodes[2 * i + side]
                let az = p.az + p.orbit * t + (side == 0 ? p.width / 2 : -p.width / 2)
                let a = Float(az * .pi / 180), e = Float(p.el * .pi / 180)
                let v = SIMD3<Float>(cos(e) * cos(a), cos(e) * sin(a), sin(e))
                node.position = AVAudio3DPoint(x: -v.y * 2, y: v.z * 2, z: -v.x * 2)
                node.volume = p.muted ? 0 : Float(p.gain)
            }
        }
        // head tracking: the listener turns, the band stays put (same sign as Listen Live, measured)
        env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: -head.yaw, pitch: head.pitch, roll: -head.roll)
    }
}

// MARK: - Views

struct MusicStudio: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: MusicSession

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MusicHeader(session: session)
                switch session.phase {
                case .ready:
                    if let player = session.player {
                        StageCard(session: session, player: player)
                    }
                default:
                    SeparationCard(session: session)
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 130)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if session.phase == .ready, let player = session.player {
                MusicActionBar(session: session, player: player)
                    .frame(maxWidth: 1080)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { if session.phase == .needsEngine { session.begin() } }
    }
}

private struct MusicHeader: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: MusicSession

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                if let art = session.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [StemKind.vocals.color.opacity(0.6), StemKind.other.color.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 42, weight: .light)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 117, height: 117)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))

            VStack(alignment: .leading, spacing: 8) {
                Text(session.title).font(.system(size: 26, weight: .bold)).lineLimit(1)
                if let a = session.artist { Text(a).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 8) {
                    Chip(text: "3D Music", symbol: "airpodspro")
                    Chip(text: session.duration.clock, symbol: "clock")
                    Chip(text: session.url.pathExtension.uppercased())
                }
            }
            Spacer(minLength: 0)
            Button { app.closeMusic() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).help("Close this song")
        }
        .padding(18)
        .staticGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), darkness: 0.28)
    }
}

private struct SeparationCard: View {
    @ObservedObject var session: MusicSession

    var body: some View {
        GlassCard(title: "Splitting the Song", symbol: "waveform.path.ecg") {
            switch session.phase {
            case .needsEngine:
                Text("Spatialize uses Demucs, an open-source AI model from Meta, to split a song into vocals, drums, bass and the other instruments, right here on your Mac. It needs a one-time download of about 700 MB (Python, PyTorch and the model).")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Install Separation Engine") { session.installEngine() }
                        .buttonStyle(.glassProminent).controlSize(.large)
                }
            case .installing, .separating:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(session.phase == .installing ? "Installing the separation engine" : "Splitting into vocals, drums, bass and instruments")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if session.phase == .separating {
                        ProgressView(value: session.progress)
                    }
                    Text(session.status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Text("Usually under a minute for a song on Apple silicon. The parts are kept, so it only happens once per song.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Try Again") { session.begin() }.buttonStyle(.glass) }
            case .ready:
                EmptyView()
            }
        }
    }
}

private struct StageCard: View {
    @ObservedObject var session: MusicSession
    @ObservedObject var player: StemPlayer
    @ObservedObject var head: HeadTracker
    @State private var selected = 0

    init(session: MusicSession, player: StemPlayer) {
        self.session = session
        self.player = player
        self.head = player.head
    }

    var body: some View {
        GlassCard(title: "Your Stage", symbol: "person.3.sequence") {
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 10) {
                    StageDome(session: session, selected: $selected, headYaw: head.active ? Double(head.yaw) : 0, time: player.position)
                        .frame(width: 400, height: 400)
                    Text("Drag a part to move it · centre = above you · solid ring = ear level")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Presets").font(.system(size: 13, weight: .medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(MusicPreset.allCases) { p in
                            Button { withAnimation(.snappy) { session.apply(p) }; player.update() } label: {
                                Text(p.label).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.green.opacity(session.preset == p ? 0.75 : 0), lineWidth: 1.2))
                            .help(p.detail)
                        }
                    }
                    if let p = session.preset {
                        Text(p.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.5)
                    ForEach(StemKind.allCases) { k in
                        StemRow(kind: k, placement: binding(k.rawValue), selected: selected == k.rawValue) {
                            selected = k.rawValue
                        }
                    }
                    Divider().opacity(0.5)
                    HStack {
                        Text("Head tracking").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if head.available {
                            Button("Recenter") { head.recenter() }.buttonStyle(.glass).controlSize(.small).disabled(!head.active)
                            Toggle("", isOn: Binding(get: { head.active }, set: { $0 ? head.start() : head.stop() }))
                                .labelsHidden().toggleStyle(.switch)
                        } else {
                            Text("Connect AirPods Pro or Max").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Text("For the most accurate result, turn Spatial Audio off for Spatialize in Control Center → Sound.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: head.yaw) { _, _ in player.update() }
    }

    private func binding(_ i: Int) -> Binding<StemPlacement> {
        Binding(get: { session.placements[i] }, set: { session.placements[i] = $0; session.edited(); player.update() })
    }
}

private struct StemRow: View {
    let kind: StemKind
    @Binding var placement: StemPlacement
    var selected: Bool
    var select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color).frame(width: 18)
                Text(kind.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer()
                Toggle("", isOn: Binding(get: { !placement.muted }, set: { placement.muted = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(placement.muted ? "Muted" : "Playing")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            if selected {
                mini("Level", $placement.gain, 0...1.5, "\(Int(placement.gain * 100))%")
                mini("Height", $placement.el, -20...85, placement.el.rounded() == 0 ? "ear level" : "\(Int(placement.el))°")
                mini("Width", $placement.width, 0...330, "\(Int(placement.width))°")
                mini("Orbit", $placement.orbit, -40...40, placement.orbit == 0 ? "still" : String(format: "%+.0f°/s", placement.orbit))
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: selected)
    }

    private func mini(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Slider(value: v, in: r).controlSize(.small)
            Text(text).font(.system(size: 11).monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
        .padding(.leading, 26)
    }
}

/// Top-down map of the stage: drag each part; its stereo width is the arc between its two dots.
private struct StageDome: View {
    @ObservedObject var session: MusicSession
    @Binding var selected: Int
    var headYaw: Double
    var time: Double
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let R = min(geo.size.width, geo.size.height) / 2 / 1.34
            Canvas { ctx, _ in
                for (frac, alpha) in [(1.0, 0.35), (2.0 / 3, 0.14), (1.0 / 3, 0.14)] {
                    let r = R * frac
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(alpha)), lineWidth: frac == 1 ? 1.2 : 0.8)
                }
                let rb = R * 1.2
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rb, y: c.y - rb, width: 2 * rb, height: 2 * rb)),
                           with: .color(.white.opacity(0.1)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 5]))
                ctx.draw(Text("FRONT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y - rb - 8))
                ctx.draw(Text("BEHIND").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y + rb + 8))
                // you
                var nose = Path()
                let a = CGFloat(headYaw) * .pi / 180
                nose.move(to: c); nose.addLine(to: CGPoint(x: c.x - sin(a) * 24, y: c.y - cos(a) * 24))
                ctx.stroke(nose, with: .color(.white.opacity(0.8)), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.25)))
                // parts, unselected first so the selected one is on top
                let order = StemKind.allCases.sorted { ($0.rawValue == selected ? 1 : 0) < ($1.rawValue == selected ? 1 : 0) }
                for k in order {
                    let p = session.placements[k.rawValue]
                    let az = p.az + p.orbit * time
                    let col = k.color.opacity(p.muted ? 0.3 : 1)
                    let r = R * CGFloat(90 - max(-20, min(85, p.el))) / 90
                    // the spread between left and right channel
                    if p.width > 1 {
                        var arc = Path()
                        let steps = 24
                        for s in 0...steps {
                            let aa = (az + p.width / 2 - p.width * Double(s) / Double(steps)) * .pi / 180
                            let pt = CGPoint(x: c.x - sin(aa) * r, y: c.y - cos(aa) * r)
                            if s == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                        }
                        ctx.stroke(arc, with: .color(col.opacity(0.55)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    let ca = az * .pi / 180
                    let pt = CGPoint(x: c.x - sin(ca) * r, y: c.y - cos(ca) * r)
                    let size: CGFloat = k.rawValue == selected ? 30 : 24
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - size, y: pt.y - size, width: 2 * size, height: 2 * size)), with: .color(col.opacity(0.18)))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - size / 2, y: pt.y - size / 2, width: size, height: size)), with: .color(col))
                    if k.rawValue == selected {
                        ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - size / 2 - 3, y: pt.y - size / 2 - 3, width: size + 6, height: size + 6)),
                                   with: .color(.white), lineWidth: 2)
                    }
                    ctx.draw(Text(k.name).font(.system(size: 10.5, weight: .semibold)), at: CGPoint(x: pt.x, y: pt.y + size / 2 + 9))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let dx = g.location.x - c.x, dy = g.location.y - c.y
                    if dragging == nil {
                        // pick the nearest part to where the drag started
                        var best = selected, bestD = CGFloat.infinity
                        for k in StemKind.allCases {
                            let p = session.placements[k.rawValue]
                            let r = R * CGFloat(90 - p.el) / 90, ca = (p.az + p.orbit * time) * .pi / 180
                            let pt = CGPoint(x: c.x - sin(ca) * r, y: c.y - cos(ca) * r)
                            let d = hypot(pt.x - g.startLocation.x, pt.y - g.startLocation.y)
                            if d < bestD { bestD = d; best = k.rawValue }
                        }
                        dragging = best
                        selected = best
                    }
                    guard let i = dragging else { return }
                    let r = min(hypot(dx, dy), R * 1.2)
                    session.placements[i].el = max(-20, min(85, Double(90 - 90 * r / R)))
                    session.placements[i].az = Double(atan2(-dx, -dy) * 180 / .pi) - session.placements[i].orbit * time
                    session.edited()
                    session.player?.update()
                }
                .onEnded { _ in dragging = nil })
        }
    }
}

private struct MusicActionBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: MusicSession
    @ObservedObject var player: StemPlayer

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                Text(player.position.clock).font(.system(size: 12).monospacedDigit())
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                    .frame(minWidth: 200)
                Text(player.duration.clock).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                exportControls
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    @ViewBuilder private var exportControls: some View {
        switch session.export {
        case .idle, .failed:
            if case .failed(let m) = session.export {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(m)
            }
            Button {
                let folder = app.settings.outputFolder.isEmpty ? nil : URL(fileURLWithPath: app.settings.outputFolder)
                session.exportSpatial(to: session.exportURL(folder: folder), hrtf: HeadModels.engineSpec(app.settings.headModel))
            } label: {
                Label("Export Spatial Audio", systemImage: "airpodspro").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Color(red: 0.16, green: 0.42, blue: 1.0))
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Writes an .m4a with head-tracked Spatial Audio for QuickTime and Music, plus a binaural copy for any player.")
        case .running:
            ProgressView(value: session.exportProgress).frame(width: 120)
            Text("Exporting…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .done(let url):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.glass)
            Button { app.play(url) } label: { Label("Play in QuickTime", systemImage: "play.fill") }
                .buttonStyle(.glassProminent)
            Button { session.export = .idle } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.glass).help("Export again with new placements")
        }
    }
}
