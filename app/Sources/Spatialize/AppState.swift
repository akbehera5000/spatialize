import AppKit
import Combine
import SwiftUI

/// The movie that is open, the choices made for it, and the conversions running on it.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var info: MediaInfo?
    @Published var thumbnail: NSImage?
    @Published var loading = false
    @Published var loadError: String?

    // per-movie choices
    @Published var audioTrack = 0
    @Published var extraAudio: Set<Int> = []
    @Published var subtitles: Set<Int> = []
    @Published var ocrSubtitles: Set<Int> = []
    @Published var outputName = ""
    @Published var syncMs: Double = 0
    @Published var previewStart: Double = 0

    // sheets and alerts
    @Published var diskWarning: DiskEstimate?
    @Published var showQueue = false
    @Published var showResync = false
    @Published var showLive = false
    @Published var showHeadTest = false
    @Published var showCalibration = false
    /// Conversions a quit, crash or power loss interrupted, with the steps they finished.
    @Published var interrupted: [InterruptedConversion] = []
    /// Space freed on launch by removing leftover temporary folders.
    @Published var cleanedBytes: Int64 = 0
    /// Movie and correction to pre-fill in the sync repair sheet.
    @Published var resyncPreset: (url: URL, ms: Double)?

    func fixSync(_ url: URL, measured: SyncResult) {
        resyncPreset = (url, -measured.offsetMs)
        showResync = true
    }

    let settings = Settings()
    let conversion = Conversion()
    let preview = Conversion()
    lazy var queue = JobQueue(app: self)

    private var bag: Set<AnyCancellable> = []

    init() {
        // a finished main conversion lets the queue continue
        conversion.onFinish = { [weak self] _ in self?.queue.startNextIfIdle() }
        // re-publish nested changes so views that watch AppState update
        for o in [conversion.objectWillChange, preview.objectWillChange] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    // MARK: leftovers and resuming

    /// On launch: offers interrupted conversions for resuming, removes other leftovers.
    func scanLeftovers() {
        var folders: [URL] = []
        if !settings.outputFolder.isEmpty { folders.append(URL(fileURLWithPath: settings.outputFolder)) }
        Task.detached(priority: .utility) {
            let r = Leftovers.scan(extraFolders: folders)
            await MainActor.run {
                self.interrupted = r.resumable
                self.cleanedBytes = r.removedBytes
            }
        }
    }

    func resume(_ job: InterruptedConversion) {
        interrupted.removeAll { $0 == job }
        queue.add(title: job.title, output: job.output, args: job.arguments,
                  size: DiskEstimate(needed: 0, free: .max, folder: job.output.deletingLastPathComponent()))
        showQueue = true
    }

    func discard(_ job: InterruptedConversion) {
        interrupted.removeAll { $0 == job }
        Leftovers.discard(job)
    }

    /// Movies handed over by Finder's right-click service or Shortcuts: straight into the queue.
    func convertFromOutside(_ urls: [URL]) {
        for u in urls { queue.addDefault(u) }
        showQueue = true
        NSApp.activate()
    }

    // MARK: opening

    func open(_ url: URL) {
        guard !conversion.isRunning else { NSSound.beep(); return }
        loading = true
        loadError = nil
        conversion.state = .idle
        preview.state = .idle
        Task {
            do {
                let info = try await Self.probe(url)
                self.info = info
                let d = Self.defaults(for: info)
                self.audioTrack = d.audio
                self.extraAudio = d.extra
                self.subtitles = d.subs
                self.ocrSubtitles = d.ocr
                self.outputName = info.url.deletingPathExtension().lastPathComponent + " · Spatial"
                self.syncMs = 0
                self.previewStart = (info.duration * 0.28).rounded()
                self.thumbnail = nil
                self.loading = false
                self.thumbnail = await Self.frame(info, at: info.duration * 0.28, width: 1280)
            } catch {
                self.loading = false
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Opens the first movie and puts the rest straight into the queue with automatic choices.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if info == nil || !conversion.isRunning { open(first) } else { queue.addDefault(first) }
        for u in urls.dropFirst() { queue.addDefault(u) }
        if urls.count > 1 { showQueue = true }
    }

    static func probe(_ url: URL) async throws -> MediaInfo {
        let info = try await MediaInfo.load(url, ffprobe: Engine.tool("ffprobe"))
        guard info.video != nil else { throw Shell.Failure(message: "This file has no video track.") }
        guard !info.audio.isEmpty else { throw Shell.Failure(message: "This file has no audio track.") }
        return info
    }

    /// Track choices for a freshly opened movie.
    static func defaults(for info: MediaInfo) -> (audio: Int, extra: Set<Int>, subs: Set<Int>, ocr: Set<Int>) {
        let audio = info.bestAudio?.id ?? 0
        let lang = info.audio.first(where: { $0.id == audio })?.language ?? "und"
        let textLangs = Set(info.subtitles.filter(\.isText).map(\.language))
        // read picture subtitles only in the film's language, and only when there's no text version
        let ocr = info.subtitles.filter { $0.codec == "hdmv_pgs_subtitle" && $0.language == lang && !textLangs.contains(lang) }
        return (audio, Set(info.audio.map(\.id)).subtracting([audio]),
                Set(info.subtitles.filter(\.isText).map(\.id)), ocr.first.map { [$0.id] } ?? [])
    }

    func close() {
        guard !conversion.isRunning else { return }
        info = nil
        thumbnail = nil
        conversion.state = .idle
    }

    // MARK: output

    var outputFolder: URL {
        let s = settings.outputFolder
        if !s.isEmpty { return URL(fileURLWithPath: s) }
        return info?.url.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var outputURL: URL {
        let name = outputName.trimmingCharacters(in: .whitespaces).isEmpty ? "Spatial" : outputName
        return outputFolder.appendingPathComponent(name).appendingPathExtension("mov")
    }

    /// The choices made for one movie (the open one, or one being queued).
    struct Choices {
        var info: MediaInfo
        var audioTrack: Int
        var extraAudio: Set<Int>
        var subtitles: Set<Int>
        var ocrSubtitles: Set<Int>
        var syncMs: Double
    }

    var choices: Choices? {
        info.map { Choices(info: $0, audioTrack: audioTrack, extraAudio: extraAudio, subtitles: subtitles,
                           ocrSubtitles: ocrSubtitles, syncMs: syncMs) }
    }

    var videoPlan: (convert: Bool, text: String) { info.map { videoPlan(for: $0) } ?? (false, "") }

    /// What will happen to the video, in words, and whether it gets re-encoded.
    func videoPlan(for info: MediaInfo) -> (convert: Bool, text: String) {
        guard let v = info.video else { return (false, "") }
        let s = settings
        let tooTall = s.maxHeight > 0 && v.height > s.maxHeight
        let needsSDR = v.isHDR && !s.keepHDR
        let convert: Bool
        switch s.videoMode {
        case .auto: convert = !info.videoPlaysAsIs || tooTall || needsSDR
        case .copy: convert = false
        case .hevc, .h264: convert = true
        }
        let src = v.codec.uppercased()
        if !convert {
            if v.codec == "hevc" && v.dolbyVisionProfile == 7 { return (false, "Keep \(src) video, Dolby Vision 7 becomes HDR10") }
            return (false, "Keep the original \(src) video, no quality loss")
        }
        let target = s.videoMode == .h264 ? "H.264" : "HEVC"
        let hdr = v.isHDR ? (s.keepHDR && target == "HEVC" ? " 10-bit HDR" : " SDR") : ""
        return (true, "Convert \(src) → \(target)\(hdr)")
    }

    var selectedTrackIsAtmosTrueHD: Bool {
        info?.audio.first(where: { $0.id == audioTrack }).map { $0.codec == "truehd" && $0.isAtmos } ?? false
    }

    // MARK: engine arguments

    /// Everything the engine needs, from the current settings. `clip` makes a scene preview.
    func engineArguments(_ c: Choices, output: URL, clip: (start: Double, length: Double)? = nil) -> [String] {
        let (info, audioTrack, extraAudio, subtitles, ocrSubtitles, syncMs) =
            (c.info, c.audioTrack, c.extraAudio, c.subtitles, c.ocrSubtitles, c.syncMs)
        let s = settings
        var args = [info.url.path, output.path,
                    "--track", "\(audioTrack)",
                    "--bitrate", "\(s.audioBitrate)",
                    "--height", s.heightMode.rawValue,
                    "--height-eq", String(format: "%.1f", s.heightEQ),
                    "--height-angle", "\(Int(s.heightAngle))",
                    "--objects", s.directObjects ? "direct" : "speakers",
                    "--dialogue", String(format: "%.1f", s.dialogueDB),
                    "--lfe", String(format: "%.1f", s.lfeDB),
                    "--room", s.roomPreset == .off ? "off" : "\(s.roomPreset.rawValue):\(String(format: "%.2f", s.roomAmount))",
                    "--sync", "\(Int(syncMs))",
                    "--compat", s.compatMode.rawValue]
        if s.compatMode == .binaural || s.compatMode == .both { args += ["--hrtf", HeadModels.engineSpec(s.headModel)] }
        if !s.eqIsFlat { args += ["--eq", s.eqGains.map { String(format: "%.1f", $0) }.joined(separator: ",")] }
        if s.nightMode { args.append("--night") }
        if s.customLayout { args += ["--speakers", s.speakerLayout.engineArgument] }
        let extras = s.keepOtherAudio ? extraAudio.subtracting([audioTrack]).sorted() : []
        args += ["--extra-audio", extras.isEmpty ? "none" : extras.map(String.init).joined(separator: ",")]
        let subs = s.includeSubtitles ? subtitles.sorted() : []
        args += ["--subs", subs.isEmpty ? "none" : subs.map(String.init).joined(separator: ",")]
        let ocr = s.includeSubtitles ? ocrSubtitles.sorted() : []
        if !ocr.isEmpty { args += ["--ocr-subs", ocr.map(String.init).joined(separator: ",")] }
        if let clip {
            // previews: fast 1080p video, loudness left alone (a scene isn't the whole film)
            args += ["--start", String(format: "%.2f", clip.start), "--duration", String(format: "%.2f", clip.length),
                     "--video", "hevc", "--quality", "55", "--max-height", "1080",
                     "--hdr", s.keepHDR ? "keep" : "sdr", "--loudness", "off"]
        } else {
            args += ["--video", s.videoMode.rawValue,
                     "--quality", "\(Int(s.videoQuality))",
                     "--max-height", "\(s.maxHeight)",
                     "--hdr", s.keepHDR ? "keep" : "sdr",
                     "--loudness", s.normalizeLoudness ? "\(Int(s.loudnessTarget))" : "off"]
        }
        return args
    }

    // MARK: converting

    /// Starts the conversion, after checking there's room on the disk. While the queue is busy,
    /// the movie joins the queue instead.
    func convert(skipDiskCheck: Bool = false) {
        guard let c = choices else { return }
        if queue.isBusy {
            addToQueue()
            return
        }
        let est = estimate(c, output: outputURL)
        if !skipDiskCheck, est.free < est.needed {
            diskWarning = est
            return
        }
        conversion.start(arguments: engineArguments(c, output: outputURL))
    }

    func addToQueue() {
        guard let c = choices else { return }
        queue.add(title: c.info.title, output: outputURL, args: engineArguments(c, output: outputURL),
                  size: estimate(c, output: outputURL))
        showQueue = true
    }

    // MARK: disk space

    struct DiskEstimate: Identifiable {
        let id = UUID()
        var needed: Int64
        var free: Int64
        var folder: URL
    }

    /// Peak space the conversion needs on the output's disk: the decoded Atmos master is by far
    /// the largest temporary file (24-bit PCM for every bed and object), then the video and the
    /// finished movie.
    func estimate(_ c: Choices, output: URL) -> DiskEstimate {
        let info = c.info
        let d = max(info.duration, 1)
        let track = info.audio.first(where: { $0.id == c.audioTrack })
        var needed: Int64 = 0
        if track?.codec == "truehd" {
            needed += Int64(d * 6_000_000 / 8)               // the TrueHD track copied out
            needed += Int64(d * 48_000 * 3 * 26)             // decoded master, ~26 channels
        } else {
            needed += Int64(d * 48_000 * 4 * 12 / 4)         // working audio
        }
        let video = videoPlan(for: info).convert ? Int64(d * Double(settings.videoQuality) * 300_000 / 8) : info.fileSize
        needed += video * 2                                  // video.mp4 and the final movie
        needed += Int64(Double(needed) * 0.05) + 1_000_000_000
        let folder = output.deletingLastPathComponent()
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        return DiskEstimate(needed: needed, free: free, folder: folder)
    }

    // MARK: scene preview

    var previewURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Spatialize Preview.mov")
    }
    /// The preview's decoded Atmos master (or 7.1.4 mix), for the live player.
    var liveMasterDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Spatialize Live")
    }

    /// Converts a short scene with the current settings, then opens it.
    func makePreview(live: Bool = false) {
        guard info != nil, !preview.isRunning else { return }
        let length = settings.previewLength
        let start = min(max(0, previewStart), max(0, (info?.duration ?? 0) - length))
        preview.onFinish = { [weak self] state in
            guard let self, case .done(let url) = state else { return }
            if live { self.showLive = true } else { self.play(url) }
        }
        guard let c = choices else { return }
        preview.start(arguments: engineArguments(c, output: previewURL, clip: (start, length)) + ["--keep-master", liveMasterDir.path])
    }

    // MARK: resync

    /// Re-times an existing movie's main audio without converting it again.
    func resync(_ movie: URL, by ms: Double) async throws -> URL {
        let sign = ms >= 0 ? "+" : "−"
        let name = movie.deletingPathExtension().lastPathComponent + " (sync \(sign)\(Int(abs(ms))) ms).mov"
        let out = movie.deletingLastPathComponent().appendingPathComponent(name)
        _ = try await Shell.output(Engine.tool("mux"), ["--resync", movie.path, "--out", out.path,
                                                        "--delay", String(format: "%.3f", ms / 1000)])
        return out
    }

    // MARK: speaker test

    @Published var makingTest = false

    /// Renders the speaker-walk test with the current height settings and opens it in QuickTime.
    func playSpeakerTest() {
        guard !makingTest else { return }
        makingTest = true
        let s = settings
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Spatialize Speaker Test.mov")
        var args = [out.path, "--height", s.heightMode.rawValue,
                    "--height-eq", String(format: "%.1f", s.heightEQ),
                    "--height-angle", "\(Int(s.heightAngle))"]
        if s.customLayout { args += ["--speakers", s.speakerLayout.engineArgument] }
        Task {
            do {
                _ = try await Shell.output(URL(fileURLWithPath: "/bin/zsh"),
                                           [Engine.root.appendingPathComponent("speaker-test").path] + args)
                play(out)
            } catch {
                loadError = "Couldn't make the speaker test: \(error.localizedDescription)"
            }
            makingTest = false
        }
    }

    func play(_ url: URL) {
        let qt = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        NSWorkspace.shared.open([url], withApplicationAt: qt, configuration: NSWorkspace.OpenConfiguration())
    }

    /// One video frame as an image (tone-mapped when HDR).
    static func frame(_ info: MediaInfo, at time: Double, width: Int) async -> NSImage? {
        guard let v = info.video else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("spatialize-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        var filter = "scale=\(width):-2"
        if v.isHDR {
            filter = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,scale=\(width):-2"
        }
        var args = ["-v", "error", "-ss", String(format: "%.1f", max(0, time))]
        if v.codec == "av1" { args += ["-c:v", "libdav1d"] }
        args += ["-i", info.url.path, "-frames:v", "1", "-vf", filter, "-q:v", "3", "-y", out.path]
        _ = try? await Shell.output(Engine.tool("ffmpeg"), args)
        return NSImage(contentsOf: out)
    }
}

/// Movies waiting to be converted one after another, each with the settings it was added with.
@MainActor
final class JobQueue: ObservableObject {
    enum JobState: Equatable { case waiting, running, done(URL), failed(String), cancelled }

    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var output: URL
        var args: [String]
        var needed: Int64
        var state: JobState = .waiting
        var sync: SyncResult?
    }

    @Published var jobs: [Job] = []
    let runner = Conversion()
    private weak var app: AppState?
    private var current: UUID?
    private var bag: Set<AnyCancellable> = []

    init(app: AppState) {
        self.app = app
        runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        runner.onFinish = { [weak self] state in self?.finished(state) }
    }

    var isBusy: Bool { runner.isRunning || jobs.contains { $0.state == .waiting } }
    var pending: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }

    func add(title: String, output: URL, args: [String], size: AppState.DiskEstimate) {
        jobs.append(Job(title: title, output: output, args: args, needed: size.needed))
        startNextIfIdle()
    }

    /// Adds a movie with the automatic track choices and the current settings.
    func addDefault(_ url: URL) {
        guard let app else { return }
        Task {
            guard let info = try? await AppState.probe(url) else {
                app.loadError = "Couldn't read \(url.lastPathComponent), so it wasn't queued."
                return
            }
            let d = AppState.defaults(for: info)
            let c = AppState.Choices(info: info, audioTrack: d.audio, extraAudio: d.extra, subtitles: d.subs,
                                     ocrSubtitles: d.ocr, syncMs: 0)
            let folder = app.settings.outputFolder.isEmpty ? url.deletingLastPathComponent() : URL(fileURLWithPath: app.settings.outputFolder)
            let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " · Spatial.mov")
            add(title: info.title, output: out, args: app.engineArguments(c, output: out), size: app.estimate(c, output: out))
        }
    }

    func startNextIfIdle() {
        guard !runner.isRunning, app?.conversion.isRunning != true,
              let i = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        jobs[i].state = .running
        current = jobs[i].id
        runner.start(arguments: jobs[i].args)
    }

    private func finished(_ state: Conversion.State) {
        guard let id = current, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch state {
        case .done(let url):
            jobs[i].state = .done(url)
            jobs[i].sync = SyncResult.summary(runner.sync)
        case .failed(let m): jobs[i].state = .failed(m)
        default: jobs[i].state = .cancelled
        }
        current = nil
        if case .done = state { NSSound(named: "Glass")?.play() }
        startNextIfIdle()
    }

    func remove(_ job: Job) {
        if job.state == .running { runner.cancel(); return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { if case .waiting = $0.state { return false }; return $0.state != .running }
    }

    var currentJob: Job? { jobs.first { $0.state == .running } }
}
