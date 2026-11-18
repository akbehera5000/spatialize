import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Which head sounds like mine?": short noise bursts from known directions through each head
/// model; you mark where each one seemed to come from, and the head you placed most accurately wins.
@MainActor
final class HeadTest: ObservableObject {
    enum Phase: Equatable { case intro, loading, trial, results }

    struct Trial {
        var head: Int
        var dir: Int
        var seed: UInt64
        var answer: HRIRSet.Direction?
    }

    struct Score: Identifiable {
        var id: String { head.id }
        var head: HeadModel
        var meanError: Double
        var frontBack: Int
        var count: Int
    }

    /// Directions the test sounds come from: around, above and a little below.
    nonisolated static let pool: [HRIRSet.Direction] = [
        .init(az: 0, el: 0), .init(az: 180, el: 0), .init(az: 50, el: 0), .init(az: -50, el: 0),
        .init(az: 130, el: 0), .init(az: -130, el: 0), .init(az: 0, el: 45), .init(az: 180, el: 45),
        .init(az: 90, el: 50), .init(az: -90, el: 50), .init(az: 30, el: -25), .init(az: -150, el: -20),
    ]

    @Published var phase: Phase = .intro
    @Published var available: [HeadModel] = HeadModels.all()
    @Published var chosen: Set<String> = Set(HeadModels.all().map(\.id))
    @Published var perHead = 6
    @Published var trials: [Trial] = []
    @Published var index = 0
    @Published var answer: HRIRSet.Direction?
    @Published var error: String?
    @Published var downloading: Double?
    @Published var scores: [Score] = []

    private var heads: [HeadModel] = []
    private var sets: [HRIRSet] = []
    private let player = TestPlayer()

    func refresh() {
        available = HeadModels.all()
        chosen.formUnion(available.map(\.id))
        chosen = chosen.filter { id in available.contains { $0.id == id } }
    }

    func download() {
        downloading = 0
        Task {
            do {
                try await HeadModels.downloadMissing { self.downloading = $0 }
            } catch {
                self.error = error.localizedDescription
            }
            downloading = nil
            refresh()
        }
    }

    func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sofa") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose SOFA head models (HRTF files)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try HeadModels.add(url) } catch { self.error = "\(url.lastPathComponent): \(error)" }
        }
        refresh()
    }

    func start() {
        heads = available.filter { chosen.contains($0.id) }
        guard heads.count >= 2 else { error = "Choose at least two heads to compare."; return }
        phase = .loading
        error = nil
        let heads = heads
        Task {
            var loaded: [HRIRSet] = []
            for h in heads {
                do {
                    let set = try await Task.detached { try HRIRSet.load(h.id, HeadTest.pool) }.value
                    loaded.append(set)
                } catch {
                    self.error = "\(h.name) couldn't be read: \(error)"
                    self.phase = .intro
                    return
                }
            }
            sets = loaded
            // every head gets the same number of trials from a spread of directions, all interleaved
            var list: [Trial] = []
            for h in heads.indices {
                var dirs = Array(HeadTest.pool.indices).shuffled()
                while dirs.count < perHead { dirs += Array(HeadTest.pool.indices).shuffled() }
                for d in dirs.prefix(perHead) { list.append(Trial(head: h, dir: d, seed: .random(in: 1...UInt64.max))) }
            }
            trials = list.shuffled()
            index = 0
            answer = nil
            phase = .trial
            play()
        }
    }

    func play() {
        guard index < trials.count else { return }
        let t = trials[index]
        let sound = TestSound.bursts(seed: t.seed)
        let out = sets[t.head].render(sound, at: t.dir)
        player.play(left: out.left, right: out.right)
    }

    func next() {
        guard index < trials.count, let answer else { return }
        trials[index].answer = answer
        self.answer = nil
        index += 1
        if index >= trials.count { finish() } else { play() }
    }

    func stop() { player.stop() }

    private func finish() {
        player.stop()
        var out: [Score] = []
        for (h, head) in heads.enumerated() {
            let mine = trials.filter { $0.head == h && $0.answer != nil }
            guard !mine.isEmpty else { continue }
            var err = 0.0, fb = 0
            for t in mine {
                let truth = HeadTest.pool[t.dir], a = t.answer!
                err += angleBetween(truth, a)
                // heard in front when it was behind, or the other way round (not counting the sides)
                let tf = cos(Double(truth.az) * .pi / 180), af = cos(Double(a.az) * .pi / 180)
                if abs(tf) > 0.35 && abs(af) > 0.35 && (tf > 0) != (af > 0) { fb += 1 }
            }
            out.append(Score(head: head, meanError: err / Double(mine.count), frontBack: fb, count: mine.count))
        }
        scores = out.sorted { $0.meanError < $1.meanError }
        phase = .results
    }
}

