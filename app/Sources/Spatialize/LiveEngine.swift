import AVFoundation
import Accelerate
import CoreMotion
import SwiftUI

/// Head orientation from AirPods (Pro, Max, 3rd generation and later) through Core Motion.
@MainActor
final class HeadTracker: ObservableObject {
    @Published var available = false
    @Published var active = false
    @Published var yaw: Float = 0     // degrees, positive = turned left
    @Published var pitch: Float = 0   // degrees, positive = looking up
    @Published var roll: Float = 0
    /// Mirrors left/right turning, in case a headset reports it the other way round.
    @Published var flip = false
    private let manager = CMHeadphoneMotionManager()
    private var reference: CMAttitude?
    /// Rotation that takes world directions into head directions (inverse head rotation).
    nonisolated(unsafe) var worldToHead = simd_quatf(angle: 0, axis: [0, 0, 1])

    init() { available = manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            MainActor.assumeIsolated { self.update(motion.attitude) }
        }
        active = true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        active = false
        yaw = 0; pitch = 0; roll = 0
        worldToHead = simd_quatf(angle: 0, axis: [0, 0, 1])
    }

    /// Makes the current head direction "straight ahead".
    func recenter() { reference = nil }

    private func update(_ attitude: CMAttitude) {
        if reference == nil { reference = attitude.copy() as? CMAttitude }
        let a = attitude.copy() as! CMAttitude
        if let reference { a.multiply(byInverseOf: reference) }
        let m: Double = flip ? -1 : 1
        yaw = Float(m * a.yaw * 180 / .pi)
        pitch = Float(a.pitch * 180 / .pi)
        roll = Float(m * a.roll * 180 / .pi)
        // our frame: x forward, y left, z up; yaw about z, pitch about y (nose up), roll about x
        let q = simd_quatf(angle: Float(m * a.yaw), axis: [0, 0, 1])
            * simd_quatf(angle: -Float(a.pitch), axis: [0, 1, 0])
            * simd_quatf(angle: Float(m * a.roll), axis: [1, 0, 0])
        worldToHead = q.inverse
    }
}

/// What the dome view draws for one source.
struct LiveDot: Identifiable {
    let id: Int
    var name: String
    var az: Float
    var el: Float
    var level: Float
    var isBed: Bool
}

enum LiveRenderer: String, CaseIterable, Identifiable {
    case apple, sofa
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple HRTF" : "Custom HRTF (SOFA)" }
}

/// Plays a scene preview's master live: every bed and object is a separate source placed around
/// your head, turned by head tracking. Two renderers: Apple's built-in HRTF
/// (AVAudioEnvironmentNode) or our own convolution with any SOFA HRTF set.
@MainActor
final class LiveEngine: ObservableObject {
    @Published var playing = false
    @Published var position: Double = 0          // seconds
    @Published var dots: [LiveDot] = []
    @Published var renderer: LiveRenderer = .apple
    @Published var error: String?
    @Published var hrtfName: String?
    @Published var room: Bool = false
    /// Headphone EQ (10 bands, dB), the same curve a conversion gets.
    var eqGains: [Double] = []

    let duration: Double
    let scene: LiveScene
    let player: AVPlayer?
    let head = HeadTracker()

    private var engine = AVAudioEngine()
    private let shared: Shared
    private var timer: Timer?
    private var hints: [Int]
    private var hrtf: SofaHRTF?

    /// State the audio thread reads; written from the main thread (single floats/ints).
    final class Shared {
        /// Read position of each source (they all advance in lockstep, one render cycle at a time);
        /// the binaural renderer uses only the first.
        var heads: UnsafeMutablePointer<Int>
        var playhead: Int {
            get { heads[0] }
            set { for i in 0..<max(1, count) { heads[i] = newValue } }
        }
        var gains: UnsafeMutablePointer<Float>
        var dirs: UnsafeMutablePointer<SIMD3<Float>>   // head-relative unit vectors (x fwd, y left, z up)
        var levels: UnsafeMutablePointer<Float>
        let count: Int
        init(count: Int) {
            self.count = count
            heads = .allocate(capacity: max(1, count)); heads.initialize(repeating: 0, count: max(1, count))
            gains = .allocate(capacity: count); gains.initialize(repeating: 0, count: count)
            dirs = .allocate(capacity: count); dirs.initialize(repeating: [1, 0, 0], count: count)
            levels = .allocate(capacity: count); levels.initialize(repeating: 0, count: count)
        }
        deinit { heads.deallocate(); gains.deallocate(); dirs.deallocate(); levels.deallocate() }
    }

