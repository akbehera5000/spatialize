import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            if let info = app.info {
                Editor(info: info, settings: app.settings, conversion: app.conversion)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                EmptyState(targeted: dropTargeted)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop(image: app.thumbnail) }
        .animation(.smooth(duration: 0.45), value: app.info?.url)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            app.open(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .frame(minWidth: 900, minHeight: 680)
        .preferredColorScheme(.dark)
        .alert("Can't open this file", isPresented: .constant(app.loadError != nil)) {
            Button("OK") { app.loadError = nil }
        } message: {
            Text(app.loadError ?? "")
        }
        .alert(item: $app.diskWarning) { w in
            let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return Alert(title: Text("Not enough free space"),
                         message: Text("Converting this movie needs about \(f(w.needed)) on the disk with \(w.folder.lastPathComponent), and \(f(w.free)) is free. Most of it is temporary and is removed when the conversion finishes."),
                         primaryButton: .cancel(Text("Cancel")),
                         secondaryButton: .destructive(Text("Convert Anyway")) { app.convert(skipDiskCheck: true) })
        }
        .sheet(isPresented: $app.showQueue) { QueueSheet(queue: app.queue) }
        .sheet(isPresented: $app.showResync) { ResyncSheet() }
        .sheet(isPresented: $app.showLive) { LivePlayerView(app: app) }
        .sheet(isPresented: $app.showHeadTest) { HeadTestSheet() }
        .sheet(isPresented: $app.showCalibration) { HeightCalibrationSheet() }
        .overlay(alignment: .top) { LeftoverBanners() }
    }
}

/// Interrupted conversions that can pick up where they stopped, and a note about cleaned-up space.
struct LeftoverBanners: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 8) {
            ForEach(app.interrupted) { job in
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(job.title) was interrupted").font(.system(size: 12.5, weight: .semibold))
                        Text("\(job.finishedText.prefix(1).uppercased() + job.finishedText.dropFirst()) · \(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)) kept")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Button("Discard") { app.discard(job) }.buttonStyle(.glass).controlSize(.small)
                    Button("Resume") { app.resume(job) }.buttonStyle(.glassProminent).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: 620)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if app.cleanedBytes > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                    Text("Removed \(ByteCountFormatter.string(fromByteCount: app.cleanedBytes, countStyle: .file)) of temporary files left by interrupted conversions.")
                        .font(.system(size: 12))
                    Button { app.cleanedBytes = 0 } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .task {
                    try? await Task.sleep(for: .seconds(12))
                    withAnimation { app.cleanedBytes = 0 }
                }
            }
        }
        .padding(.top, 14)
        .animation(.snappy, value: app.interrupted)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    @EnvironmentObject var app: AppState
    var targeted: Bool

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle().fill(.white.opacity(0.04)).frame(width: 150, height: 150)
                Image(systemName: app.loading ? "waveform" : "airpodspro")
                    .font(.system(size: 64, weight: .light))
                    .symbolEffect(.variableColor.iterative, isActive: app.loading)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .glassEffect(.regular, in: Circle())

            VStack(spacing: 8) {
                Text(app.loading ? "Reading movie…" : "Drop a movie here")
                    .font(.system(size: 30, weight: .bold))
                Text("Dolby Atmos, TrueHD, Dolby Digital Plus or any MKV. Spatialize turns it into a\nQuickTime movie with Spatial Audio and head tracking for AirPods.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                openPanel()
            } label: {
                Label("Choose Movie…", systemImage: "folder").padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut("o")
            .disabled(app.loading)
        }
        .padding(60)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.white.opacity(targeted ? 0.6 : 0))
                .padding(10)
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.snappy, value: targeted)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a movie with Dolby audio"
        if panel.runModal() == .OK, let url = panel.url { app.open(url) }
    }
}

// MARK: - Editor

/// The editor's cards without the scroll view, for headless layout snapshots.
struct SnapshotEditor: View {
    @EnvironmentObject var app: AppState
    let info: MediaInfo
    @ObservedObject var settings: Settings
    @ObservedObject var conversion: Conversion

    var body: some View {
        let contentWidth: CGFloat = 1120 - 52
        VStack(spacing: 18) {
            MovieHeader(info: info)
            HStack(alignment: .top, spacing: 18) {
                AudioSection(settings: settings, info: info).frame(width: (contentWidth - 18) / 2)
                VStack(spacing: 18) {
                    VideoSection(settings: settings, info: info)
                    SubtitleSection(settings: settings, info: info)
                }
                .frame(width: (contentWidth - 18) / 2)
            }
            HStack(alignment: .top, spacing: 18) {
                SoundSection(settings: settings).frame(width: (contentWidth - 18) / 2)
                SceneSection(settings: settings, preview: app.preview, info: info).frame(width: (contentWidth - 18) / 2)
            }
            SpeakerLayoutSection(settings: settings)
            OutputSection(settings: settings)
            ActionBar(conversion: conversion, settings: settings)
        }
        .frame(width: contentWidth)
        .padding(26)
    }
}

