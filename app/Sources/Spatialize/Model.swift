import AppKit
import SwiftUI

enum HeightMode: String, CaseIterable, Identifiable {
    case off, eq, hoa, hoaEq = "hoa+eq"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .eq: "Height Cue"
        case .hoa: "Ambisonic"
        case .hoaEq: "Both"
        }
    }
    var detail: String {
        switch self {
        case .off: "Plain 7.1.4. Apple's renderer places the height speakers on its own."
        case .eq: "Boosts the 7.5 kHz band the ear uses to judge \u{201C}above\u{201D}, on the height speakers only. Recommended."
        case .hoa: "Encodes a 360° ambisonic sound field with the height speakers raised to the angle you choose."
        case .hoaEq: "Ambisonic sound field plus the height cue boost."
        }
    }
    var usesEQ: Bool { self == .eq || self == .hoaEq }
    var usesAngle: Bool { self == .hoa || self == .hoaEq }
}

enum RoomPreset: String, CaseIterable, Identifiable {
    case off, small, living, cinema
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .small: "Small Room"
        case .living: "Living Room"
        case .cinema: "Cinema"
        }
    }
}

/// What players without Apple's spatial codec (IINA, VLC) get.
enum CompatMode: String, CaseIterable, Identifiable {
    case binaural, surround = "aac", both, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .binaural: "Binaural"
        case .surround: "5.1"
        case .both: "Both"
        case .none: "None"
        }
    }
    var detail: String {
        switch self {
        case .binaural: "A stereo track rendered for headphones with your head model, so height and surround come through in IINA, VLC or on a phone. No head tracking."
        case .surround: "A 5.1 AAC copy of the same mix, for speakers or players that do their own surround."
        case .both: "The binaural track for headphones, plus the 5.1 copy for speakers."
        case .none: "QuickTime and other Apple players only."
        }
    }
}

/// Ten-band headphone EQ presets (31 Hz … 16 kHz).
enum EQPreset: String, CaseIterable, Identifiable {
    case flat, warm, dialogue, lessBass, air, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat: "Flat"
        case .warm: "Warmer"
        case .dialogue: "Clearer Voices"
        case .lessBass: "Less Bass"
        case .air: "More Air"
        case .custom: "Custom"
        }
    }
    var gains: [Double]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .warm: [3, 2.5, 1.5, 0.5, 0, 0, -0.5, -1, -1.5, -1]
        case .dialogue: [-2, -1.5, -1, 0, 1, 2, 2.5, 1.5, 0, 0]
        case .lessBass: [-5, -4, -2.5, -1, 0, 0, 0, 0, 0, 0]
        case .air: [0, 0, 0, 0, 0, 0, 0, 1, 2.5, 3.5]
        case .custom: nil
        }
    }
    static let bands = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
}

enum VideoMode: String, CaseIterable, Identifiable {
    case auto, copy, hevc, h264
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .copy: "Keep Original"
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }
}

/// Every option, persisted between launches.
final class Settings: ObservableObject {
    @AppStorage("heightMode") var heightMode: HeightMode = .eq
    @AppStorage("heightEQ") var heightEQ: Double = 6
    @AppStorage("heightAngle") var heightAngle: Double = 60
    @AppStorage("audioBitrate") var audioBitrate: Int = 1_536_000
    @AppStorage("keepOtherAudio") var keepOtherAudio: Bool = true
    @AppStorage("compatTrack") var compatTrack: Bool = true      // before compatMode existed
    @AppStorage("compatMode") var compatMode: CompatMode = .binaural
    /// Head model for the binaural track and Listen Live: "apple" or a SOFA file path.
    @AppStorage("headModel") var headModel: String = "apple"
    @AppStorage("eqPreset") var eqPreset: EQPreset = .flat
    @AppStorage("eqGains") private var eqGainsText: String = "0,0,0,0,0,0,0,0,0,0"
    @AppStorage("videoMode") var videoMode: VideoMode = .auto
    @AppStorage("videoQuality") var videoQuality: Double = 62
    @AppStorage("maxHeight") var maxHeight: Int = 0
    @AppStorage("keepHDR") var keepHDR: Bool = true
    @AppStorage("includeSubtitles") var includeSubtitles: Bool = true
    @AppStorage("openWhenDone") var openWhenDone: Bool = true
    @AppStorage("outputFolder") var outputFolder: String = ""
    @AppStorage("customLayout") var customLayout: Bool = false
    @AppStorage("speakerLayoutJSON") private var speakerLayoutJSON: String = ""
    @AppStorage("mirrorPairs") var mirrorPairs: Bool = true
    @AppStorage("snapAngles") var snapAngles: Bool = true
    // sound
    @AppStorage("directObjects") var directObjects: Bool = false
    @AppStorage("dialogueDB") var dialogueDB: Double = 0
    @AppStorage("lfeDB") var lfeDB: Double = 0
    @AppStorage("roomPreset") var roomPreset: RoomPreset = .off
    @AppStorage("roomAmount") var roomAmount: Double = 1
    @AppStorage("nightMode") var nightMode: Bool = false
    @AppStorage("normalizeLoudness") var normalizeLoudness: Bool = false
    @AppStorage("loudnessTarget") var loudnessTarget: Double = -24
    @AppStorage("previewLength") var previewLength: Double = 30

