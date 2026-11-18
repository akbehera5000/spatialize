import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sound

struct SoundSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings

    var body: some View {
        GlassCard(title: "Sound", symbol: "slider.horizontal.3") {
            ValueSlider(title: "Dialogue", value: $settings.dialogueDB, range: -3...9, step: 0.5,
                        format: { $0 == 0 ? "As mixed" : String(format: "%+.1f dB", $0) },
                        minLabel: "Softer", maxLabel: "Clearer",
                        detail: "Raises the centre channel, where nearly every film keeps its dialogue.")
            ValueSlider(title: "Bass (LFE)", value: $settings.lfeDB, range: -12...6, step: 0.5,
                        format: { $0 == 0 ? "As mixed" : String(format: "%+.1f dB", $0) },
                        minLabel: "Less", maxLabel: "More")

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text("Room").font(.system(size: 13, weight: .medium))
                Picker("", selection: $settings.roomPreset.animation(.snappy)) {
                    ForEach(RoomPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Adds the reflections of a real room so the sound feels like it's around you, not inside your head.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.roomPreset != .off {
                    ValueSlider(title: "Room amount", value: $settings.roomAmount, range: 0.25...2, step: 0.05,
                                format: { "\(Int(($0 * 100).rounded()))%" }, minLabel: "Hint", maxLabel: "Lots")
                        .transition(.opacity)
                }
            }

            Divider().opacity(0.5)

            HeadphoneEQ(settings: settings)

            Divider().opacity(0.5)

            SwitchRow(title: "Night mode",
                      detail: "Softens explosions and lifts quiet dialogue, for late-night watching.",
                      isOn: $settings.nightMode)
            SwitchRow(title: "Match loudness",
                      detail: "Measures the whole film first (a few extra minutes), then sets it to a standard level so films play at a similar volume.",
                      isOn: $settings.normalizeLoudness.animation(.snappy))
            if settings.normalizeLoudness {
                ValueSlider(title: "Target", value: $settings.loudnessTarget, range: -31 ... -16, step: 1,
                            format: { "\(Int($0)) LUFS" }, minLabel: "Quieter", maxLabel: "Louder",
                            detail: "−24 is the broadcast standard for films. Peaks are kept below −1 dB.")
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: settings.roomPreset)
        .disabled(app.conversion.isRunning)
    }
}

// MARK: - Headphone EQ

/// Ten-band EQ applied to the whole mix before encoding (and in Listen Live).
struct HeadphoneEQ: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Headphone EQ").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: Binding(get: { settings.eqPreset }, set: { p in
                    settings.eqPreset = p
                    if let g = p.gains { settings.eqGains = g }
                })) {
                    ForEach(EQPreset.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(gainText(settings.eqGains[i]))
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(settings.eqGains[i] == 0 ? .secondary : .primary)
                        BandSlider(value: Binding(get: { settings.eqGains[i] }, set: { v in
                            var g = settings.eqGains
                            g[i] = v
                            settings.eqGains = g
                            settings.eqPreset = EQPreset.allCases.first { $0.gains == g } ?? .custom
                        }))
                        .frame(width: 22, height: 90)
                        Text(EQPreset.bands[i]).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("AirPods Pro 2 already tune themselves with Adaptive EQ, so Flat is the accurate choice. Use this to taste; boosts are kept clear of clipping by the limiter.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gainText(_ v: Double) -> String { v == 0 ? "0" : String(format: "%+.1f", v) }
}

/// A vertical ±12 dB slider with a centre line.
private struct BandSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { g in
            let h: CGFloat = g.size.height
            let travel: CGFloat = h / 2 - 7
            let y: CGFloat = h / 2 - CGFloat(value) / 12 * travel
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 4).frame(maxWidth: .infinity)
                Rectangle().fill(.white.opacity(0.25)).frame(width: 12, height: 1).offset(y: h / 2)
                Capsule().fill(Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.7))
                    .frame(width: 4, height: abs(y - h / 2))
                    .offset(y: min(y, h / 2))
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1).offset(y: y - 7)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let v = Double((h / 2 - d.location.y) / travel * 12)
                value = (max(-12, min(12, v)) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

// MARK: - Audio sync

struct SyncControl: View {
    @Binding var ms: Double
    var range: ClosedRange<Double> = -2000...2000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Audio sync").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(label)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: ms)
                Stepper("", value: $ms, in: range, step: 10).labelsHidden()
                Button("Reset") { ms = 0 }.buttonStyle(.glass).controlSize(.small).disabled(ms == 0)
            }
            Slider(value: $ms, in: range, step: 10) {
                EmptyView()
            } minimumValueLabel: {
                Text("Earlier").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Later").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text("Use this when the film's own audio is out of step with the picture. Try it on a scene preview first. Lips moving before you hear the words: move the audio earlier.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var label: String {
        ms == 0 ? "In sync" : ms > 0 ? "\(Int(ms)) ms later" : "\(Int(-ms)) ms earlier"
    }
}

