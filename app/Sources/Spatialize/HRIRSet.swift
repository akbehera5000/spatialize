import AVFoundation
import Accelerate
import Foundation
#if canImport(CMySofa)
import CMySofa
#endif

/// Head-related impulse responses (one left/right pair per direction) for a fixed list of
/// directions: Apple's built-in head model, or a measured head from a SOFA file.
/// Shared by the app (head-model test, height calibration) and the engine's binaural renderer.
struct HRIRSet {
    static let length = 512

    struct Direction: Hashable {
        var az: Float   // degrees, positive = left
        var el: Float   // degrees, positive = up
    }

    var name: String
    var directions: [Direction]
    var left: [[Float]]
    var right: [[Float]]

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String { if case .unreadable(let m) = self { return m }; return "" }
    }

    /// Unit vector, x forward, y left, z up.
    static func vector(_ d: Direction) -> SIMD3<Float> {
        let a = d.az * .pi / 180, e = d.el * .pi / 180
        return SIMD3(cos(e) * cos(a), cos(e) * sin(a), sin(e))
    }

    // MARK: sources

    /// Apple's head model, the one AVAudioEnvironmentNode (and so the live player) uses, captured
    /// by rendering an impulse from each direction offline.
    static func apple(_ dirs: [Direction]) throws -> HRIRSet {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = 4096
        var L: [[Float]] = [], R: [[Float]] = []
        for d in dirs {
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
            let env = AVAudioEnvironmentNode()
            env.outputType = .headphones
            env.reverbParameters.enable = false
            env.distanceAttenuationParameters.distanceAttenuationModel = .inverse
            env.distanceAttenuationParameters.referenceDistance = 10
            let player = AVAudioPlayerNode()
            engine.attach(env)
            engine.attach(player)
            engine.connect(env, to: engine.mainMixerNode, format: stereo)
            engine.connect(player, to: env, format: mono)
            player.renderingAlgorithm = .HRTFHQ
            player.sourceMode = .pointSource
            player.reverbBlend = 0
            let v = vector(d)
            // AVAudioEnvironmentNode: x right, y up, -z forward
            player.position = AVAudio3DPoint(x: -v.y * 2, y: v.z * 2, z: -v.x * 2)
            let impulse = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 1024)!
            impulse.frameLength = 1024
            memset(impulse.floatChannelData![0], 0, 1024 * 4)
            impulse.floatChannelData![0][0] = 1
            try engine.start()
            player.scheduleBuffer(impulse, at: nil)
            player.play()
            let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
            var l: [Float] = [], r: [Float] = []
            while l.count < capture {
                guard try engine.renderOffline(1024, to: chunk) == .success else { break }
                let n = Int(chunk.frameLength)
                l += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: n)
                r += UnsafeBufferPointer(start: chunk.floatChannelData![1], count: n)
            }
            engine.stop()
            L.append(l); R.append(r)
        }
        var set = HRIRSet(name: "Apple", directions: dirs, left: L, right: R)
        set.tidy()
        return set
    }

    /// A measured head from a SOFA file: for each direction the nearest measurement.
    static func sofa(_ url: URL, _ dirs: [Direction]) throws -> HRIRSet {
        let len = 2048
        var m: Int32 = 0
        var ir: UnsafeMutablePointer<Float>?
        var dir: UnsafeMutablePointer<Float>?
        let status = sofa_load(url.path, 48000, Int32(len), &m, &ir, &dir)
        guard status == 0, let ir, let dir, m > 0 else {
            throw Failure.unreadable("\(url.lastPathComponent) is not a readable SOFA HRTF (error \(status))")
        }
        defer { sofa_free(ir); sofa_free(dir) }
        var L: [[Float]] = [], R: [[Float]] = []
        for d in dirs {
            let want = vector(d)
            var best = 0
            var bestDot: Float = -2
            for i in 0..<Int(m) {
                let dot = want.x * dir[3 * i] + want.y * dir[3 * i + 1] + want.z * dir[3 * i + 2]
                if dot > bestDot { bestDot = dot; best = i }
            }
            L.append(Array(UnsafeBufferPointer(start: ir + (2 * best) * len, count: len)))
            R.append(Array(UnsafeBufferPointer(start: ir + (2 * best + 1) * len, count: len)))
        }
        var set = HRIRSet(name: url.deletingPathExtension().lastPathComponent, directions: dirs, left: L, right: R)
        set.tidy()
        return set
    }

    /// "apple" or a path to a SOFA file.
    static func load(_ spec: String, _ dirs: [Direction]) throws -> HRIRSet {
        spec == "apple" ? try apple(dirs) : try sofa(URL(fileURLWithPath: spec), dirs)
    }

    // MARK: tidy up

    /// Removes the shared onset delay (so nothing lags the picture), cuts to `length` with a short
    /// fade, and scales the set to unit average energy per ear so different heads play equally loud.
    private mutating func tidy() {
        let all = left + right
        let peak = all.map { $0.map(abs).max() ?? 0 }.max() ?? 0
        guard peak > 0 else { return }
        let onset = all.compactMap { $0.firstIndex { abs($0) > peak * 0.1 } }.min() ?? 0
        let cut = max(0, onset - 8)
        let n = HRIRSet.length, fade = 48
        func shape(_ x: [Float]) -> [Float] {
            var y = Array(x.dropFirst(cut).prefix(n))
            if y.count < n { y += [Float](repeating: 0, count: n - y.count) }
            for k in 0..<fade { y[n - fade + k] *= Float(fade - k) / Float(fade) }
            return y
        }
        left = left.map(shape)
        right = right.map(shape)
        var energy: Float = 0
        for x in left + right { energy += x.reduce(0) { $0 + $1 * $1 } }
        energy /= Float(2 * left.count)
        let g = energy > 0 ? 1 / sqrt(energy) : 1
        left = left.map { $0.map { $0 * g } }
        right = right.map { $0.map { $0 * g } }
    }

    // MARK: rendering

    /// A mono signal placed at direction `i` (direct convolution, for short test sounds).
    func render(_ mono: [Float], at i: Int) -> (left: [Float], right: [Float]) {
        (Self.convolve(mono, left[i]), Self.convolve(mono, right[i]))
    }

    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        let n = x.count + h.count - 1
        var padded = [Float](repeating: 0, count: n + h.count - 1)
        padded.replaceSubrange((h.count - 1)..<(h.count - 1 + x.count), with: x)
        var out = [Float](repeating: 0, count: n)
        h.withUnsafeBufferPointer { hp in
            // vDSP_conv correlates; a reversed filter (negative stride from its end) convolves
            vDSP_conv(padded, 1, hp.baseAddress! + h.count - 1, -1, &out, 1, vDSP_Length(n), vDSP_Length(h.count))
        }
        return out
    }
}
