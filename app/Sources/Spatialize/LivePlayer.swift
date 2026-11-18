import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The live player: the previewed scene, rendered in real time around your head with head
/// tracking, and a map of where every sound is.
struct LivePlayerView: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var engine: LiveEngine?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let engine {
                LivePlayerContent(engine: engine, close: close)
            } else {
                VStack(spacing: 14) {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Close") { dismiss() }
                    } else {
                        ProgressView()
                        Text("Loading the scene…").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 520, height: 300)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let s = app.settings
            let top = Float(s.customLayout ? 45 : s.heightAngle)
            engine = try LiveEngine(masterDir: app.liveMasterDir, video: app.previewURL, topElevation: top)
            engine?.room = s.roomPreset != .off
            engine?.eqGains = s.eqGains
            // start with the head model chosen for the binaural track (or found by the head test)
            let head = HeadModels.engineSpec(s.headModel)
            if head != "apple" {
                engine?.loadHRTF(URL(fileURLWithPath: head))
                engine?.hrtfName = HeadModels.name(of: head)
            }
        } catch {
            loadError = "Couldn't open the scene: \(error.localizedDescription)"
        }
    }

    private func close() {
        engine?.stop()
        dismiss()
    }
}

private struct LivePlayerContent: View {
    @ObservedObject var engine: LiveEngine
    @ObservedObject var head: HeadTracker
    var close: () -> Void

    init(engine: LiveEngine, close: @escaping () -> Void) {
        self.engine = engine
        self.head = engine.head
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Listen Live").font(.system(size: 20, weight: .bold))
                Text("· rendered around your head as it plays").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    if let player = engine.player {
                        PlayerLayerView(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    transport
                }
                .frame(width: 520)

                VStack(spacing: 8) {
                    LiveDome(dots: engine.dots, headYaw: head.active ? head.yaw : 0)
                        .frame(width: 300, height: 300)
                    Text(engine.scene.isObjectBased
                         ? "\(engine.dots.filter { !$0.isBed }.count) objects active · blue at ear level, violet above"
                         : "7.1.4 speakers (this film has no Atmos objects)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.5)

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Head tracking").font(.system(size: 13, weight: .semibold))
                    if head.available {
                        HStack {
                            Toggle("", isOn: Binding(get: { head.active }, set: { $0 ? head.start() : head.stop() }))
                                .labelsHidden().toggleStyle(.switch)
                            Button("Recenter") { head.recenter() }.buttonStyle(.glass).disabled(!head.active)
                        }
                        if head.active {
                            Text(String(format: "Turn %+.0f°   Tilt %+.0f°", head.yaw, head.pitch))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            Toggle("Sounds turn the wrong way", isOn: $head.flip)
                                .font(.system(size: 11)).controlSize(.small)
                                .help("Turn your head left: the sound in front should move to your right ear. If it moves left, switch this on.")
                        }
                    } else {
                        Text("Connect AirPods Pro, AirPods Max or AirPods (3rd generation or later).")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 230, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Head model (HRTF)").font(.system(size: 13, weight: .semibold))
                    Picker("", selection: Binding(get: { engine.renderer }, set: { engine.setRenderer($0) })) {
                        ForEach(LiveRenderer.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 290)
                    HStack {
                        Text(engine.renderer == .sofa ? (engine.hrtfName ?? "") : "Apple's built-in head model")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Choose SOFA File…") { chooseSofa() }.buttonStyle(.glass).controlSize(.small)
                    }
                    .frame(width: 290)
                    Text("A SOFA file holds a measured head (yours, if you've been measured, or one from a public database such as SADIE II or ARI). Choose the one that sounds most natural.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(width: 290, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Room").font(.system(size: 13, weight: .semibold))
                    Toggle("Room reflections", isOn: Binding(get: { engine.room }, set: { engine.setRoom($0) }))
                    Text("For the most accurate result, turn Spatial Audio off for Spatialize in Control Center → Sound, so macOS doesn't spatialize it a second time.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(width: 220, alignment: .leading)
                }
            }

            if let e = engine.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .padding(22)
        .frame(width: 900)
        .onAppear {
            guard !SelfTest.active else { return } // headless check: no sound, no sensors
            if head.available { head.start() }
            engine.play()
        }
        .onDisappear { engine.stop() }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { engine.togglePlay() } label: {
                Image(systemName: engine.playing ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.space, modifiers: [])
            Text(engine.position.clock).font(.system(size: 12).monospacedDigit())
            Slider(value: Binding(get: { engine.position }, set: { engine.seek(to: $0) }), in: 0...max(0.1, engine.duration))
            Text(engine.duration.clock).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func chooseSofa() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sofa") ?? .data]
        panel.message = "Choose a SOFA HRTF file"
        if panel.runModal() == .OK, let url = panel.url { engine.loadHRTF(url) }
    }
}

/// Top-down map of the sound field: the centre is straight overhead, the ring is ear level.
/// Dots are sources, sized by how loud they are right now; the head marker shows where you face.
struct LiveDome: View {
    var dots: [LiveDot]
    var headYaw: Float

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) / 2 - 18
            for (frac, alpha) in [(1.0, 0.35), (2.0 / 3, 0.15), (1.0 / 3, 0.15)] {
                let r = R * frac
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(alpha)), lineWidth: frac == 1 ? 1.2 : 0.8)
            }
            ctx.draw(Text("Front").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y - R - 9))
            // listener's facing direction
            let a = CGFloat(headYaw) * .pi / 180
            var nose = Path()
            nose.move(to: c)
            nose.addLine(to: CGPoint(x: c.x - sin(a) * 26, y: c.y - cos(a) * 26))
            ctx.stroke(nose, with: .color(.white.opacity(0.8)), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.25)))

            for d in dots {
                let r = R * CGFloat(max(-30, min(90, 90 - d.el))) / 90
                let az = CGFloat(d.az) * .pi / 180
                let p = CGPoint(x: c.x - sin(az) * r, y: c.y - cos(az) * r)
                let loud = CGFloat(min(1, sqrt(max(0, d.level)) * 3))
                let size: CGFloat = (d.isBed ? 7 : 10) + 16 * loud
                let color = d.el > 20 ? Color(red: 0.62, green: 0.45, blue: 1.0) : Color(red: 0.32, green: 0.62, blue: 1.0)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                         with: .color(color.opacity(d.isBed ? 0.25 + 0.5 * Double(loud) : 0.45 + 0.55 * Double(loud))))
                if !d.isBed && loud > 0.15 {
                    ctx.draw(Text(d.name.replacingOccurrences(of: "Object ", with: "")).font(.system(size: 8.5, weight: .semibold)),
                             at: CGPoint(x: p.x, y: p.y - size / 2 - 6))
                }
            }
        }
        .background(.black.opacity(0.2), in: Circle())
    }
}

/// Shows an AVPlayer's picture with a plain AVPlayerLayer. (SwiftUI's VideoPlayer from AVKit
/// crashes while loading on this macOS version, and the live player needs no playback controls.)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
