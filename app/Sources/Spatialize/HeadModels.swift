import Foundation

/// A head model the binaural track, Listen Live and the head test can use.
struct HeadModel: Identifiable, Hashable {
    var id: String        // "apple", or a SOFA file path
    var name: String
    var detail: String
    var isApple: Bool { id == "apple" }
}

/// The head models on this Mac: Apple's, the built-in KEMAR dummy head, and SOFA files that were
/// downloaded or added (kept in ~/Library/Application Support/Spatialize/Heads).
enum HeadModels {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Spatialize/Heads")
    }

    static var kemar: URL { Engine.root.appendingPathComponent("hrtf/KEMAR.sofa") }

    /// Free measured heads from public research databases (sofacoustics.org), downloaded only when
    /// the person asks. Real listeners, so the head test has a range of ear shapes to choose from.
    struct Download {
        var file: String
        var name: String
        var source: String
        var url: String
        var bytes: Int64
    }

    static let catalog: [Download] = [
        Download(file: "ARI NH2.sofa", name: "ARI listener NH2", source: "Acoustics Research Institute, Vienna (CC BY-SA)",
                 url: "https://sofacoustics.org/data/database/ari/hrtf_nh2.sofa", bytes: 2_962_116),
        Download(file: "ARI NH4.sofa", name: "ARI listener NH4", source: "Acoustics Research Institute, Vienna (CC BY-SA)",
                 url: "https://sofacoustics.org/data/database/ari/hrtf_nh4.sofa", bytes: 2_952_337),
        Download(file: "CIPIC 003.sofa", name: "CIPIC subject 3", source: "UC Davis CIPIC database",
                 url: "https://sofacoustics.org/data/database/cipic/subject_003.sofa", bytes: 1_837_391),
        Download(file: "CIPIC 008.sofa", name: "CIPIC subject 8", source: "UC Davis CIPIC database",
                 url: "https://sofacoustics.org/data/database/cipic/subject_008.sofa", bytes: 1_842_061),
        Download(file: "HUTUBS 1.sofa", name: "HUTUBS listener 1", source: "TU Berlin HUTUBS (CC BY)",
                 url: "https://sofacoustics.org/data/database/hutubs/pp1_HRIRs_measured.sofa", bytes: 1_659_720),
        Download(file: "SADIE H3.sofa", name: "SADIE II listener H3", source: "University of York SADIE II (Apache 2.0)",
                 url: "https://sofacoustics.org/data/database/sadie/H3_48K_24bit_256tap_FIR_SOFA.sofa", bytes: 11_656_471),
        Download(file: "Neumann KU100.sofa", name: "Neumann KU100 dummy head", source: "TH Köln (CC BY-SA)",
                 url: "https://sofacoustics.org/data/database/thk/HRIR_L2354.sofa", bytes: 3_002_887),
    ]

    static var catalogBytes: Int64 { catalog.reduce(0) { $0 + $1.bytes } }
    static var missingDownloads: [Download] {
        catalog.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
    }

    static func all() -> [HeadModel] {
        var list = [HeadModel(id: "apple", name: "Apple", detail: "The head model QuickTime and AirPods use")]
        if FileManager.default.fileExists(atPath: kemar.path) {
            list.append(HeadModel(id: kemar.path, name: "KEMAR dummy head", detail: "MIT, built in"))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.pathExtension.lowercased() == "sofa" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let known = catalog.first { $0.file == f.lastPathComponent }
            list.append(HeadModel(id: f.path, name: known?.name ?? f.deletingPathExtension().lastPathComponent,
                                  detail: known?.source ?? "Added by you"))
        }
        return list
    }

    static func name(of spec: String) -> String {
        all().first { $0.id == spec }?.name ?? (spec == "apple" ? "Apple" : URL(fileURLWithPath: spec).deletingPathExtension().lastPathComponent)
    }

    /// What the engine gets for --hrtf: the file if it still exists, otherwise Apple's head.
    static func engineSpec(_ spec: String) -> String {
        spec != "apple" && FileManager.default.fileExists(atPath: spec) ? spec : "apple"
    }

    /// Copies a SOFA file the person chose into the heads folder.
    @discardableResult
    static func add(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        if dest.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        }
        _ = try HRIRSet.sofa(dest, [HRIRSet.Direction(az: 0, el: 0)]) // readable?
        return dest
    }

    /// Downloads the catalog heads that aren't here yet. `progress` gets 0…1.
    static func downloadMissing(progress: @escaping @MainActor (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let todo = missingDownloads
        let total = Double(todo.reduce(0) { $0 + $1.bytes })
        var done = 0.0
        for d in todo {
            guard let url = URL(string: d.url) else { continue }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Shell.Failure(message: "Couldn't download \(d.name) (the database didn't answer).")
            }
            let dest = folder.appendingPathComponent(d.file)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            done += Double(d.bytes)
            await progress(done / max(total, 1))
        }
    }
}