struct HeadTestSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var test = HeadTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Find Your Head Model").font(.system(size: 20, weight: .bold))
                Spacer()
                Button(test.phase == .results ? "Done" : "Cancel") { test.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            switch test.phase {
            case .intro: intro
            case .loading:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Preparing the heads…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 300)
            case .trial: trial
            case .results: results
            }
            if let e = test.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onDisappear { test.stop() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everyone's ears shape sound differently, which is why one head model can sound right to one person and vague to another. You'll hear short bursts of noise from different directions and mark where each one seemed to come from. The head you place most accurately is the best match for you; it's then used for the binaural track and Listen Live.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Turn Spatial Audio off for Spatialize in Control Center → Sound, keep your head still and face the screen.", systemImage: "airpodspro")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Heads to compare").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 6) {
                ForEach(test.available) { h in
                    SwitchRow(title: h.name, detail: h.detail,
                              isOn: Binding(get: { test.chosen.contains(h.id) },
                                            set: { on in if on { test.chosen.insert(h.id) } else { test.chosen.remove(h.id) } }),
                              small: true)
                }
            }
            .frame(maxHeight: 260)
            HStack {
                if let p = test.downloading {
                    ProgressView(value: p).frame(width: 160)
                    Text("Downloading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if !HeadModels.missingDownloads.isEmpty {
                    Button("Download \(HeadModels.missingDownloads.count) Measured Heads (\(ByteCountFormatter.string(fromByteCount: HeadModels.missingDownloads.reduce(0) { $0 + $1.bytes }, countStyle: .file)))") {
                        test.download()
                    }
                    .buttonStyle(.glass)
                    .help("Free research recordings of real listeners' ears from sofacoustics.org (ARI, CIPIC, HUTUBS, SADIE II, TH Köln).")
                }
                Button("Add SOFA Files…") { test.addFile() }.buttonStyle(.glass)
                Spacer()
            }
            .controlSize(.small)
            HStack {
                Picker("", selection: $test.perHead) {
                    Text("Quick · 6 per head").tag(6)
                    Text("Thorough · 10 per head").tag(10)
                }
                .labelsHidden().frame(width: 200)
                Text("about \(max(1, test.chosen.count * test.perHead * 6 / 60)) min")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Start") { test.start() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(test.chosen.count < 2 || test.downloading != nil)
            }
        }
    }

    private var trial: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Sound \(test.index + 1) of \(test.trials.count)").font(.system(size: 13, weight: .semibold))
                Spacer()
                ProgressView(value: Double(test.index), total: Double(max(1, test.trials.count))).frame(width: 200)
            }
            Text("Where did it come from? Click the spot on the map. The middle is straight above you, the solid ring is ear level, outside it is below.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DomePicker(answer: $test.answer)
                .frame(width: 380, height: 380)
            HStack {
                Button { test.play() } label: { Label("Play Again", systemImage: "speaker.wave.2") }
                    .buttonStyle(.glass)
                    .keyboardShortcut("r", modifiers: [])
                Spacer()
                Button("Next") { test.next() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(test.answer == nil)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Average miss: how far your answers were from where the sound really was. Lower is better. Heads within about 5° of each other are equally good for you.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let worst = max(1, test.scores.map(\.meanError).max() ?? 1)
            ForEach(Array(test.scores.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.head.name).font(.system(size: 13, weight: i == 0 ? .bold : .medium))
                        Text("\(s.frontBack) front/back mix-up\(s.frontBack == 1 ? "" : "s") in \(s.count)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(width: 200, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color(red: 0.45, green: 0.62, blue: 1.0).opacity(i == 0 ? 0.9 : 0.5))
                                    .frame(width: max(8, g.size.width * s.meanError / worst))
                            }
                    }
                    .frame(height: 10)
                    Text(String(format: "%.0f°", s.meanError)).font(.system(size: 12).monospacedDigit()).frame(width: 36)
                    if app.settings.headModel == s.head.id {
                        Text("In use").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(.green.opacity(0.75), lineWidth: 1.2))
                            .frame(width: 70)
                    } else {
                        Button("Use") { app.settings.headModel = s.head.id; app.objectWillChange.send() }
                            .buttonStyle(.glass).controlSize(.small).frame(width: 70)
                    }
                }
            }
            HStack {
                Button("Test Again") { test.phase = .intro }.buttonStyle(.glass)
                Spacer()
            }
        }
        .onAppear {
            // the winner is used straight away; any other is one click
            if let best = test.scores.first { app.settings.headModel = best.head.id; app.objectWillChange.send() }
        }
    }
}