// MARK: - Scene preview

struct SceneSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    @ObservedObject var preview: Conversion
    let info: MediaInfo
    @State private var frame: NSImage?
    @State private var frameTask: Task<Void, Never>?

    var body: some View {
        GlassCard(title: "Scene Preview", symbol: "play.rectangle") {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    if let img = frame ?? app.thumbnail {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.black.opacity(0.25))
                    }
                }
                .frame(width: 224, height: 126)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(app.previewStart.clock)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .glassEffect(.regular, in: Capsule())
                        .padding(7)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Hear a scene with your settings before converting the whole film. It takes well under a minute.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Slider(value: $app.previewStart, in: 0...max(1, info.duration - settings.previewLength)) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0:00").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text(info.duration.clock).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } onEditingChanged: { editing in
                        if !editing { loadFrame() }
                    }
                    HStack(spacing: 10) {
                        Picker("", selection: $settings.previewLength) {
                            Text("15 s").tag(15.0)
                            Text("30 s").tag(30.0)
                            Text("1 min").tag(60.0)
                            Text("2 min").tag(120.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                        Stepper("", onIncrement: { nudge(10) }, onDecrement: { nudge(-10) }).labelsHidden()
                            .help("Move 10 seconds")
                        Spacer(minLength: 0)
                    }
                }
            }

            HStack(spacing: 10) {
                if preview.isRunning {
                    ProgressView(value: min(1, preview.overall)).progressViewStyle(.linear).frame(maxWidth: 220)
                    Text(preview.audio.stage).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { preview.cancel() }.buttonStyle(.glass)
                } else {
                    if case .failed(let m) = preview.state {
                        Label(m, systemImage: "exclamationmark.triangle").font(.system(size: 11.5))
                            .foregroundStyle(.orange).lineLimit(2)
                    } else if settings.normalizeLoudness {
                        Text("Loudness matching isn't applied to previews.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        app.makePreview(live: true)
                    } label: {
                        Label("Listen Live", systemImage: "headphones")
                    }
                    .buttonStyle(.glass)
                    .help("Plays the scene inside Spatialize with head tracking and shows where every sound is")
                    Button {
                        app.makePreview()
                    } label: {
                        Label("Preview in QuickTime", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .disabled(app.conversion.isRunning)
        .onAppear { if frame == nil { loadFrame() } }
    }

    private func nudge(_ s: Double) {
        app.previewStart = min(max(0, app.previewStart + s), max(0, info.duration - settings.previewLength))
        loadFrame()
    }

    private func loadFrame() {
        frameTask?.cancel()
        let t = app.previewStart + min(5, settings.previewLength / 2)
        frameTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let img = await AppState.frame(info, at: t, width: 640)
            if !Task.isCancelled, let img { frame = img }
        }
    }
}

// MARK: - Queue

struct QueueSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var queue: JobQueue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue").font(.system(size: 20, weight: .bold))
                Spacer()
                Button("Clear Finished") { queue.clearFinished() }
                    .disabled(!queue.jobs.contains { if case .waiting = $0.state { return false }; return $0.state != .running })
            }
            Text("Movies here convert one after another with the settings they were added with. Drop several movies on the window to queue them all.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if queue.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("Nothing queued").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(queue.jobs) { job in row(job) }
                    }
                }
                .frame(minHeight: 160, maxHeight: 380)
            }
            HStack {
                Text(diskText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private var diskText: String {
        let waiting = queue.jobs.filter { $0.state == .waiting || $0.state == .running }
        guard let first = waiting.first else { return "" }
        let peak = waiting.map(\.needed).max() ?? 0
        let free = (try? first.output.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let p = ByteCountFormatter.string(fromByteCount: peak, countStyle: .file)
        return "Each movie needs up to \(p) while converting · \(f) free"
    }

    @ViewBuilder private func row(_ job: JobQueue.Job) -> some View {
        HStack(spacing: 12) {
            Group {
                switch job.state {
                case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                switch job.state {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView(value: min(1, queue.runner.overall)).progressViewStyle(.linear).frame(width: 160)
                        Text(queue.runner.video.stage).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .failed(let m): Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                case .done(let url):
                    HStack(spacing: 6) {
                        if let s = job.sync { SyncBadge(result: s, compact: true) }
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .waiting: Text("Waiting · \(job.output.lastPathComponent)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                case .cancelled: Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .done(let url) = job.state, let s = job.sync, s.status == .off {
                Button("Fix Sync…") { app.fixSync(url, measured: s) }.buttonStyle(.glass)
            }
            if case .done(let url) = job.state {
                Button { app.play(url) } label: { Image(systemName: "play.fill") }.buttonStyle(.glass).help("Play in QuickTime")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.glass).help("Show in Finder")
            }
            Button { queue.remove(job) } label: {
                Image(systemName: job.state == .running ? "stop.fill" : "xmark")
            }
            .buttonStyle(.glass)
            .help(job.state == .running ? "Cancel this conversion" : "Remove from the queue")
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Fix the sync of a finished movie

struct ResyncSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var movie: URL?
    @State private var ms: Double = 0
    @State private var measured: Bool = false
    @State private var working = false
    @State private var result: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust Audio Sync").font(.system(size: 20, weight: .bold))
            Text("Moves the sound of a movie Spatialize already made, without converting it again. It saves a copy and takes about as long as copying the file.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "film").foregroundStyle(.secondary)
                Text(movie?.lastPathComponent ?? "No movie chosen").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { choose() }.buttonStyle(.glass)
            }
            .padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if measured {
                Label("Pre-set to the correction the sync check measured.", systemImage: "waveform.badge.checkmark")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            SyncControl(ms: $ms)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if let result {
                Label("Saved \(result.lastPathComponent)", systemImage: "checkmark.circle").font(.system(size: 12))
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary) }
                Spacer()
                Button("Close") { dismiss() }
                if let result {
                    Button("Play in QuickTime") { app.play(result) }.buttonStyle(.glass)
                }
                Button("Save Copy") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(movie == nil || ms == 0 || working)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            if let p = app.resyncPreset {
                movie = p.url; ms = (p.ms / 10).rounded() * 10; measured = true
                app.resyncPreset = nil
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.message = "Choose a movie made by Spatialize"
        if panel.runModal() == .OK { movie = panel.url; result = nil; error = nil }
    }

    private func save() {
        guard let movie else { return }
        working = true; error = nil; result = nil
        Task {
            do { result = try await app.resync(movie, by: ms) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

// MARK: - Sync verdict

/// The sync check's verdict. The state colour is only on the outline: green when in sync,
/// red-grey when something is off.
struct SyncBadge: View {
    let result: SyncResult
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(compact ? short : result.headline).font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 2 : 4)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(outline, lineWidth: 1.2)
        }
        .help(result.detail)
    }

    private var short: String {
        switch result.status {
        case .ok: "In sync"
        case .off: String(format: "%+.0f ms", result.offsetMs)
        case .drift: "Drifts"
        case .unknown: "Not checked"
        }
    }
    private var icon: String {
        switch result.status {
        case .ok: "checkmark"
        case .off, .drift: "exclamationmark"
        case .unknown: "questionmark"
        }
    }
    private var outline: Color {
        switch result.status {
        case .ok: .green.opacity(0.75)
        case .off, .drift: Color(red: 0.85, green: 0.35, blue: 0.35).opacity(0.8)
        case .unknown: .white.opacity(0.25)
        }
    }
}
