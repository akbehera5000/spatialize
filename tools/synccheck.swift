// Checks a finished Spatialize movie against its source: at several points through the film it
// compares the sound of the spatial track (and its AAC copy) with the original track and measures
// how far apart they are. Silent or ambiguous passages are skipped.
//
// usage: synccheck OUT.mov SOURCE --track N [--expect MS] [--start S] [--ffmpeg PATH] [--points 7]
// stdout, one line per checked track:
//   @sync TRACK STATUS OFFSET_MS SPREAD_MS CHECKED TOTAL
//     STATUS ok | off (a steady offset) | drift (the offset changes through the film) | unknown
//     OFFSET_MS median measured offset minus the expected one (positive = audio late)
//     SPREAD_MS largest minus smallest offset across the points (drift)
// and a human-readable summary on stderr.
import AVFoundation
import Accelerate
import Foundation

func fail(_ m: String) -> Never {
    FileHandle.standardError.write("synccheck: \(m)\n".data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("usage: synccheck OUT.mov SOURCE --track N [--expect MS] [--ffmpeg PATH]") }
let outURL = URL(fileURLWithPath: args[0])
let source = args[1]
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let track = opt("--track") ?? "0"
let expectMs = Double(opt("--expect") ?? "0") ?? 0
let ffmpeg = opt("--ffmpeg") ?? "ffmpeg"
let pointCount = Int(opt("--points") ?? "7") ?? 7
let sourceStart = Double(opt("--start") ?? "0") ?? 0   // the movie is a clip starting here in the source

let refLen = 20.0      // seconds of source audio per point
let search = 20.0      // ± seconds searched in the movie

// ---------- audio ----------

/// Source audio as mono 48 kHz, decoded by ffmpeg from a timestamp (accurate seek).
func sourceAudio(at t: Double, length: Double) -> [Float] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg.contains("/") ? ffmpeg : "/usr/bin/env")
    let a = ["-v", "quiet", "-nostdin", "-ss", String(format: "%.3f", t), "-i", source, "-map", "0:a:\(track)",
             "-t", String(format: "%.3f", length), "-ac", "1", "-ar", "48000", "-f", "f32le", "-"]
    p.arguments = ffmpeg.contains("/") ? a : [ffmpeg] + a
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// A movie track as mono 48 kHz, decoded by Apple's decoder (as QuickTime would play it).
func movieAudio(_ asset: AVAsset, _ t: AVAssetTrack, from start: Double, length: Double) -> [Float] {
    guard let r = try? AVAssetReader(asset: asset) else { return [] }
    let s = max(0, start)
    r.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 48000),
                              duration: CMTime(seconds: length - (s - start), preferredTimescale: 48000))
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1, AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
    ])
    guard r.canAdd(o) else { return [] }
    r.add(o)
    guard r.startReading() else { return [] }
    // pad the front with silence when the window starts before zero, so indices stay in seconds
    var out = [Float](repeating: 0, count: Int((s - start) * 48000))
    while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        guard let ptr else { continue }
        ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { out.append(contentsOf: UnsafeBufferPointer(start: $0, count: len / 4)) }
    }
    return out
}

/// 1 kHz log envelope with slow changes removed, so transients (speech, hits) dominate.
func envelope(_ s: [Float]) -> [Float] {
    let n = s.count / 48
    var e = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var m: Float = 0
        s.withUnsafeBufferPointer { vDSP_meamgv($0.baseAddress! + i * 48, 1, &m, 48) }
        e[i] = log(1e-4 + m)
    }
    var out = [Float](repeating: 0, count: n)
    var acc: Float = 0
    let w = 200
    for k in 0..<n {
        acc += e[k]
        if k >= w { acc -= e[k - w] }
        out[k] = e[k] - acc / Float(min(k + 1, w))
    }
    return out
}

