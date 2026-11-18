import SwiftUI

/// Full-width card for placing the 11 speakers anywhere around (and above, and below) you.
struct SpeakerLayoutSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings: Settings
    @State private var layout = SpeakerLayout.standard()
    @State private var selected = 8
    @State private var loaded = false

    var body: some View {
        GlassCard(title: "Speaker Placement", symbol: "hifispeaker.2", trailing: AnyView(header)) {
            Text(settings.customLayout
                 ? "Drag speakers on the dome. The centre is straight overhead, the solid ring is ear level, and the dashed ring is below ear level. Custom placement uses the ambisonic sound field."
                 : "Apple places the 7.1.4 speakers for you. Turn on Custom to move any speaker anywhere around you, including higher or lower.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 22) {
                DomeMap(layout: $layout, selected: $selected, editable: settings.customLayout,
                        snap: settings.snapAngles, mirror: settings.mirrorPairs)
                    .frame(width: 360, height: 360)
                    .opacity(settings.customLayout ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 14) {
                    Orbit3D(layout: layout, selected: selected)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Inspector(layout: $layout, selected: $selected, settings: settings)
                        .disabled(!settings.customLayout)
                        .opacity(settings.customLayout ? 1 : 0.5)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            layout = settings.speakerLayout
            loaded = true
        }
        .onChange(of: layout) { _, new in settings.speakerLayout = new }
        .disabled(app.conversion.isRunning)
        .animation(.snappy, value: settings.customLayout)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                app.playSpeakerTest()
            } label: {
                if app.makingTest {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…") }
                } else {
                    Label("Test in QuickTime", systemImage: "play.circle")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(app.makingTest)
            .help("Plays pink noise from each speaker in turn with your current settings")
            Toggle("Custom", isOn: $settings.customLayout)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
        }
    }
}

// MARK: - Dome map (top view: angle = direction, distance from centre = height)

struct DomeMap: View {
    @Binding var layout: SpeakerLayout
    @Binding var selected: Int
    var editable: Bool
    var snap: Bool
    var mirror: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let ear = size / 2 * 0.75            // radius of the ear-level ring
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                grid(center: c, ear: ear)
                ForEach(layout.speakers) { s in
                    let p = point(s, c, ear)
                    Path { $0.move(to: c); $0.addLine(to: p) }
                        .stroke(.white.opacity(s.id == selected ? 0.35 : 0.08), lineWidth: 1)
                }
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(c)
                ForEach(layout.speakers.sorted { a, _ in a.id != selected }) { s in
                    SpeakerDot(speaker: s, selected: s.id == selected)
                        .position(point(s, c, ear))
                        .gesture(drag(s, c, ear), including: editable ? .all : .subviews)
                        .onTapGesture { selected = s.id }
                }
            }
        }
        .coordinateSpace(name: "dome")
    }

    private func point(_ s: Speaker, _ c: CGPoint, _ ear: CGFloat) -> CGPoint {
        let r = ear * (90 - s.el) / 90
        let a = s.az * .pi / 180
        return CGPoint(x: c.x - sin(a) * r, y: c.y - cos(a) * r)
    }

    private func drag(_ s: Speaker, _ c: CGPoint, _ ear: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("dome"))
            .onChanged { g in
                selected = s.id
                let dx = g.location.x - c.x, dy = g.location.y - c.y
                let r = hypot(dx, dy)
                var el = 90 - Double(r / ear) * 90
                var az = r < 4 ? s.az : atan2(-Double(dx), -Double(dy)) * 180 / .pi
                if snap { el = (el / 5).rounded() * 5; az = (az / 5).rounded() * 5 }
                el = min(max(el, SpeakerLayout.elevationRange.lowerBound), SpeakerLayout.elevationRange.upperBound)
                move(s.id, az: wrapDegrees(az), el: el)
            }
    }

    private func move(_ id: Int, az: Double, el: Double) {
        guard let i = layout.speakers.firstIndex(where: { $0.id == id }) else { return }
        layout.speakers[i].az = az
        layout.speakers[i].el = el
        if mirror, let pid = layout.partner(of: layout.speakers[i]),
           let j = layout.speakers.firstIndex(where: { $0.id == pid }) {
            layout.speakers[j].az = wrapDegrees(-az)
            layout.speakers[j].el = el
        }
    }

    @ViewBuilder private func grid(center c: CGPoint, ear: CGFloat) -> some View {
        let below = ear * 120 / 90
        ZStack {
            Circle().fill(.white.opacity(0.03)).frame(width: below * 2, height: below * 2)
            Circle().strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .frame(width: below * 2, height: below * 2)
            Circle().fill(.white.opacity(0.05)).frame(width: ear * 2, height: ear * 2)
            Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.2).frame(width: ear * 2, height: ear * 2)
            ForEach([30.0, 60.0], id: \.self) { e in
                let r = ear * (90 - e) / 90
                Circle().strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .frame(width: r * 2, height: r * 2)
            }
            ForEach(0..<12) { k in
                let a = Double(k) * 30 * .pi / 180
                Path { p in
                    p.move(to: CGPoint(x: c.x - sin(a) * ear * 0.1, y: c.y - cos(a) * ear * 0.1))
                    p.addLine(to: CGPoint(x: c.x - sin(a) * below, y: c.y - cos(a) * below))
                }
                .stroke(.white.opacity(0.06), lineWidth: 1)
            }
        }
        .position(c)
        Group {
            Text("FRONT").position(x: c.x, y: c.y - below - 9)
            Text("BEHIND").position(x: c.x, y: c.y + below + 9)
            Text("LEFT").rotationEffect(.degrees(-90)).position(x: c.x - below - 10, y: c.y)
            Text("RIGHT").rotationEffect(.degrees(90)).position(x: c.x + below + 10, y: c.y)
            Text("60°").position(x: c.x + 6, y: c.y - ear * 30 / 90 + 8)
            Text("30°").position(x: c.x + 6, y: c.y - ear * 60 / 90 + 8)
            Text("ear level").position(x: c.x + 2, y: c.y + ear - 8)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))
    }
}

