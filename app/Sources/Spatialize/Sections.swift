import AppKit
import SwiftUI

// MARK: - Movie header

struct MovieHeader: View {
    @EnvironmentObject var app: AppState
    let info: MediaInfo

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                if let img = app.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.black.opacity(0.25))
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 208, height: 117)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))

            VStack(alignment: .leading, spacing: 10) {
                Text(info.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                Text(info.url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(info.url.path)
                FlowChips(info: info)
            }
            Spacer(minLength: 0)
            Button {
                app.close()
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Close this movie")
            .disabled(app.conversion.isRunning)
        }
        .padding(18)
        .staticGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous), darkness: 0.28)
    }
}

private struct FlowChips: View {
    let info: MediaInfo

    var body: some View {
        let v = info.video!
        HStack(spacing: 6) {
            Chip(text: v.height >= 2000 ? "4K" : v.height >= 1400 ? "1440p" : v.height >= 1000 ? "1080p" : "\(v.height)p")
            if let dv = v.dolbyVisionProfile { Chip(text: "Dolby Vision \(dv)") }
            if v.isHDR { Chip(text: v.transfer == "arib-std-b67" ? "HLG" : "HDR10") }
            Chip(text: v.codec.uppercased())
            if info.duration > 0 { Chip(text: info.duration.clock, symbol: "clock") }
            if info.fileSize > 0 { Chip(text: ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file)) }
            if info.videoPlaysAsIs {
                Chip(text: "QuickTime-ready video", symbol: "checkmark", tone: .good)
            } else {
                Chip(text: "Video needs converting", symbol: "arrow.triangle.2.circlepath", tone: .warn)
                    .help("This Mac can't play \(v.codec.uppercased()) video in QuickTime, so it will be converted.")
            }
        }
    }
}

// MARK: - Audio

