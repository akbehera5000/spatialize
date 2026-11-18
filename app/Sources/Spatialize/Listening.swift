import AVFoundation
import SwiftUI

/// Pieces shared by the listening tests: the test sound, a stereo player and the answer pickers.
enum TestSound {
    /// Three short bursts of pink noise (broadband, so every direction cue is in it), with soft edges.
    static func bursts(seed: UInt64 = .random(in: 1...UInt64.max), count: Int = 3, length: Double = 0.2, gap: Double = 0.09) -> [Float] {
        var rng = seed
        func white() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 11) % 2_000_001) / 1_000_000 - 1
        }
        let n = Int(length * 48000), g = Int(gap * 48000), ramp = 480
        var out: [Float] = []
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        for k in 0..<count {
            for i in 0..<n {
                // Paul Kellet's pink filter
                let w = white()
                b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
                b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
                b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
                let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.05
                b6 = w * 0.115926
                let env = Float(min(1, Double(min(i, n - 1 - i)) / Double(ramp)))
                out.append(pink * env)
            }
            if k < count - 1 { out += [Float](repeating: 0, count: g) }
        }
        return out
    }

    /// The engine's overhead cue (peaking 7.5 kHz, Q 1), so a calibration hears what a conversion gets.
    static func heightCue(_ x: [Float], db: Double) -> [Float] {
        guard db != 0 else { return x }
        let a = pow(10, db / 40), w = 2 * Double.pi * 7500 / 48000, alpha = sin(w) / 2
        let a0 = 1 + alpha / a
        let b = [(1 + alpha * a) / a0, -2 * cos(w) / a0, (1 - alpha * a) / a0]
        let fa = [-2 * cos(w) / a0, (1 - alpha / a) / a0]
        var z0 = 0.0, z1 = 0.0
        return x.map { v in
            let xi = Double(v)
            let y = b[0] * xi + z0
            z0 = b[1] * xi - fa[0] * y + z1
            z1 = b[2] * xi - fa[1] * y
            return Float(y)
        }
    }
}

/// Plays short stereo buffers.
@MainActor
final class TestPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(left: [Float], right: [Float], gain: Float = 0.5) {
        let n = min(left.count, right.count)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        // keep peaks safe whatever the head model does to the level
        let peak = max(left.prefix(n).map(abs).max() ?? 0, right.prefix(n).map(abs).max() ?? 0)
        let g = min(gain, peak > 0 ? 0.9 / peak : gain)
        for i in 0..<n {
            buf.floatChannelData![0][i] = left[i] * g
            buf.floatChannelData![1][i] = right[i] * g
        }
        if !engine.isRunning { try? engine.start() }
        node.stop()
        node.scheduleBuffer(buf, at: nil)
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

/// Angle between two directions, in degrees.
func angleBetween(_ a: HRIRSet.Direction, _ b: HRIRSet.Direction) -> Double {
    let d = simd_dot(HRIRSet.vector(a), HRIRSet.vector(b))
    return Double(acos(max(-1, min(1, d)))) * 180 / .pi
}

/// Top-down map to answer "where did it come from": the centre is straight above, the solid ring
/// is ear level, the area outside it is below ear level. Front is up.
struct DomePicker: View {
    @Binding var answer: HRIRSet.Direction?
    var reveal: HRIRSet.Direction? = nil

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let R = size / 2 / 1.33 - 6
            Canvas { ctx, _ in
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - R * 1.33, y: c.y - R * 1.33, width: 2.66 * R, height: 2.66 * R)),
                         with: .color(.black.opacity(0.18)))
                for (frac, alpha, w) in [(1.0, 0.45, 1.4), (2.0 / 3, 0.15, 0.8), (1.0 / 3, 0.15, 0.8), (1.33, 0.12, 0.8)] {
                    let r = R * frac
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(alpha)), lineWidth: w)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: c.x, y: c.y - R * 1.33)); cross.addLine(to: CGPoint(x: c.x, y: c.y + R * 1.33))
                cross.move(to: CGPoint(x: c.x - R * 1.33, y: c.y)); cross.addLine(to: CGPoint(x: c.x + R * 1.33, y: c.y))
                ctx.stroke(cross, with: .color(.white.opacity(0.08)), lineWidth: 0.8)
                for (t, p) in [("Front", CGPoint(x: c.x, y: c.y - R - 8)), ("Behind", CGPoint(x: c.x, y: c.y + R + 8)),
                               ("Left", CGPoint(x: c.x - R - 18, y: c.y - 8)), ("Right", CGPoint(x: c.x + R + 18, y: c.y - 8)),
                               ("Above", CGPoint(x: c.x + 18, y: c.y - 9)), ("Below", CGPoint(x: c.x + R * 1.17, y: c.y + R * 1.0))] {
                    ctx.draw(Text(t).font(.system(size: 10)).foregroundStyle(.secondary), at: p)
                }
                // you
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white.opacity(0.3)))
                if let reveal {
                    let p = point(reveal, c, R)
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
                if let answer {
                    let p = point(answer, c, R)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                             with: .color(Color(red: 0.45, green: 0.62, blue: 1.0)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - c.x, dy = g.location.y - c.y
                let r = min(sqrt(dx * dx + dy * dy), R * 1.33)
                let el = 90 - 90 * r / R
                let az = atan2(-dx, -dy) * 180 / .pi
                answer = HRIRSet.Direction(az: Float(az), el: Float(max(-30, el)))
            })
        }
    }

    private func point(_ d: HRIRSet.Direction, _ c: CGPoint, _ R: CGFloat) -> CGPoint {
        let r = R * CGFloat(90 - max(-30, min(90, d.el))) / 90
        let a = CGFloat(d.az) * .pi / 180
        return CGPoint(x: c.x - sin(a) * r, y: c.y - cos(a) * r)
    }
}

