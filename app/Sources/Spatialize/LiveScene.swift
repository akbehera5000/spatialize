import Foundation

/// The decoded audio of a scene preview: the Atmos master (beds + objects, 24-bit CAF) or, for
/// films without objects, the 7.1.4 mix. Memory-mapped, so even long clips cost little RAM.
final class MasterAudio {
    let channels: Int
    let frames: Int
    private let data: NSData
    private let base: UnsafeRawPointer
    private let bytesPerSample: Int
    private let float: Bool
    private let bigEndian: Bool
    private let offset: Int

    init(caf url: URL) throws {
        let d = try NSData(contentsOf: url, options: .alwaysMapped)
        data = d
        base = d.bytes
        let p = base
        func be32(_ o: Int) -> UInt32 { UInt32(p.load(fromByteOffset: o, as: UInt8.self)) << 24 | UInt32(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 16 | UInt32(p.load(fromByteOffset: o + 2, as: UInt8.self)) << 8 | UInt32(p.load(fromByteOffset: o + 3, as: UInt8.self)) }
        func be64(_ o: Int) -> Int64 { Int64(bitPattern: UInt64(be32(o)) << 32 | UInt64(be32(o + 4))) }
        guard d.length > 8, be32(0) == 0x63616666 else { throw Shell.Failure(message: "The preview audio isn't a CAF file.") } // "caff"
        var o = 8
        var desc: (flags: UInt32, ch: Int, bits: Int)?
        var dataStart = 0, dataLen = 0
        while o + 12 <= d.length {
            let kind = be32(o), size = be64(o + 4)
            o += 12
            if kind == 0x64657363 { // desc
                desc = (be32(o + 12), Int(be32(o + 24)), Int(be32(o + 28)))
            } else if kind == 0x64617461 { // data
                dataStart = o + 4
                dataLen = size < 0 ? d.length - dataStart : Int(size) - 4
                break
            }
            o += Int(size)
        }
        guard let desc, dataStart > 0 else { throw Shell.Failure(message: "The preview audio has no PCM data.") }
        channels = desc.ch
        bytesPerSample = desc.bits / 8
        float = desc.flags & 1 != 0
        bigEndian = desc.flags & 2 == 0
        offset = dataStart
        frames = min(dataLen, d.length - dataStart) / (channels * bytesPerSample)
    }

    /// Raw little-endian f32 frames (the 7.1.4 fallback).
    init(rawF32 url: URL, channels: Int) throws {
        let d = try NSData(contentsOf: url, options: .alwaysMapped)
        data = d
        base = d.bytes
        self.channels = channels
        bytesPerSample = 4
        float = true
        bigEndian = false
        offset = 0
        frames = d.length / (channels * 4)
    }

    /// Copies `count` samples of channel `ch` starting at `from` (silence outside the clip).
    @inline(__always)
    func read(_ ch: Int, from: Int, count: Int, into out: UnsafeMutablePointer<Float>) {
        let stride = channels * bytesPerSample
        for i in 0..<count {
            let f = from + i
            guard f >= 0, f < frames else { out[i] = 0; continue }
            let p = base + offset + f * stride + ch * bytesPerSample
            switch (float, bytesPerSample, bigEndian) {
            case (false, 3, true):
                let v = Int32(p.load(as: UInt8.self)) << 24 | Int32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | Int32(p.load(fromByteOffset: 2, as: UInt8.self)) << 8
                out[i] = Float(v) / 2_147_483_648
            case (false, 3, false):
                let v = Int32(p.load(fromByteOffset: 2, as: UInt8.self)) << 24 | Int32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | Int32(p.load(as: UInt8.self)) << 8
                out[i] = Float(v) / 2_147_483_648
            case (false, 2, true):
                out[i] = Float(Int16(bitPattern: UInt16(p.load(as: UInt8.self)) << 8 | UInt16(p.load(fromByteOffset: 1, as: UInt8.self)))) / 32768
            case (false, 2, false):
                out[i] = Float(Int16(bitPattern: p.loadUnaligned(as: UInt16.self))) / 32768
            case (true, 4, false):
                out[i] = p.loadUnaligned(as: Float.self)
            case (true, 4, true):
                out[i] = Float(bitPattern: UInt32(bigEndian: p.loadUnaligned(as: UInt32.self)))
            case (false, 4, true):
                out[i] = Float(Int32(bigEndian: p.loadUnaligned(as: Int32.self))) / 2_147_483_648
            default:
                out[i] = Float(p.loadUnaligned(as: Int32.self)) / 2_147_483_648
            }
        }
    }
}

/// Where every bed channel and object is, over time, from the DAMF metadata. Directions use the
/// same speaker-weighted mapping as the converter's direct mode, so the live player and the
/// finished movie agree.
final class LiveScene {
    struct Segment {
        var start: Int, end: Int
        var from: SIMD3<Float>, to: SIMD3<Float>
        var gainFrom: Float, gainTo: Float
        var active: Bool
    }
    struct Source {
        var id: Int
        var name: String
        var isBed: Bool
        var isLFE: Bool
        var segments: [Segment]
    }