struct SpeakerDot: View {
    var speaker: Speaker
    var selected: Bool

    var body: some View {
        Text(speaker.short)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                Circle().fill(speaker.isHeight
                              ? Color(red: 0.55, green: 0.36, blue: 0.95)
                              : Color(red: 0.20, green: 0.48, blue: 0.98))
            )
            .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
            .shadow(color: .black.opacity(0.4), radius: selected ? 8 : 3, y: 2)
            .scaleEffect(selected ? 1.12 : 1)
            .animation(.snappy(duration: 0.2), value: selected)
            .contentShape(Circle())
            .help("\(speaker.name): \(speaker.azText), \(speaker.elText)")
    }
}

// MARK: - 3D preview

struct Orbit3D: View {
    var layout: SpeakerLayout
    var selected: Int
    @State private var yaw: Double = 25
    @State private var dragStart: Double?
    private let pitch = 22.0 * .pi / 180

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height * 0.62)
            let k = min(size.width, size.height * 1.6) * 0.29
            func project(_ az: Double, _ el: Double, _ r: Double = 1) -> (CGPoint, Double) {
                let a = az * .pi / 180, e = el * .pi / 180, y0 = yaw * .pi / 180
                let x = -sin(a) * cos(e) * r, y = sin(e) * r, z = cos(a) * cos(e) * r
                let xr = x * cos(y0) - z * sin(y0)
                let zr = x * sin(y0) + z * cos(y0)
                let sy = y * cos(pitch) + zr * sin(pitch)
                let depth = y * sin(pitch) - zr * cos(pitch)   // larger = closer to the viewer
                return (CGPoint(x: c.x + xr * k, y: c.y - sy * k), depth)
            }
            // ear-level ring and two meridians of the dome
            for (el, alpha) in [(0.0, 0.5), (45.0, 0.15)] {
                var ring = Path()
                for i in 0...72 {
                    let p = project(Double(i) * 5, el).0
                    i == 0 ? ring.move(to: p) : ring.addLine(to: p)
                }
                ctx.stroke(ring, with: .color(.white.opacity(alpha)), lineWidth: 1)
            }
            for az in [0.0, 90.0] {
                var arc = Path()
                for i in 0...36 {
                    let p = project(az, Double(i) * 5).0
                    i == 0 ? arc.move(to: p) : arc.addLine(to: p)
                }
                ctx.stroke(arc, with: .color(.white.opacity(0.12)), lineWidth: 1)
                var back = Path()
                for i in 0...36 {
                    let p = project(az + 180, Double(i) * 5).0
                    i == 0 ? back.move(to: p) : back.addLine(to: p)
                }
                ctx.stroke(back, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            // front arrow
            let f0 = project(0, 0, 0.25).0, f1 = project(0, 0, 1.18).0
            var arrow = Path(); arrow.move(to: f0); arrow.addLine(to: f1)
            ctx.stroke(arrow, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            ctx.draw(Text("front").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5)),
                     at: project(0, 0, 1.32).0)
            // listener
            ctx.draw(Image(systemName: "person.crop.circle.fill"), at: c)
            // speakers, far ones first
            let items = layout.speakers.map { s -> (Speaker, CGPoint, Double) in
                let (p, d) = project(s.az, s.el); return (s, p, d)
            }.sorted { $0.2 < $1.2 }
            for (s, p, d) in items {
                let r = 9 + 3 * d
                let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                let fill = s.isHeight ? Color(red: 0.55, green: 0.36, blue: 0.95) : Color(red: 0.20, green: 0.48, blue: 0.98)
                // drop line to the floor plane shows height
                let base = project(s.az, 0, cos(s.el * .pi / 180)).0
                var stem = Path(); stem.move(to: p); stem.addLine(to: base)
                ctx.stroke(stem, with: .color(.white.opacity(0.15)), lineWidth: 1)
                ctx.fill(Circle().path(in: rect), with: .color(fill.opacity(0.75 + 0.25 * d)))
                if s.id == selected {
                    ctx.stroke(Circle().path(in: rect.insetBy(dx: -2, dy: -2)), with: .color(.white), lineWidth: 2)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("3D view · drag to rotate").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(10)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { g in
            if dragStart == nil { dragStart = yaw }
            yaw = (dragStart ?? 0) - Double(g.translation.width) * 0.6
        }.onEnded { _ in dragStart = nil })
    }
}

