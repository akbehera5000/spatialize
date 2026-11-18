import Foundation

/// The engine works in a hidden ".atmos2apple.*" folder next to the output. A finished run removes
/// it; an interrupted one (quit, crash, power loss) leaves it behind. On launch these are either
/// offered for resuming (the steps that finished are kept) or removed.
struct InterruptedConversion: Identifiable, Equatable {
    var id: URL { folder }
    var folder: URL
    var input: URL
    var output: URL
    var arguments: [String]
    var finished: [String]     // engine steps that completed: decode, audio, video, ocr, loudness
    var bytes: Int64
    var started: Date

    var title: String { output.deletingPathExtension().lastPathComponent }

    var finishedText: String {
        let names = ["audio": "audio", "video": "video", "decode": "Atmos decoding", "ocr": "subtitles"]
        let done = ["audio", "video", "ocr", "decode"].filter(finished.contains)
        // decoding is part of the audio, so only mention it when the audio itself isn't done
        let shown = done.filter { $0 != "decode" || !done.contains("audio") }.compactMap { names[$0] }
        return shown.isEmpty ? "nothing finished yet" : shown.joined(separator: " and ") + " finished"
    }
}

enum Leftovers {
    nonisolated(unsafe) static var registry = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/atmos2apple/workdirs")
    static let keepDays = 14.0

    struct Result {
        var resumable: [InterruptedConversion] = []
        var removedBytes: Int64 = 0
        var removedCount = 0
    }

    /// Looks at every engine folder it knows of. Runs off the main thread (sizes take a moment).
    static func scan(extraFolders: [URL], standardFolders: Bool = true) -> Result {
        let fm = FileManager.default
        var candidates = Set<URL>()
        let listed = (try? String(contentsOf: registry, encoding: .utf8))?.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } ?? []
        candidates.formUnion(listed)
        var folders = Set(extraFolders + listed.map { $0.deletingLastPathComponent() })
        for d in [FileManager.SearchPathDirectory.downloadsDirectory, .moviesDirectory, .desktopDirectory] where standardFolders {
            if let u = fm.urls(for: d, in: .userDomainMask).first { folders.insert(u) }
        }
        for f in folders {
            let items = (try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil, options: [])) ?? []
            candidates.formUnion(items.filter { $0.lastPathComponent.hasPrefix(".atmos2apple.") })
        }

        var result = Result()
        for dir in candidates.sorted(by: { $0.path < $1.path }) {
            var isDir: ObjCBool = false
            guard dir.lastPathComponent.hasPrefix(".atmos2apple."),
                  fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // still being worked on
            if let pid = (try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8))
                .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), kill(pid, 0) == 0 {
                continue
            }
            // an older engine without a pid file may still be writing: leave anything touched lately
            if newest(dir) > Date().addingTimeInterval(-600) && !fm.fileExists(atPath: dir.appendingPathComponent("resume.info").path) {
                continue
            }
            let size = bytes(dir)
            if let job = read(dir, size: size), !job.finished.isEmpty,
               fm.fileExists(atPath: job.input.path), job.started > Date().addingTimeInterval(-keepDays * 86400) {
                result.resumable.append(job)
            } else if (try? fm.removeItem(at: dir)) != nil {
                result.removedBytes += size
                result.removedCount += 1
            }
        }
        writeRegistry(result.resumable.map(\.folder))
        result.resumable.sort { $0.started > $1.started }
        return result
    }

    static func discard(_ job: InterruptedConversion) {
        try? FileManager.default.removeItem(at: job.folder)
    }

    private static func read(_ dir: URL, size: Int64) -> InterruptedConversion? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("resume.info"), encoding: .utf8) else { return nil }
        var input: URL?, output: URL?, started = Date.distantPast, args: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            switch key {
            case "input": input = URL(fileURLWithPath: value)
            case "output": output = URL(fileURLWithPath: value)
            case "started": started = Date(timeIntervalSince1970: Double(value) ?? 0)
            case "arg": args.append(value)
            default: break
            }
        }
        guard let input, let output, !args.isEmpty else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let done = files.filter { $0.hasSuffix(".done") }.map { String($0.dropLast(5)) }
        return InterruptedConversion(folder: dir, input: input, output: output, arguments: args,
                                     finished: done, bytes: size, started: started)
    }

    private static func writeRegistry(_ dirs: [URL]) {
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (dirs.map(\.path).joined(separator: "\n") + (dirs.isEmpty ? "" : "\n")).write(to: registry, atomically: true, encoding: .utf8)
    }

    private static func bytes(_ dir: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private static func newest(_ dir: URL) -> Date {
        var latest = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let f = e?.nextObject() as? URL {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > latest { latest = d }
        }
        return latest
    }
}