/// Where `ref` sits inside `test` (seconds) and how clearly (peak height in standard deviations).
func locate(_ ref: [Float], in test: [Float]) -> (offset: Double, confidence: Float)? {
    let r = envelope(ref), t = envelope(test)
    guard r.count > 1000, t.count > r.count else { return nil }
    // a near-silent reference can't be matched
    var spread: Float = 0, mean: Float = 0
    vDSP_normalize(r, 1, nil, 1, &mean, &spread, vDSP_Length(r.count))
    guard spread > 0.05 else { return nil }
    let n = t.count - r.count + 1
    var c = [Float](repeating: 0, count: n)
    vDSP_conv(t, 1, r, 1, &c, 1, vDSP_Length(n), vDSP_Length(r.count))
    var best: Float = 0
    var bi: vDSP_Length = 0
    vDSP_maxvi(c, 1, &best, &bi, vDSP_Length(n))
    var m: Float = 0, sd: Float = 0
    vDSP_normalize(c, 1, nil, 1, &m, &sd, vDSP_Length(n))
    guard sd > 0 else { return nil }
    return (Double(bi) / 1000, (best - m) / sd)
}

// ---------- run ----------

let sem = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: outURL)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
          let duration = try? await asset.load(.duration).seconds, duration > 0 else { fail("can't read \(outURL.path)") }
    func fourcc(_ t: AVAssetTrack) async -> String {
        guard let f = try? await t.load(.formatDescriptions).first else { return "" }
        let id = CMFormatDescriptionGetMediaSubType(f).bigEndian
        return String(bytes: withUnsafeBytes(of: id) { Array($0) }, encoding: .ascii) ?? ""
    }
    // Sync is audio against picture: if the picture itself starts late (an empty edit before it,
    // e.g. after moving the audio earlier with mux --resync), audio is expected that much later.
    var pictureDelayMs = 0.0
    if let v = try? await asset.loadTracks(withMediaType: .video).first,
       let segs = try? await v.load(.segments), let first = segs.first, first.isEmpty {
        pictureDelayMs = first.timeMapping.target.duration.seconds * 1000
    }
    var checks: [(String, AVAssetTrack)] = []
    for t in tracks where await fourcc(t) == "apac" {
        checks.append(("spatial", t))
        if let c = try? await t.loadAssociatedTracks(ofType: .audioFallback).first { checks.append(("compat", c)) }
    }
    if checks.isEmpty, let first = tracks.first { checks.append(("audio", first)) }

    // points spread through the film, away from the very start and end
    let usable = duration - refLen
    let points: [Double] = usable < 5 ? [0] : (0..<pointCount).map { i in
        let f = (Double(i) + 0.5) / Double(pointCount)
        return max(0, min(usable, f * usable))
    }
    let refs = points.map { sourceAudio(at: sourceStart + $0, length: min(refLen, duration)) }

    for (name, t) in checks {
        var found: [Double] = []
        var detail: [String] = []
        for (p, ref) in zip(points, refs) {
            let test = movieAudio(asset, t, from: p - search, length: refLen + 2 * search)
            guard let hit = locate(ref, in: test), hit.confidence >= 9 else {
                detail.append("\(Int(p))s: –")
                continue
            }
            let offset = (hit.offset - search) * 1000 - expectMs - pictureDelayMs
            found.append(offset)
            detail.append(String(format: "%ds: %+.0f ms", Int(p), offset))
        }
        let status: String
        var median = 0.0, spreadMs = 0.0
        if found.count < min(3, points.count) {
            status = "unknown"
        } else {
            let sorted = found.sorted()
            median = sorted[sorted.count / 2]
            // one stray reading (a misleading passage) mustn't look like drift
            let trimmed = sorted.count >= 5 ? Array(sorted.dropFirst().dropLast()) : sorted
            spreadMs = trimmed.last! - trimmed.first!
            status = spreadMs > 60 ? "drift" : abs(median) > 40 ? "off" : "ok"
        }
        print(String(format: "@sync %@ %@ %.0f %.0f %d %d", name, status, median, spreadMs, found.count, points.count))
        FileHandle.standardError.write("synccheck: \(name) \(status): \(detail.joined(separator: ", "))\n".data(using: .utf8)!)
    }
    sem.signal()
}
sem.wait()
