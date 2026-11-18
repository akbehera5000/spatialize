import SwiftUI

/// Sets the overhead-cue strength and height-speaker angle for your ears: the height speakers play
/// with different cue strengths through Apple's head model (the one QuickTime uses), you say how
/// high each sounded, and the weakest cue that lifts them clearly above you is chosen.
@MainActor
final class HeightCalibration: ObservableObject {
    enum Phase: Equatable { case intro, loading, trial, results }

    struct Trial {
        var dir: Int          // index into `dirs`
        var boost: Double     // overhead cue, dB (0 for the ear-level references)
        var seed: UInt64
        var answer: Double?
    }

    static let boosts: [Double] = [0, 4, 8, 12]
    /// The four height speakers, then four ear-level references (to learn your own bias).
    nonisolated static let dirs: [HRIRSet.Direction] = [
        .init(az: 45, el: 45), .init(az: -45, el: 45), .init(az: 135, el: 45), .init(az: -135, el: 45),
        .init(az: 30, el: 0), .init(az: -30, el: 0), .init(az: 110, el: 0), .init(az: -110, el: 0),
    ]

    @Published var phase: Phase = .intro
    @Published var trials: [Trial] = []
    @Published var index = 0
    @Published var answer: Double?
    @Published var error: String?

    // results
    @Published var perceived: [Double: Double] = [:]   // boost → elevation heard above the references
    @Published var reference: Double = 0
    @Published var recommendedEQ: Double = 6
    @Published var recommendedAngle: Double = 60

    private var set: HRIRSet?
    private let player = TestPlayer()

    func start() {
        phase = .loading
        Task {
            do {
                set = try await Task.detached { try HRIRSet.apple(HeightCalibration.dirs) }.value
            } catch {
                self.error = "Couldn't prepare Apple's head model: \(error)"
                phase = .intro
                return
            }
            var list: [Trial] = []
            for d in 0..<4 { for b in Self.boosts { list.append(Trial(dir: d, boost: b, seed: .random(in: 1...UInt64.max))) } }
            for d in 4..<8 { list.append(Trial(dir: d, boost: 0, seed: .random(in: 1...UInt64.max))) }
            trials = list.shuffled()
            index = 0
            answer = nil
            phase = .trial
            play()
        }
    }

    func play() {
        guard let set, index < trials.count else { return }
        let t = trials[index]
        let sound = TestSound.heightCue(TestSound.bursts(seed: t.seed), db: t.boost)
        let out = set.render(sound, at: t.dir)
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
        let refs = trials.filter { $0.dir >= 4 }.compactMap(\.answer)
        reference = refs.isEmpty ? 0 : refs.reduce(0, +) / Double(refs.count)
        var p: [Double: Double] = [:]
        for b in Self.boosts {
            let a = trials.filter { $0.dir < 4 && $0.boost == b }.compactMap(\.answer)
            if !a.isEmpty { p[b] = a.reduce(0, +) / Double(a.count) - reference }
        }
        perceived = p
        // the weakest cue that puts the height speakers clearly above you (35° or more)
        let enough = Self.boosts.first { (p[$0] ?? 0) >= 35 }
        let best = Self.boosts.max { (p[$0] ?? 0) < (p[$1] ?? 0) } ?? 6
        recommendedEQ = enough ?? best
        // the ambisonic output can also raise the speakers to make up for what's still missing
        let heard = p[recommendedEQ] ?? 45
        recommendedAngle = min(75, max(45, (45 + (45 - heard)).rounded()))
        phase = .results
    }
}

struct HeightCalibrationSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cal = HeightCalibration()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Calibrate Height").font(.system(size: 20, weight: .bold))
                Spacer()
                Button(cal.phase == .results ? "Done" : "Cancel") { cal.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            switch cal.phase {
            case .intro:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Headphones make overhead sound hard to hear, and how much help your ears need differs from person to person. You'll hear 20 short sounds and mark how high each one seemed. Spatialize then picks the overhead-cue strength (and the height-speaker angle for the Ambisonic option) that works for your ears.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label("Uses Apple's head model, as QuickTime does. Turn Spatial Audio off for Spatialize in Control Center → Sound, and keep your head still.", systemImage: "airpodspro")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("About 2 minutes").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Start") { cal.start() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    }
                }
            case .loading:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Preparing…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .trial:
                VStack(spacing: 14) {
                    HStack {
                        Text("Sound \(cal.index + 1) of \(cal.trials.count)").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        ProgressView(value: Double(cal.index), total: Double(max(1, cal.trials.count))).frame(width: 200)
                    }
                    Text("How high was it? Click on the arc. Only the height matters, not whether it was in front or behind.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ElevationPicker(elevation: $cal.answer).frame(width: 340, height: 300)
                    HStack {
                        Button { cal.play() } label: { Label("Play Again", systemImage: "speaker.wave.2") }
                            .buttonStyle(.glass).keyboardShortcut("r", modifiers: [])
                        Spacer()
                        Button("Next") { cal.next() }
                            .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(cal.answer == nil)
                    }
                }
            case .results:
                results
            }
            if let e = cal.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { cal.stop() }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How high the height speakers sounded to you at each cue strength (above where ear-level sounds seemed, \(Int(cal.reference.rounded()))°):")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(HeightCalibration.boosts, id: \.self) { b in
                let e = cal.perceived[b] ?? 0
                HStack(spacing: 10) {
                    Text(b == 0 ? "No cue" : String(format: "+%.0f dB", b))
                        .font(.system(size: 12, weight: b == cal.recommendedEQ ? .bold : .regular)).frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color(red: 0.62, green: 0.45, blue: 1.0).opacity(b == cal.recommendedEQ ? 0.9 : 0.45))
                                    .frame(width: max(6, g.size.width * max(0, e) / 90))
                            }
                    }
                    .frame(height: 10)
                    Text("\(Int(e.rounded()))°").font(.system(size: 12).monospacedDigit()).frame(width: 40)
                }
            }
            Divider().opacity(0.5)
            Text(String(format: "Recommended: overhead cue +%.0f dB", cal.recommendedEQ)
                 + (app.settings.heightMode.usesAngle ? ", height speakers at \(Int(cal.recommendedAngle))°" : "") + ".")
                .font(.system(size: 13, weight: .semibold))
            if (cal.perceived[cal.recommendedEQ] ?? 0) < 35 {
                Text("Even the strongest cue didn't lift the sound far above you. That's common with a generic head; the Ambisonic option with a higher speaker angle can help, or try Find Your Head Model.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Test Again") { cal.phase = .intro }.buttonStyle(.glass)
                Spacer()
                Button("Use These Settings") {
                    let s = app.settings
                    if s.heightMode == .off { s.heightMode = .eq }
                    s.heightEQ = cal.recommendedEQ
                    s.heightAngle = cal.recommendedAngle
                    app.objectWillChange.send()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