    let audio: MasterAudio
    private(set) var sources: [Source] = []
    let topElevation: Float
    let isObjectBased: Bool

    static let bedNames = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Lts", "Rts"]

    init(directory: URL, topElevation: Float) throws {
        self.topElevation = topElevation
        let header = directory.appendingPathComponent("master.atmos")
        if FileManager.default.fileExists(atPath: header.path) {
            audio = try MasterAudio(caf: directory.appendingPathComponent("master.atmos.audio"))
            isObjectBased = true
            sources = try Self.readObjects(directory.appendingPathComponent("master.atmos.metadata"), channels: audio.channels)
        } else {
            audio = try MasterAudio(rawF32: directory.appendingPathComponent("bed714.f32"), channels: 12)
            isObjectBased = false
            // 7.1.4 speakers as fixed sources, at their DAMF room positions
            let pos: [SIMD3<Float>] = [[-1, 1, 0], [1, 1, 0], [0, 1, 0], [0, 1, 0], [-1, 0, 0], [1, 0, 0],
                                       [-1, -1, 0], [1, -1, 0], [-1, 1, 1], [1, 1, 1], [-1, -1, 1], [1, -1, 1]]
            let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Ltf", "Rtf", "Ltr", "Rtr"]
            sources = (0..<12).map { i in
                Source(id: i, name: names[i], isBed: true, isLFE: i == 3,
                       segments: [Segment(start: 0, end: 0, from: pos[i], to: pos[i], gainFrom: 1, gainTo: 1, active: true)])
            }
        }
    }

    private static func readObjects(_ url: URL, channels: Int) throws -> [Source] {
        let text = try String(contentsOf: url, encoding: .utf8)
        struct Ev { var id = -1, pos: SIMD3<Float>?, gain: Float?, active: Bool?, ramp = 0, sample = -1 }
        var events: [Ev] = []
        var cur: Ev?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var t = raw.trimmingCharacters(in: .whitespaces)[...]
            if t.hasPrefix("- ") {
                if let c = cur { events.append(c) }
                cur = Ev()
                t = t.dropFirst(2)
            }
            guard cur != nil, let colon = t.firstIndex(of: ":") else { continue }
            let key = t[..<colon].trimmingCharacters(in: .whitespaces)
            let val = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "ID": cur!.id = Int(val) ?? -1
            case "samplePos": cur!.sample = Int(val) ?? Int(Double(val) ?? -1)
            case "active": cur!.active = val == "true"
            case "rampLength": cur!.ramp = Int(val) ?? 0
            case "gain": cur!.gain = val.contains("inf") ? 0 : pow(10, (Float(val) ?? 0) / 20)
            case "pos":
                let n = val.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                if n.count == 3 { cur!.pos = SIMD3(n[0], n[1], n[2]) }
            default: break
            }
        }
        if let c = cur { events.append(c) }
        events = events.filter { $0.id >= 0 && $0.sample >= 0 }.sorted { $0.sample < $1.sample }

