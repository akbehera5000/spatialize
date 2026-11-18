import AVFoundation
import Foundation

/// Offline check of the live renderers (SPATIALIZE_LIVE_TEST=dir): renders the scene in `dir`
/// with each renderer and head turn, writes WAVs next to it and prints the left/right balance of
/// every second, so direction and head-tracking signs can be verified without listening.
@MainActor
enum LiveSelfTest {
    static func run(_ dir: URL) {
        let sofa = ProcessInfo.processInfo.environment["SPATIALIZE_SOFA"]
        for renderer in [LiveRenderer.apple, .sofa] {
            for yaw: Float in [0, 90] {
                do {
                    let e = try LiveEngine(masterDir: dir, video: nil, topElevation: 60)
                    if renderer == .sofa {
                        guard let sofa else { continue }
                        e.loadHRTF(URL(fileURLWithPath: sofa))
                        e.setRenderer(.sofa)
                    }
                    e.testYaw = yaw
                    let buf = try e.renderOffline(seconds: e.duration)
                    let name = "\(renderer.rawValue)-yaw\(Int(yaw))"
                    let file = try AVAudioFile(forWriting: dir.appendingPathComponent("\(name).wav"), settings: buf.format.settings)
                    try file.write(from: buf)
                    var line = "\(name):"
                    let sec = 48000
                    for k in 0..<(Int(buf.frameLength) / sec) {
                        var l: Float = 0, r: Float = 0
                        for i in (k * sec + 4000)..<((k + 1) * sec - 4000) {
                            let a = buf.floatChannelData![0][i], b = buf.floatChannelData![1][i]
                            l += a * a; r += b * b
                        }
                        line += String(format: " %+5.1f", 10 * log10(max(l, 1e-12) / max(r, 1e-12)))
                    }
                    print(line + "   (dB left louder than right, per second)")
                } catch {
                    print("\(renderer.rawValue): \(error)")
                }
            }
        }
    }
}