struct Editor: View {
    @EnvironmentObject var app: AppState
    let info: MediaInfo
    @ObservedObject var settings: Settings
    @ObservedObject var conversion: Conversion
    @State private var width: CGFloat = 1100
    private var wide: Bool { width > 1000 }
    private var contentWidth: CGFloat { max(300, min(width, 1180) - 52) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MovieHeader(info: info)
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        AudioSection(settings: settings, info: info)
                            .frame(width: (contentWidth - 18) / 2)
                            
                        VStack(spacing: 18) {
                            VideoSection(settings: settings, info: info)
                            SubtitleSection(settings: settings, info: info)
                        }
                        .frame(width: (contentWidth - 18) / 2)
                        
                    }
                } else {
                    VStack(spacing: 18) {
                        AudioSection(settings: settings, info: info)
                        VideoSection(settings: settings, info: info)
                        SubtitleSection(settings: settings, info: info)
                    }
                }
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        SoundSection(settings: settings).frame(width: (contentWidth - 18) / 2)
                        SceneSection(settings: settings, preview: app.preview, info: info).frame(width: (contentWidth - 18) / 2)
                    }
                } else {
                    SoundSection(settings: settings)
                    SceneSection(settings: settings, preview: app.preview, info: info)
                }
                SpeakerLayoutSection(settings: settings).id("speakers")
                OutputSection(settings: settings)
            }
            .frame(width: contentWidth)
            .padding(.top, 8)
            .padding(.bottom, 130)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            width = $0
        }
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["SPATIALIZE_SCROLL_BOTTOM"] != nil ? .bottom : .top)
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom) {
            ActionBar(conversion: conversion, settings: settings)
                .frame(width: contentWidth)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Action bar

struct ActionBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var conversion: Conversion
    @ObservedObject var settings: Settings
    @State private var showLog = false

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .sheet(isPresented: $showLog) { LogSheet(lines: conversion.log) }
        .onChange(of: conversion.state) { _, state in
            if case .done(let url) = state {
                NSSound(named: "Glass")?.play()
                if settings.openWhenDone { app.play(url) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch conversion.state {
        case .idle, .cancelled:
            VStack(alignment: .leading, spacing: 3) {
                Text(summaryTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(summaryDetail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if conversion.state == .cancelled {
                Text("Cancelled").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            QueueButton(queue: app.queue)
            Button {
                app.addToQueue()
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus").padding(.horizontal, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("Convert this movie after the ones already queued (⇧⌘↩)")
            Button {
                app.convert()
            } label: {
                Label("Create Spatial Movie", systemImage: "airpodspro")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color(red: 0.16, green: 0.42, blue: 1.0))
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)

        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(conversion.startedAt)
                let p = conversion.overall
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        LaneRow(symbol: "waveform", title: "Audio", lane: conversion.audio)
                        LaneRow(symbol: "film", title: "Video", lane: conversion.video)
                        if conversion.subs.stage != "Waiting" {
                            Label(conversion.subs.stage, systemImage: "captions.bubble")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(p * 100))%").font(.system(size: 22, weight: .bold).monospacedDigit())
                            .contentTransition(.numericText()).animation(.snappy, value: Int(p * 100))
                        Text(eta(elapsed: elapsed, progress: p)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 120, alignment: .trailing)
                    Button(role: .cancel) { conversion.cancel() } label: { Text("Cancel").padding(.horizontal, 4) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }

        case .done(let url):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Spatial movie ready").font(.system(size: 14, weight: .semibold))
                    if let s = SyncResult.summary(conversion.sync) { SyncBadge(result: s) }
                }
                if let s = SyncResult.summary(conversion.sync), s.status != .ok {
                    Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("\(url.lastPathComponent) · made in \(conversion.finishedAt.timeIntervalSince(conversion.startedAt).clock)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let s = SyncResult.summary(conversion.sync), s.status == .off {
                Button("Fix Sync…") { app.fixSync(url, measured: s) }
                    .buttonStyle(.glass).controlSize(.large)
            }
            QueueButton(queue: app.queue)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.glass).controlSize(.large)
            Button { app.play(url) } label: { Label("Play in QuickTime", systemImage: "play.fill").padding(.horizontal, 4) }
                .buttonStyle(.glassProminent).controlSize(.large)

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversion failed").font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Show Details") { showLog = true }.buttonStyle(.glass).controlSize(.large)
            Button("Try Again") { app.convert() }.buttonStyle(.glassProminent).controlSize(.large)
        }
    }

    private var summaryTitle: String {
        guard let info = app.info, let t = info.audio.first(where: { $0.id == app.audioTrack }) else { return "" }
        return "Spatial Audio from \(t.languageName) \(t.codecName)\(t.isAtmos ? " Atmos" : "")"
    }

    private var summaryDetail: String {
        var parts = [app.videoPlan.text]
        if settings.keepOtherAudio, !app.extraAudio.subtracting([app.audioTrack]).isEmpty {
            parts.append("\(app.extraAudio.subtracting([app.audioTrack]).count) more language(s)")
        }
        if settings.includeSubtitles, !app.subtitles.isEmpty { parts.append("\(app.subtitles.count) subtitle track(s)") }
        return parts.joined(separator: " · ")
    }

    private func eta(elapsed: TimeInterval, progress: Double) -> String {
        guard progress > 0.03, elapsed > 5 else { return "Elapsed \(elapsed.clock)" }
        let remaining = elapsed / progress - elapsed
        return "About \(remaining.clock) left"
    }
}

struct LaneRow: View {
    var symbol: String
    var title: String
    var lane: Conversion.Lane

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: lane.finished ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(lane.finished ? .green : .secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12, weight: .semibold)).frame(width: 42, alignment: .leading)
            ProgressView(value: min(1, lane.progress))
                .progressViewStyle(.linear)
                .frame(minWidth: 160)
            Text(lane.stage).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 220, alignment: .leading)
        }
    }
}

struct LogSheet: View {
    var lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversion details").font(.headline)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 420)
    }
}

/// Opens the queue; shows how many movies are waiting.
struct QueueButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var queue: JobQueue

    var body: some View {
        if !queue.jobs.isEmpty {
            Button {
                app.showQueue = true
            } label: {
                HStack(spacing: 6) {
                    if queue.runner.isRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "list.bullet") }
                    Text(queue.pending > 0 ? "\(queue.pending) queued" : "Queue")
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
        }
    }
}