    init(masterDir: URL, video: URL?, topElevation: Float) throws {
        scene = try LiveScene(directory: masterDir, topElevation: topElevation)
        duration = Double(scene.audio.frames) / 48000
        shared = Shared(count: scene.sources.count)
        hints = Array(repeating: 0, count: scene.sources.count)
        if let video, FileManager.default.fileExists(atPath: video.path) {
            let p = AVPlayer(url: video)
            p.isMuted = true
            player = p
        } else {
            player = nil
        }
        updatePositions()
    }

    // MARK: transport

    func togglePlay() { playing ? pause() : play() }

    func play() {
        guard !playing else { return }
        if shared.playhead >= scene.audio.frames { seek(to: 0) }
        do {
            try build()
            try engine.start()
        } catch {
            self.error = "Couldn't start audio: \(error.localizedDescription)"
            return
        }
        player?.seek(to: CMTime(seconds: Double(shared.playhead) / 48000, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        engine.pause()
        player?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        engine.stop()
        head.stop()
    }

    func seek(to seconds: Double) {
        let wasPlaying = playing
        if wasPlaying { pause() }
        shared.playhead = max(0, min(scene.audio.frames, Int(seconds * 48000)))
        position = Double(shared.playhead) / 48000
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updatePositions()
        if wasPlaying { play() }
    }

    func setRenderer(_ r: LiveRenderer) {
        guard r != renderer else { return }
        if r == .sofa && hrtf == nil {
            loadDefaultHRTF()
            if hrtf == nil { return }
        }
        let wasPlaying = playing
        if wasPlaying { pause() }
        engine.stop()
        engine = AVAudioEngine()
        renderer = r
        if wasPlaying { play() }
    }

    func loadHRTF(_ url: URL) {
        do {
            hrtf = try SofaHRTF(url: url, block: Binaural.block)
            hrtfName = url.deletingPathExtension().lastPathComponent
            if renderer != .sofa { setRenderer(.sofa) } else { rebuild() }
        } catch {
            self.error = "Couldn't load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func loadDefaultHRTF() {
        if let url = Engine.root.appendingPathComponent("hrtf").appendingPathComponent("KEMAR.sofa") as URL?,
           FileManager.default.fileExists(atPath: url.path) {
            do {
                hrtf = try SofaHRTF(url: url, block: Binaural.block)
                hrtfName = "KEMAR dummy head"
            } catch { self.error = "Couldn't load the built-in HRTF: \(error.localizedDescription)" }
        } else {
            error = "Choose a SOFA file first."
        }
    }

    func setRoom(_ on: Bool) {
        room = on
        rebuild()
    }

    private func rebuild() {
        let wasPlaying = playing
        if wasPlaying { pause() }
        engine.stop()
        engine = AVAudioEngine()
        if wasPlaying { play() }
    }

    // MARK: graph

    private var built = false
    private func build() throws {
        if engine.isRunning { return }
        if !engine.attachedNodes.filter({ $0 !== engine.mainMixerNode && $0 !== engine.outputNode }).isEmpty { return }
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let audio = scene.audio
        let shared = shared
        let sources = scene.sources

        switch renderer {
        case .apple:
            let env = AVAudioEnvironmentNode()
            env.outputType = .headphones
            env.distanceAttenuationParameters.referenceDistance = 10
            env.distanceAttenuationParameters.maximumDistance = 100
            env.reverbParameters.enable = room
            if room {
                env.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
                env.reverbParameters.level = -12
            }
            engine.attach(env)
            engine.connect(env, to: engine.mainMixerNode, format: stereo)
            var nodes: [(AVAudioSourceNode, Int)] = []
            for (i, s) in sources.enumerated() {
                // every source reads its own channel at the shared playhead; source 0 advances it
                let ch = s.id
                let node = AVAudioSourceNode(format: mono) { _, _, frameCount, abl -> OSStatus in
                    let n = Int(frameCount)
                    let buf = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
                    let start = shared.heads[i]
                    shared.heads[i] = start + n
                    audio.read(ch, from: start, count: n, into: buf)
                    var g = shared.gains[i]
                    vDSP_vsmul(buf, 1, &g, buf, 1, vDSP_Length(n))
                    var rms: Float = 0
                    vDSP_rmsqv(buf, 1, &rms, vDSP_Length(n))
                    shared.levels[i] = max(rms, shared.levels[i] * 0.85)
                    return noErr
                }
                engine.attach(node)
                if s.isLFE {
                    engine.connect(node, to: engine.mainMixerNode, format: mono)
                } else {
                    engine.connect(node, to: env, format: mono)
                    node.renderingAlgorithm = .HRTFHQ
                    node.sourceMode = .pointSource
                    node.reverbBlend = room ? 0.35 : 0
                }
                nodes.append((node, i))
            }
            appleNodes = nodes
            appleEnv = env

        case .sofa:
            guard let hrtf else { throw Shell.Failure(message: "No HRTF loaded.") }
            let bin = Binaural(hrtf: hrtf, scene: scene, shared: shared)
            binaural = bin
            let node = AVAudioSourceNode(format: stereo) { _, _, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                let l = list[0].mData!.assumingMemoryBound(to: Float.self)
                let r = list[1].mData!.assumingMemoryBound(to: Float.self)
                bin.render(frames: Int(frameCount), left: l, right: r)
                return noErr
            }
            engine.attach(node)
            if room {
                let reverb = AVAudioUnitReverb()
                reverb.loadFactoryPreset(.mediumRoom)
                reverb.wetDryMix = 12
                engine.attach(reverb)
                engine.connect(node, to: reverb, format: stereo)
                engine.connect(reverb, to: engine.mainMixerNode, format: stereo)
            } else {
                engine.connect(node, to: engine.mainMixerNode, format: stereo)
            }
        }
        if eqGains.count == 10 && eqGains.contains(where: { abs($0) > 0.05 }) {
            let eq = AVAudioUnitEQ(numberOfBands: 10)
            let freqs: [Float] = [44, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 11300]
            for (i, g) in eqGains.enumerated() {
                let b = eq.bands[i]
                b.filterType = i == 0 ? .lowShelf : i == 9 ? .highShelf : .parametric
                b.frequency = freqs[i]
                b.bandwidth = 1.0
                b.gain = Float(g)
                b.bypass = false
            }
            eq.globalGain = -Float(max(0, eqGains.max() ?? 0)) / 2
            engine.attach(eq)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: eq, format: stereo)
            engine.connect(eq, to: engine.outputNode, format: stereo)
        }
        engine.prepare()
    }

    /// Sign that maps "head turned left" onto AVAudioEnvironmentNode's listener yaw (measured by
    /// the offline self-test).
    var yawSign: Float = -1

    /// Renders `seconds` of the scene offline (no audio device) and returns the stereo result.
    func renderOffline(seconds: Double) throws -> AVAudioPCMBuffer {
        engine.stop()
        engine = AVAudioEngine()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
        try build()
        try engine.start()
        let total = AVAudioFrameCount(seconds * 48000)
        let out = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: total)!
        let chunk = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 512)!
        while out.frameLength < total {
            updatePositions()
            let n = min(512, total - out.frameLength)
            let status = try engine.renderOffline(n, to: chunk)
            guard status == .success else { break }
            for c in 0..<2 {
                memcpy(out.floatChannelData![c] + Int(out.frameLength), chunk.floatChannelData![c], Int(chunk.frameLength) * 4)
            }
            out.frameLength += chunk.frameLength
        }
        engine.stop()
        return out
    }