// MARK: - Inspector (fine adjustments)

struct Inspector: View {
    @Binding var layout: SpeakerLayout
    @Binding var selected: Int
    @ObservedObject var settings: Settings

    var body: some View {
        let idx = layout.speakers.firstIndex { $0.id == selected } ?? 0
        let s = layout.speakers[idx]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $selected) {
                    ForEach(layout.speakers) { Text("\($0.name) (\($0.short))").tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
                Spacer()
                Menu {
                    ForEach(SpeakerLayout.presets) { p in
                        Button {
                            withAnimation(.snappy) { layout = p.layout }
                        } label: { Text("\(p.name) — \(p.detail)") }
                    }
                } label: {
                    Label("Presets", systemImage: "square.grid.3x3")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.small)
                .fixedSize()
            }

            angleRow(title: "Direction", value: Binding(
                get: { s.az }, set: { set(idx, az: wrapDegrees($0), el: nil) }),
                     range: -180...180, text: s.azText, flip: true)
            angleRow(title: "Height", value: Binding(
                get: { s.el }, set: { set(idx, az: nil, el: $0) }),
                     range: SpeakerLayout.elevationRange, text: s.elText, flip: false)

            HStack(spacing: 18) {
                Toggle("Mirror left/right pairs", isOn: $settings.mirrorPairs)
                Toggle("Snap to 5°", isOn: $settings.snapAngles)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
        }
    }

    /// Slider + fine ±1° steps. `flip` shows the direction slider with left on the left.
    private func angleRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String, flip: Bool) -> some View {
        let shown = flip
            ? Binding(get: { -value.wrappedValue }, set: { value.wrappedValue = -$0 })
            : value
        let shownRange = flip ? -range.upperBound ... -range.lowerBound : range
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(text).font(.system(size: 12, weight: .semibold).monospacedDigit())
                Stepper("", value: shown, in: shownRange, step: 1).labelsHidden().controlSize(.small)
            }
            Slider(value: shown, in: shownRange, step: settings.snapAngles ? 5 : 1)
                .controlSize(.small)
        }
    }

    private func set(_ i: Int, az: Double?, el: Double?) {
        if let az { layout.speakers[i].az = az }
        if let el { layout.speakers[i].el = el }
        if settings.mirrorPairs, let pid = layout.partner(of: layout.speakers[i]),
           let j = layout.speakers.firstIndex(where: { $0.id == pid }) {
            layout.speakers[j].az = wrapDegrees(-layout.speakers[i].az)
            layout.speakers[j].el = layout.speakers[i].el
        }
    }
}