    init() {
        // someone who switched the old "also playable in IINA" off keeps it off
        if UserDefaults.standard.object(forKey: "compatMode") == nil && !compatTrack { compatMode = .none }
    }

    var eqGains: [Double] {
        get {
            let v = eqGainsText.split(separator: ",").compactMap { Double($0) }
            return v.count == 10 ? v : Array(repeating: 0, count: 10)
        }
        set { eqGainsText = newValue.map { String(format: "%.1f", $0) }.joined(separator: ",") }
    }
    var eqIsFlat: Bool { eqGains.allSatisfy { abs($0) < 0.05 } }

    var speakerLayout: SpeakerLayout {
        get { SpeakerLayout(json: speakerLayoutJSON) ?? .standard() }
        set { speakerLayoutJSON = newValue.json }
    }

    func reset() {
        customLayout = false; speakerLayoutJSON = ""; mirrorPairs = true; snapAngles = true
        heightMode = .eq; heightEQ = 6; heightAngle = 60; audioBitrate = 1_536_000; keepOtherAudio = true; compatTrack = true
        compatMode = .binaural; headModel = "apple"; eqPreset = .flat; eqGains = Array(repeating: 0, count: 10)
        videoMode = .auto; videoQuality = 62; maxHeight = 0; keepHDR = true; includeSubtitles = true
        openWhenDone = true; outputFolder = ""
        directObjects = false; dialogueDB = 0; lfeDB = 0; roomPreset = .off; roomAmount = 1
        nightMode = false; normalizeLoudness = false; loudnessTarget = -24; previewLength = 30
    }
}

/// Where the bundled tools live: inside the app, or the project folder when run from source.
enum Engine {
    static let root: URL = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("atmos2apple").path) {
            return res
        }
        var dir = Bundle.main.executableURL!.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("atmos2apple").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/usr/local/bin")
    }()
    static var script: URL { root.appendingPathComponent("atmos2apple") }
    static func tool(_ name: String) -> URL {
        let bundled = root.appendingPathComponent("bin/\(name)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return URL(fileURLWithPath: "\(dir)/\(name)")
        }
        return bundled
    }
}

/// What the engine's sync check measured for one track of the finished movie.
struct SyncResult: Equatable {
    enum Status: String { case ok, off, drift, unknown }
    var track: String          // spatial, compat or audio
    var status: Status
    var offsetMs: Double       // median offset beyond the one asked for (positive = audio late)
    var spreadMs: Double       // how much it changes through the film
    var checked: Int
    var total: Int

    /// The worst of several results (spatial and its AAC copy), as one verdict.
    static func summary(_ r: [SyncResult]) -> SyncResult? {
        let order: [Status] = [.drift, .off, .unknown, .ok]
        return r.min { order.firstIndex(of: $0.status)! < order.firstIndex(of: $1.status)! }
    }

    var headline: String {
        switch status {
        case .ok: "Verified in sync"
        case .off: String(format: "Audio is %.0f ms %@", abs(offsetMs), offsetMs > 0 ? "late" : "early")
        case .drift: String(format: "Audio drifts by up to %.1f s", spreadMs / 1000)
        case .unknown: "Sync couldn't be checked"
        }
    }

    var detail: String {
        switch status {
        case .ok: "Checked at \(checked) points through the film against the original."
        case .off: "The whole film is shifted by the same amount. Fix Sync moves it back without converting again."
        case .drift: "The gap grows through the film, which a shift can't fix. Convert it again; if it persists, tell me."
        case .unknown: "Too few clear passages to compare (\(checked) of \(total)). This happens with very quiet films."
        }
    }
}