struct AudioSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    let info: MediaInfo

    var body: some View {
        GlassCard(title: "Spatial Audio", symbol: "airpodspro") {
            SettingRow(title: "Source track",
                       detail: sourceDetail) {
                Picker("", selection: $app.audioTrack) {
                    ForEach(info.audio) { t in
                        Text("\(t.languageName) · \(t.codecName)\(t.isAtmos ? " Atmos" : "") \(t.channelName)").tag(t.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .disabled(app.conversion.isRunning)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Height enhancement").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Calibrate for My Ears…") { app.showCalibration = true }
                        .buttonStyle(.glass).controlSize(.small)
                        .help("A two-minute listening test that sets the overhead cue strength for you.")
                }
                Picker("", selection: $settings.heightMode) {
                    ForEach(HeightMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.heightMode.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.heightMode.usesEQ {
                ValueSlider(title: "Overhead cue strength", value: $settings.heightEQ, range: 0...12, step: 0.5,
                            format: { String(format: "+%.1f dB", $0) }, minLabel: "Subtle", maxLabel: "Strong",
                            detail: settings.heightEQ > 10 ? "Very strong settings can make the height speakers sound hissy." : nil)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if settings.customLayout {
                Label("Speaker directions come from your custom placement below.", systemImage: "hifispeaker.2")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if settings.heightMode.usesAngle {
                ValueSlider(title: "Height speaker elevation", value: $settings.heightAngle, range: 30...85, step: 1,
                            format: { "\(Int($0))°" }, minLabel: "30°", maxLabel: "85°")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if app.selectedTrackIsAtmosTrueHD {
                SwitchRow(title: "Precise object placement",
                          detail: settings.directObjects
                            ? "Each Atmos object goes straight into a 360° sound field at its exact position, instead of being mixed between speakers. Uses the ambisonic output."
                            : "Atmos objects are mixed between the 7.1.4 speakers, as a home cinema would play them.",
                          isOn: $settings.directObjects.animation(.snappy))
            }

            Divider().opacity(0.5)

            SyncControl(ms: $app.syncMs)

            Divider().opacity(0.5)

            SettingRow(title: "Audio quality", detail: "Apple Positional Audio Codec. 1.5 Mbps is transparent for most films.") {
                Picker("", selection: $settings.audioBitrate) {
                    Text("Standard · 768 kbps").tag(768_000)
                    Text("High · 1.5 Mbps").tag(1_536_000)
                    Text("Very High · 2.3 Mbps").tag(2_304_000)
                    Text("Maximum · 3 Mbps").tag(3_072_000)
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 10) {
                Text("For IINA, VLC and other players").font(.system(size: 13, weight: .medium))
                Picker("", selection: $settings.compatMode.animation(.snappy)) {
                    ForEach(CompatMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.compatMode.detail + (settings.compatMode == .none ? "" : " QuickTime still plays Spatial Audio. In IINA, set Settings → Codec → Preferred language so it picks this track."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.compatMode == .binaural || settings.compatMode == .both {
                    HeadModelRow(settings: settings)
                        .transition(.opacity)
                }
            }

            if info.audio.count > 1 {
                Divider().opacity(0.5)
                SwitchRow(title: "Keep other languages",
                          detail: "Added as AAC tracks you can switch to in QuickTime's View → Languages menu.",
                          isOn: $settings.keepOtherAudio.animation(.snappy))
                if settings.keepOtherAudio {
                    VStack(spacing: 8) {
                        ForEach(info.audio.filter { $0.id != app.audioTrack }) { t in
                            TrackToggle(title: t.languageName,
                                        subtitle: "\(t.codecName) \(t.channelName)\(t.title.isEmpty ? "" : " · \(t.title)")",
                                        isOn: binding(for: t.id))
                        }
                    }
                    .padding(.leading, 4)
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy, value: settings.heightMode)
        .disabled(app.conversion.isRunning)
    }

    private var sourceDetail: String {
        guard let t = info.audio.first(where: { $0.id == app.audioTrack }) else { return "" }
        if t.isAtmos && (t.codec == "truehd" || t.codec == "eac3") {
            return "Atmos objects are decoded and placed in 3D around you, with head tracking."
        }
        if t.channels > 2 { return "\(t.channelName) channels are placed around you, with head tracking." }
        return "Stereo has no surround information, so the sound stays in front of you."
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(get: { app.extraAudio.contains(id) },
                set: { on in if on { app.extraAudio.insert(id) } else { app.extraAudio.remove(id) } })
    }
}

/// The head model used for the binaural track and Listen Live, with the test to find yours.
struct HeadModelRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    @State private var heads = HeadModels.all()

    var body: some View {
        HStack {
            Text("Head model").font(.system(size: 12.5, weight: .medium))
            Picker("", selection: $settings.headModel) {
                ForEach(heads) { Text($0.name).tag($0.id) }
                if !heads.contains(where: { $0.id == settings.headModel }) {
                    Text(HeadModels.name(of: settings.headModel)).tag(settings.headModel)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
            Button("Find My Head…") { app.showHeadTest = true }
                .buttonStyle(.glass).controlSize(.small)
                .help("A listening test that compares head models and picks the one you hear most accurately.")
        }
        .onAppear { heads = HeadModels.all() }
        .onChange(of: app.showHeadTest) { _, open in if !open { heads = HeadModels.all() } }
    }
}

// MARK: - Video

struct VideoSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    let info: MediaInfo

    var body: some View {
        let plan = app.videoPlan
        let v = info.video!
        GlassCard(title: "Video", symbol: "film") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $settings.videoMode.animation(.snappy)) {
                    ForEach(VideoMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 6) {
                    Image(systemName: plan.convert ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    Text(plan.text)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                if settings.videoMode == .copy && !info.videoPlaysAsIs {
                    Label("This Mac can't play \(v.codec.uppercased()) in QuickTime. The movie won't play unless you convert.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
            }

            if plan.convert {
                Divider().opacity(0.5)
                ValueSlider(title: "Quality", value: $settings.videoQuality, range: 35...90, step: 1,
                            format: { q in
                                q >= 80 ? "Archival \(Int(q))" : q >= 68 ? "High \(Int(q))" : q >= 55 ? "Balanced \(Int(q))" : "Compact \(Int(q))"
                            },
                            minLabel: "Smaller", maxLabel: "Better",
                            detail: "Hardware HEVC encoding on Apple silicon. 60–65 looks the same as the original for most films.")
                SettingRow(title: "Resolution") {
                    Picker("", selection: $settings.maxHeight) {
                        Text("Original (\(v.height)p)").tag(0)
                        if v.height > 1600 { Text("1440p").tag(1440) }
                        if v.height > 1100 { Text("1080p").tag(1080) }
                        if v.height > 760 { Text("720p").tag(720) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)
                }
                if v.isHDR {
                    SwitchRow(title: "Keep HDR",
                              detail: settings.videoMode == .h264
                                ? "H.264 can't carry HDR; it will be tone-mapped to SDR."
                                : "10-bit HDR10\(v.dolbyVisionProfile != nil ? ". Dolby Vision dynamic metadata isn't kept when converting." : ".") Turn off to tone-map for SDR screens.",
                              isOn: $settings.keepHDR,
                              enabled: settings.videoMode != .h264)
                }
            }
        }
        .disabled(app.conversion.isRunning)
    }
}

// MARK: - Subtitles

struct SubtitleSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    let info: MediaInfo
    @State private var showPictures = false

    var body: some View {
        GlassCard(title: "Subtitles", symbol: "captions.bubble") {
            if info.subtitles.isEmpty {
                Text("This movie has no subtitles.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                SwitchRow(title: "Include subtitles",
                          detail: "Off by default; turn on in QuickTime's View → Subtitles menu.",
                          isOn: $settings.includeSubtitles.animation(.snappy))
                if settings.includeSubtitles {
                    VStack(spacing: 8) {
                        ForEach(info.subtitles.filter(\.isText)) { s in
                            TrackToggle(title: s.languageName + (s.forced ? " (Forced)" : ""),
                                        subtitle: "\(s.formatName)\(s.title.isEmpty ? "" : " · \(s.title)")",
                                        isOn: binding(for: s.id))
                        }
                        let pictures = info.subtitles.filter { !$0.isText }
                        if !pictures.isEmpty {
                            DisclosureGroup(isExpanded: $showPictures) {
                                VStack(spacing: 8) {
                                    ForEach(pictures) { s in
                                        TrackToggle(title: s.languageName + (s.forced ? " (Forced)" : ""),
                                                    subtitle: s.codec == "hdmv_pgs_subtitle"
                                                        ? "Read into text with OCR"
                                                        : "\(s.formatName) · can't be read",
                                                    isOn: ocrBinding(for: s.id), enabled: s.codec == "hdmv_pgs_subtitle")
                                    }
                                }
                                .padding(.top, 6)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Picture subtitles (\(pictures.count))\(app.ocrSubtitles.isEmpty ? "" : " · \(app.ocrSubtitles.count) to read")")
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text("Blu-ray subtitles are pictures QuickTime can't show. Spatialize can read them into text, about 5 minutes per track.")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 26)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .disabled(app.conversion.isRunning)
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(get: { app.subtitles.contains(id) },
                set: { on in if on { app.subtitles.insert(id) } else { app.subtitles.remove(id) } })
    }

    private func ocrBinding(for id: Int) -> Binding<Bool> {
        Binding(get: { app.ocrSubtitles.contains(id) },
                set: { on in if on { app.ocrSubtitles.insert(id) } else { app.ocrSubtitles.remove(id) } })
    }
}

// MARK: - Output

struct OutputSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings

    var body: some View {
        GlassCard(title: "Output", symbol: "square.and.arrow.down") {
            SettingRow(title: "Name") {
                HStack(spacing: 4) {
                    TextField("Name", text: $app.outputName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Text(".mov").foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            SettingRow(title: "Save to") {
                HStack(spacing: 8) {
                    Text(settings.outputFolder.isEmpty ? "Same folder as the movie" : app.outputFolder.lastPathComponent)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(app.outputFolder.path)
                    Button("Choose…") { chooseFolder() }.buttonStyle(.glass).controlSize(.small)
                    if !settings.outputFolder.isEmpty {
                        Button("Reset") { settings.outputFolder = "" }.buttonStyle(.glass).controlSize(.small)
                    }
                }
            }
            SwitchRow(title: "Open in QuickTime Player when finished", isOn: $settings.openWhenDone)
            if FileManager.default.fileExists(atPath: app.outputURL.path) && !app.conversion.isRunning {
                Label("A file with this name exists and will be replaced.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .disabled(app.conversion.isRunning)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = app.outputFolder
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url.path }
    }
}