        let bedPos: [SIMD3<Float>] = [[-1, 1, 0], [1, 1, 0], [0, 1, 0], [0, 1, 0], [-1, 0, 0], [1, 0, 0],
                                      [-1, -1, 0], [1, -1, 0], [-1, 0, 1], [1, 0, 1]]
        var out: [Source] = []
        for id in 0..<channels {
            let isBed = id < 10
            var p = isBed ? bedPos[id] : SIMD3<Float>(0, 1, 0)
            var g: Float = 1
            var active = isBed
            var segs: [Segment] = [Segment(start: 0, end: 0, from: p, to: p, gainFrom: g, gainTo: g, active: active)]
            for e in events where e.id == id {
                // where the previous ramp had got to when this event starts
                if let last = segs.last {
                    let k = last.end > last.start ? min(1, Float(e.sample - last.start) / Float(last.end - last.start)) : 1
                    p = last.from + (last.to - last.from) * k
                    g = last.gainFrom + (last.gainTo - last.gainFrom) * k
                }
                if let a = e.active { active = a }
                let to = isBed ? bedPos[id] : (e.pos ?? p)
                let gt = e.gain ?? g
                segs.append(Segment(start: e.sample, end: e.sample + e.ramp, from: p, to: to, gainFrom: g, gainTo: gt, active: active))
            }
            out.append(Source(id: id, name: isBed ? bedNames[id] : "Object \(id - 9)", isBed: isBed, isLFE: id == 3 && isBed,
                              segments: segs))
        }
        return out
    }

    /// Room position (DAMF cube) and gain of a source at a frame.
    func state(of index: Int, at frame: Int, hint: inout Int) -> (pos: SIMD3<Float>, gain: Float) {
        let segs = sources[index].segments
        if hint >= segs.count || segs[hint].start > frame { hint = 0 }
        while hint + 1 < segs.count && segs[hint + 1].start <= frame { hint += 1 }
        let s = segs[hint]
        guard s.active else { return (s.to, 0) }
        let k: Float = s.end > s.start ? min(1, max(0, Float(frame - s.start) / Float(s.end - s.start))) : 1
        return (s.from + (s.to - s.from) * k, s.gainFrom + (s.gainTo - s.gainFrom) * k)
    }

    /// Direction (azimuth left-positive, elevation, degrees) for a room position: the energy-weighted
    /// direction of the 7.1.4 speakers the converter's panner would use.
    func direction(_ p: SIMD3<Float>) -> (az: Float, el: Float) {
        let g = Self.pan(p)
        let t = topElevation
        let dirs: [(Float, Float)] = [(30, 0), (-30, 0), (0, 0), (0, 0), (90, 0), (-90, 0), (150, 0), (-150, 0),
                                      (45, t), (-45, t), (135, t), (-135, t)]
        var v = SIMD3<Float>(0, 0, 0)
        for c in 0..<12 where c != 3 && g[c] != 0 {
            let (a, e) = (dirs[c].0 * .pi / 180, dirs[c].1 * .pi / 180)
            v += g[c] * g[c] * SIMD3(cos(e) * cos(a), cos(e) * sin(a), sin(e))
        }
        let len = (v * v).sum().squareRoot()
        guard len > 1e-6 else { return (0, 90) }
        return (atan2(v.y, v.x) * 180 / .pi, asin(max(-1, min(1, v.z / len))) * 180 / .pi)
    }

    /// The converter's balance panner (see atmos-render), giving 7.1.4 speaker gains.
    static func pan(_ pos: SIMD3<Float>) -> [Float] {
        let x = max(-1, min(1, pos.x)), y = max(-1, min(1, pos.y)), z = max(0, min(1, pos.z))
        var g = [Float](repeating: 0, count: 12)
        let h = Float.pi / 2
        let ear = cos(z * h), top = sin(z * h)
        func pair(_ x: Float) -> (Float, Float) { let u = (x + 1) * 0.5 * h; return (cos(u), sin(u)) }
        if ear > 1e-6 {
            if y >= 0 {
                let t = y * h
                let (front, side) = (sin(t) * ear, cos(t) * ear)
                if x <= 0 { let u = (x + 1) * h; g[0] += front * cos(u); g[2] += front * sin(u) }
                else { let u = x * h; g[2] += front * cos(u); g[1] += front * sin(u) }
                let (l, r) = pair(x); g[4] += side * l; g[5] += side * r
            } else {
                let t = -y * h
                let (rear, side) = (sin(t) * ear, cos(t) * ear)
                let (l, r) = pair(x)
                g[4] += side * l; g[5] += side * r; g[6] += rear * l; g[7] += rear * r
            }
        }
        if top > 1e-6 {
            let t = (y + 1) * 0.5 * h
            let (front, rear) = (sin(t) * top, cos(t) * top)
            let (l, r) = pair(x)
            g[8] += front * l; g[9] += front * r; g[10] += rear * l; g[11] += rear * r
        }
        return g
    }
}