/// One conversion, driven by the engine's "@stage / @progress / @done" lines.
@MainActor
final class Conversion: ObservableObject {
    enum State: Equatable { case idle, running, done(URL), failed(String), cancelled }

    struct Lane {
        var stage = "Waiting"
        var progress: Double = 0
        var finished = false
    }

    @Published var state: State = .idle
    @Published var audio = Lane()
    @Published var video = Lane()
    @Published var subs = Lane()
    @Published var finalStage = ""
    @Published var sync: [SyncResult] = []
    @Published var log: [String] = []
    @Published var startedAt = Date()
    @Published var finishedAt = Date()
    private var process: Process?
    private var buffer = ""
    /// The engine's working folder (finished steps are kept there when a run is interrupted).
    private(set) var workDir: URL?
    private var discardWork = false
    private var activity: NSObjectProtocol?
    /// Called once when a run ends, whatever the outcome.
    var onFinish: ((State) -> Void)?

    var overall: Double {
        let base = 0.48 * audio.progress + 0.48 * video.progress
        if case .done = state { return 1 }
        return finalStage.isEmpty ? base : 0.97
    }

    var isRunning: Bool { state == .running }

    func start(arguments: [String]) {
        audio = Lane(); video = Lane(); subs = Lane(); finalStage = ""; log = []; buffer = ""; sync = []
        startedAt = Date()
        state = .running
        workDir = nil; discardWork = false
        // keep the Mac from sleeping while it works (closing the lid still sleeps it)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Converting a movie")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Engine.script.path] + arguments + ["--progress"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Engine.root.path)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in self?.consume(text) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in self?.finished(status: status) }
        }
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops the run and throws away what it had finished.
    func cancel() {
        guard let p = process, p.isRunning else { return }
        state = .cancelled
        discardWork = true
        p.terminate()
    }

    /// Stops the run but keeps its finished steps, so it can resume next time (quitting the app).
    func suspend() {
        guard let p = process, p.isRunning else { return }
        state = .cancelled
        p.terminate()
        p.waitUntilExit()
    }

    private func appendLog(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            log.append(String(line))
        }
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func consume(_ text: String) {
        buffer += text
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let tag = parts.first else { return }
        switch tag {
        case "@stage" where parts.count == 3:
            switch parts[1] {
            case "audio": audio.stage = parts[2]
            case "video": video.stage = parts[2]
            case "subs": subs.stage = parts[2]
            default:
                finalStage = parts[2]
                audio.progress = 1; video.progress = 1
                audio.finished = true; video.finished = true
            }
        case "@progress" where parts.count == 3:
            let v = Double(parts[2]) ?? 0
            if parts[1] == "audio" { audio.progress = max(audio.progress, v) }
            if parts[1] == "video" { video.progress = max(video.progress, v) }
        case "@sync":
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 7, let status = SyncResult.Status(rawValue: f[2]) {
                sync.append(SyncResult(track: f[1], status: status, offsetMs: Double(f[3]) ?? 0,
                                       spreadMs: Double(f[4]) ?? 0, checked: Int(f[5]) ?? 0, total: Int(f[6]) ?? 0))
            }
        case "@work" where parts.count >= 2:
            workDir = URL(fileURLWithPath: String(line.dropFirst("@work ".count)))
        case "@done" where parts.count >= 2:
            let path = line.dropFirst("@done ".count)
            finishedAt = Date()
            state = .done(URL(fileURLWithPath: String(path)))
            onFinish?(state)
        case "@error":
            state = .failed(String(line.dropFirst("@error ".count)))
            onFinish?(state)
        default:
            break
        }
    }

    private func finished(status: Int32) {
        process = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if discardWork, let w = workDir, w.lastPathComponent.hasPrefix(".atmos2apple.") {
            try? FileManager.default.removeItem(at: w)
        }
        if case .running = state {
            if status == 0 {
                state = .failed("The converter stopped without finishing.")
            } else {
                let last = log.last(where: { !$0.hasPrefix("▸") }) ?? "Exit code \(status)"
                state = .failed(last.replacingOccurrences(of: "atmos2apple: ", with: ""))
            }
            onFinish?(state)
        } else if state == .cancelled {
            onFinish?(state)
        }
    }
}

extension TimeInterval {
    var clock: String {
        let s = Int(self.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