    private var appleNodes: [(AVAudioSourceNode, Int)] = []
    private weak var appleEnv: AVAudioEnvironmentNode?
    private var binaural: Binaural?

    // MARK: per-frame updates

    private func tick() {
        position = Double(shared.playhead) / 48000
        if shared.playhead >= scene.audio.frames { pause(); return }
        updatePositions()
        // the picture follows the sound
        if let player, playing {
            let drift = player.currentTime().seconds - position
            if abs(drift) > 0.08 {
                player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// Fixed head turn (degrees, positive = left) used by the offline self-test instead of AirPods.
    var testYaw: Float?

    private func updatePositions() {
        let frame = shared.playhead
        var q = head.worldToHead
        var listenerYaw = head.yaw, listenerPitch = head.pitch, listenerRoll = head.roll
        if let y = testYaw {
            q = simd_quatf(angle: y * .pi / 180, axis: [0, 0, 1]).inverse
            listenerYaw = y; listenerPitch = 0; listenerRoll = 0
        }
        var newDots: [LiveDot] = []
        newDots.reserveCapacity(scene.sources.count)
        for (i, s) in scene.sources.enumerated() {
            let st = scene.state(of: i, at: frame, hint: &hints[i])
            shared.gains[i] = st.gain
            let d = scene.direction(st.pos)
            let a = d.az * .pi / 180, e = d.el * .pi / 180
            let world = SIMD3<Float>(cos(e) * cos(a), cos(e) * sin(a), sin(e))
            let local = q.act(world)
            shared.dirs[i] = local
            if renderer == .apple, i < appleNodes.count, !s.isLFE {
                // AVAudioEnvironmentNode: x right, y up, -z forward; head turning is done by the listener
                let node = appleNodes[i].0
                node.position = AVAudio3DPoint(x: -world.y * 2, y: world.z * 2, z: -world.x * 2)
            }
            let level = shared.levels[i] * (st.gain > 0 ? 1 : 0)
            shared.levels[i] *= 0.97
            if !s.isLFE && (s.isBed || st.gain > 0) {
                newDots.append(LiveDot(id: s.id, name: s.name, az: d.az, el: d.el, level: level, isBed: s.isBed))
            }
        }
        if renderer == .apple, let env = appleEnv {
            env.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: yawSign * listenerYaw, pitch: listenerPitch, roll: -listenerRoll)
        }
        dots = newDots
    }
}

/// Binaural rendering with a measured HRTF: every source is convolved with the impulse responses
/// of its nearest measured direction (FFT overlap-add), crossfading when a source changes direction.
final class Binaural {
    static let block = 512
    private let n = Binaural.block           // hop
    private let fftN = 2 * Binaural.block    // FFT size
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let hrtf: SofaHRTF
    private let audio: MasterAudio
    private let shared: LiveEngine.Shared
    private let sourceIDs: [Int]
    private let isLFE: [Bool]
    private var current: [Int]                // HRIR index per source, as rendered last block
    // work buffers
    private var inBlock: [Float]
    private var timeBuf: [Float]
    private var re: [Float], im: [Float]
    private var acc: [[Float]]                // [oldL re, oldL im, oldR re, oldR im, newL re, ..., newR im]
    private var tail: [[Float]]               // overlap for L and R
    private var lfe: [Float]
    private var outFIFO: [[Float]]            // rendered samples not yet handed out
    private var fifoCount = 0
    private var workR: [Float], workI: [Float], outA: [Float], outB: [Float]

    init(hrtf: SofaHRTF, scene: LiveScene, shared: LiveEngine.Shared) {
        self.hrtf = hrtf
        self.audio = scene.audio
        self.shared = shared
        sourceIDs = scene.sources.map(\.id)
        isLFE = scene.sources.map(\.isLFE)
        current = Array(repeating: -1, count: scene.sources.count)
        log2n = vDSP_Length(log2(Double(2 * Binaural.block)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        inBlock = [Float](repeating: 0, count: 2 * Binaural.block)
        timeBuf = [Float](repeating: 0, count: 2 * Binaural.block)
        re = [Float](repeating: 0, count: Binaural.block)
        im = [Float](repeating: 0, count: Binaural.block)
        acc = Array(repeating: [Float](repeating: 0, count: Binaural.block), count: 8)
        tail = Array(repeating: [Float](repeating: 0, count: Binaural.block), count: 2)
        lfe = [Float](repeating: 0, count: Binaural.block)
        outFIFO = Array(repeating: [Float](repeating: 0, count: 8 * Binaural.block), count: 2)
        workR = [Float](repeating: 0, count: Binaural.block)
        workI = [Float](repeating: 0, count: Binaural.block)
        outA = [Float](repeating: 0, count: 2 * Binaural.block)
        outB = [Float](repeating: 0, count: 2 * Binaural.block)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var produced = 0
        while produced < frames {
            if fifoCount == 0 { renderBlock() }
            let take = min(fifoCount, frames - produced)
            let start = n - fifoCount
            outFIFO[0].withUnsafeBufferPointer { left.advanced(by: produced).update(from: $0.baseAddress! + start, count: take) }
            outFIFO[1].withUnsafeBufferPointer { right.advanced(by: produced).update(from: $0.baseAddress! + start, count: take) }
            fifoCount -= take
            produced += take
        }
    }

    private func renderBlock() {
        let frame = shared.playhead
        shared.playhead += n
        for k in 0..<8 { vDSP_vclr(&acc[k], 1, vDSP_Length(n)) }
        vDSP_vclr(&lfe, 1, vDSP_Length(n))
        var anyChange = false

        for i in 0..<sourceIDs.count {
            let g = shared.gains[i]
            if g == 0 { continue }
            inBlock.withUnsafeMutableBufferPointer { audio.read(sourceIDs[i], from: frame, count: n, into: $0.baseAddress!) }
            var gg = g
            vDSP_vsmul(inBlock, 1, &gg, &inBlock, 1, vDSP_Length(n))
            var rms: Float = 0
            vDSP_rmsqv(inBlock, 1, &rms, vDSP_Length(n))
            shared.levels[i] = max(rms, shared.levels[i] * 0.85)
            if isLFE[i] {
                vDSP_vadd(lfe, 1, inBlock, 1, &lfe, 1, vDSP_Length(n))
                continue
            }
            let idx = hrtf.nearest(shared.dirs[i])
            let old = current[i] < 0 ? idx : current[i]
            if old != idx { anyChange = true }
            current[i] = idx
            // spectrum of the zero-padded block (packed real FFT)
            for k in n..<fftN { inBlock[k] = 0 }
            inBlock.withUnsafeBufferPointer { src in
                src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { c in
                    re.withUnsafeMutableBufferPointer { r in
                        im.withUnsafeMutableBufferPointer { m in
                            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                            vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n))
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }
            mulAdd(filter: old, into: 0)
            mulAdd(filter: idx, into: 4)
        }

        // back to time domain; crossfade old→new filters over the block when anything moved
        let scale = 1 / Float(4 * fftN)
        for ear in 0..<2 {
            ifft(acc: 4 + 2 * ear, into: &outB)
            if anyChange {
                ifft(acc: 2 * ear, into: &outA)
                for k in 0..<fftN {
                    let w: Float = k < n ? Float(k) / Float(n) : 1
                    outB[k] = outA[k] * (1 - w) + outB[k] * w
                }
            }
            var s = scale
            vDSP_vsmul(outB, 1, &s, &outB, 1, vDSP_Length(fftN))
            // overlap-add, LFE equally to both ears
            for k in 0..<n {
                outFIFO[ear][k] = outB[k] + tail[ear][k] + lfe[k] * 0.7
                tail[ear][k] = outB[n + k]
            }
        }
        fifoCount = n
    }

    private func mulAdd(filter idx: Int, into base: Int) {
        let h = hrtf.spectra[idx]
        for ear in 0..<2 {
            let hr = h[2 * ear], hi = h[2 * ear + 1]
            let ar = base + 2 * ear, ai = base + 2 * ear + 1
            // packed DC / Nyquist in element 0
            acc[ar][0] += re[0] * hr[0]
            acc[ai][0] += im[0] * hi[0]
            for k in 1..<n {
                acc[ar][k] += re[k] * hr[k] - im[k] * hi[k]
                acc[ai][k] += re[k] * hi[k] + im[k] * hr[k]
            }
        }
    }

    /// Inverse FFT of an accumulator pair into `out` (2·block samples), leaving the accumulator intact.
    private func ifft(acc r: Int, into out: inout [Float]) {
        workR.withUnsafeMutableBufferPointer { tr in
            workI.withUnsafeMutableBufferPointer { ti in
                acc[r].withUnsafeBufferPointer { memcpy(tr.baseAddress!, $0.baseAddress!, n * 4) }
                acc[r + 1].withUnsafeBufferPointer { memcpy(ti.baseAddress!, $0.baseAddress!, n * 4) }
                var work = DSPSplitComplex(realp: tr.baseAddress!, imagp: ti.baseAddress!)
                vDSP_fft_zrip(setup, &work, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { c in
                        vDSP_ztoc(&work, 1, c, 2, vDSP_Length(n))
                    }
                }
            }
        }
    }
}