/// Side view to answer "how high was it": a quarter circle from ear level (front) to overhead.
struct ElevationPicker: View {
    @Binding var elevation: Double?

    var body: some View {
        GeometryReader { geo in
            let R = min(geo.size.width - 40, geo.size.height - 40)
            let c = CGPoint(x: 26, y: geo.size.height - 22)
            Canvas { ctx, _ in
                var arc = Path()
                arc.addArc(center: c, radius: R, startAngle: .degrees(15), endAngle: .degrees(-90), clockwise: true)
                ctx.stroke(arc, with: .color(.white.opacity(0.35)), lineWidth: 1.4)
                for deg in stride(from: 0.0, through: 90, by: 15) {
                    let a = deg * .pi / 180
                    var t = Path()
                    t.move(to: CGPoint(x: c.x + cos(a) * (R - 6), y: c.y - sin(a) * (R - 6)))
                    t.addLine(to: CGPoint(x: c.x + cos(a) * (R + 6), y: c.y - sin(a) * (R + 6)))
                    ctx.stroke(t, with: .color(.white.opacity(0.4)), lineWidth: 1)
                    if deg.truncatingRemainder(dividingBy: 45) == 0 {
                        ctx.draw(Text("\(Int(deg))°").font(.system(size: 10)).foregroundStyle(.secondary),
                                 at: CGPoint(x: c.x + cos(a) * (R + 22), y: c.y - sin(a) * (R + 16)))
                    }
                }
                ctx.draw(Text("Ear level, in front").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: c.x + R * 0.55, y: c.y + 12))
                ctx.draw(Text("Overhead").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: c.x + 34, y: c.y - R - 10))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.white.opacity(0.3)))
                if let e = elevation {
                    let a = e * .pi / 180
                    var ray = Path()
                    ray.move(to: c)
                    ray.addLine(to: CGPoint(x: c.x + cos(a) * R, y: c.y - sin(a) * R))
                    ctx.stroke(ray, with: .color(.white.opacity(0.25)), lineWidth: 1)
                    let p = CGPoint(x: c.x + cos(a) * R, y: c.y - sin(a) * R)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                             with: .color(Color(red: 0.45, green: 0.62, blue: 1.0)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let a = atan2(c.y - g.location.y, g.location.x - c.x) * 180 / .pi
                elevation = max(-15, min(90, a)).rounded()
            })
        }
    }
}
