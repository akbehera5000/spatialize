// Writes the final QuickTime movie, copying samples untouched. AVFoundation does this because
// ffmpeg can't mux APAC.
//
// Build:  mux --video V.mp4 --audio A.caf --out OUT.mov [--compat C.m4a [--compat-kind binaural|surround]]
//             [--surround S.m4a] [--extra E.mov] [--delay SECONDS] [--lang ISO639]
//   Every track of V (video, other languages, text subtitles), the spatial APAC track from A,
//   the copy for other players from C (binaural stereo or 5.1), an extra 5.1 copy from S and
//   any tracks of E (e.g. OCR'd subtitles).
// Resync: mux --resync IN.mov --out OUT.mov --delay SECONDS
//   Re-times an existing Spatialize movie: its main audio (the spatial track and its fallback
//   copy) moves by SECONDS relative to everything else. Nothing is re-encoded.
//
// --delay: positive = main audio later than the picture. Negative values move everything else
// later instead, so the other languages and subtitles stay in step with the picture.
//
// The spatial track is the enabled default of an audio alternate group, so QuickTime plays only
// it and lists the others under View → Languages; subtitles form their own group, off by default.
// The AAC copy is the spatial track's audio fallback, so QuickTime treats the two as one choice
// and plays only the spatial track (measured: marking both enabled makes AVPlayer render both).
// The AAC carries the movie's language and the spatial track none, so mpv-based players with a
// preferred audio language set (IINA: Settings > Codec) pick the AAC; mpv checks language
// before the default flag.
import AVFoundation
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("mux: \(msg)\n".data(using: .utf8)!)
    exit(1)
}
let usage = "usage: mux --video V --audio A --out O [--compat C [--compat-kind K]] [--surround S] [--extra E] [--delay S] [--lang L] | mux --resync IN --out O --delay S"

/// Track names Spatialize gives the copies of the mix; re-timing recognises them by name.
enum TrackName {
    static let spatial = "Spatial Audio"
    static let binaural = "Binaural (headphones)"
    static let surround = "5.1 Surround"
    static let copies: Set<String> = [binaural, surround]
}

var opts: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    guard k.hasPrefix("--"), let v = it.next() else { fail(usage) }
    opts[String(k.dropFirst(2))] = v
}
guard let o = opts["out"] else { fail(usage) }
let outURL = URL(fileURLWithPath: o)
let delay = Double(opts["delay"] ?? "0") ?? 0

enum Role { case spatial, compat, other }

struct Item {
    let asset: AVAsset
    let track: AVAssetTrack
    let role: Role
    var enabled: Bool
    var language: String?        // ISO 639-2 for the track; nil = keep the source's
    var languageTag: String?
    var name: String? = nil
}

func trackName(_ t: AVAssetTrack) async -> String? {
    let items = (try? await t.load(.metadata)) ?? []
    for i in items where i.identifier == .quickTimeUserDataTrackName {
        if let v = try? await i.load(.stringValue) { return v }
    }
    return nil
}

struct Lane {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let reader: AVAssetReader
    let shift: CMTime
}

func shifted(_ sample: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer {
    if shift == .zero { return sample }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for i in timing.indices {
        if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + shift }
        if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + shift }
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                          sampleTimingArray: &timing, sampleBufferOut: &out)
    guard let out else { return sample }
    return out
}

func fourcc(_ t: AVAssetTrack) async -> String {
    guard let f = try? await t.load(.formatDescriptions).first else { return "" }
    let id = CMFormatDescriptionGetMediaSubType(f).bigEndian
    return String(bytes: withUnsafeBytes(of: id) { Array($0) }, encoding: .ascii) ?? ""
}

/// Builds the item list for a fresh movie.
func buildItems() async throws -> [Item] {
    guard let a = opts["audio"] else { fail(usage) }
    // no --video: an audio-only file (music)
    let videoAsset = opts["video"].map { AVURLAsset(url: URL(fileURLWithPath: $0)) }
    let audioAsset = AVURLAsset(url: URL(fileURLWithPath: a))
    let sourceTracks = try await videoAsset?.load(.tracks) ?? []
    guard let spatial = try await audioAsset.loadTracks(withMediaType: .audio).first else { fail("no audio in \(a)") }
    if let v = opts["video"], !sourceTracks.contains(where: { $0.mediaType == .video }) { fail("no video in \(v)") }
    let lang = opts["lang"].flatMap { $0 == "und" || $0.isEmpty ? nil : $0 }
    let tag = lang.map { Locale.LanguageCode($0).identifier(.alpha2) ?? $0 }
    let hasCompat = opts["compat"] != nil

    var items: [Item] = sourceTracks.filter { $0.mediaType == .video }
        .map { Item(asset: videoAsset!, track: $0, role: .other, enabled: true) }
    // the compatible copy comes before the spatial track (players without APAC take it first)
    // The first copy becomes the spatial track's fallback; an extra 5.1 copy follows it, also
    // in the movie's language and timed with the main audio.
    let kind = opts["compat-kind"] == "binaural" ? TrackName.binaural : TrackName.surround
    for (key, name) in [("compat", kind), ("surround", TrackName.surround)] {
        guard let c = opts[key] else { continue }
        let asset = AVURLAsset(url: URL(fileURLWithPath: c))
        if let t = try await asset.loadTracks(withMediaType: .audio).first {
            items.append(Item(asset: asset, track: t, role: .compat, enabled: false, language: lang, languageTag: tag, name: name))
        }
    }
    items.append(Item(asset: audioAsset, track: spatial, role: .spatial, enabled: true,
                      language: hasCompat ? "und" : lang, languageTag: hasCompat ? nil : tag, name: TrackName.spatial))
    for t in sourceTracks where t.mediaType != .video {
        items.append(Item(asset: videoAsset!, track: t, role: .other, enabled: false))
    }
    if let e = opts["extra"] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: e))
        for t in try await asset.load(.tracks) {
            items.append(Item(asset: asset, track: t, role: .other, enabled: false))
        }
    }
    return items
}

/// Reads an existing movie back as items, recognising its spatial track and fallback copy.
func resyncItems(_ path: String) async throws -> [Item] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let tracks = try await asset.load(.tracks)
    var spatialIDs = Set<CMPersistentTrackID>(), compatIDs = Set<CMPersistentTrackID>()
    for t in tracks where t.mediaType == .audio {
        guard await fourcc(t) == "apac" else { continue }
        spatialIDs.insert(t.trackID)
        for f in (try? await t.loadAssociatedTracks(ofType: .audioFallback)) ?? [] { compatIDs.insert(f.trackID) }
    }
    if spatialIDs.isEmpty, let first = tracks.first(where: { $0.mediaType == .audio }) {
        spatialIDs.insert(first.trackID) // not a Spatialize movie: move its default audio track
    }
    var items: [Item] = []
    for t in tracks {
        let name = await trackName(t)
        let isCopy = compatIDs.contains(t.trackID) || (t.mediaType == .audio && name.map(TrackName.copies.contains) == true)
        let role: Role = spatialIDs.contains(t.trackID) ? .spatial : isCopy ? .compat : .other
        items.append(Item(asset: asset, track: t, role: role, enabled: try await t.load(.isEnabled), name: name))
    }
    return items
}

func run() async throws {
    let items: [Item]
    if let r = opts["resync"] { items = try await resyncItems(r) } else { items = try await buildItems() }
    if let r = opts["resync"], URL(fileURLWithPath: r).standardizedFileURL == outURL.standardizedFileURL {
        fail("the output must be a different file")
    }
    try? FileManager.default.removeItem(at: outURL)
    let writer = try AVAssetWriter(outputURL: outURL, fileType: outURL.pathExtension.lowercased() == "m4a" ? .m4a : .mov)
    // --metadata-from SONG: title, artist, album, artwork and so on from the original file
    if let m = opts["metadata-from"] {
        let items = (try? await AVURLAsset(url: URL(fileURLWithPath: m)).load(.commonMetadata)) ?? []
        writer.metadata = items.compactMap { $0.mutableCopy() as? AVMetadataItem }
    }
    var lanes: [Lane] = []
    var audioInputs: [AVAssetWriterInput] = []
    var subtitleInputs: [AVAssetWriterInput] = []
    var defaultAudio: AVAssetWriterInput?
    var spatialInputs: [AVAssetWriterInput] = [], compatInputs: [AVAssetWriterInput] = []
    let mainShift = CMTime(seconds: max(delay, 0), preferredTimescale: 48000)
    let restShift = CMTime(seconds: max(-delay, 0), preferredTimescale: 48000)

    for item in items {
        let track = item.track
        let type = track.mediaType
        let kinds: [AVMediaType] = [.video, .audio, .text, .subtitle, .closedCaption]
        guard kinds.contains(type) else { continue }
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { continue }
        reader.add(output)
        let formats = try await track.load(.formatDescriptions)
        let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        if type == .video { input.transform = try await track.load(.preferredTransform) }
        if let l = item.language {
            input.languageCode = l
            if let tag = item.languageTag { input.extendedLanguageTag = tag }
        } else {
            if let code = try await track.load(.languageCode) { input.languageCode = code }
            if let tag = try await track.load(.extendedLanguageTag) { input.extendedLanguageTag = tag }
        }
        input.marksOutputTrackAsEnabled = item.enabled
        if let name = item.name {
            let m = AVMutableMetadataItem()
            m.identifier = .quickTimeUserDataTrackName
            m.value = name as NSString
            input.metadata = [m]
        }
        guard writer.canAdd(input) else {
            FileHandle.standardError.write("mux: skipping a \(type.rawValue) track the movie can't hold\n".data(using: .utf8)!)
            continue
        }
        writer.add(input)
        if type == .audio && item.role != .compat { audioInputs.append(input) }
        if type == .text || type == .subtitle { subtitleInputs.append(input) }
        if item.role == .spatial { spatialInputs.append(input); defaultAudio = defaultAudio ?? input }
        if item.role == .compat { compatInputs.append(input) }
        if type == .audio && item.enabled && defaultAudio == nil { defaultAudio = input }
        lanes.append(Lane(output: output, input: input, reader: reader,
                          shift: item.role == .other ? restShift : mainShift))
    }

    let fall = AVAssetTrack.AssociationType.audioFallback.rawValue
    for (s, c) in zip(spatialInputs, compatInputs) where s.canAddTrackAssociation(withTrackOf: c, type: fall) {
        s.addTrackAssociation(withTrackOf: c, type: fall)
    }
    audioInputs.insert(contentsOf: compatInputs, at: 0)
    if audioInputs.count > 1, let defaultAudio {
        let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: defaultAudio)
        if writer.canAdd(group) { writer.add(group) }
    }
    if !subtitleInputs.isEmpty {
        let group = AVAssetWriterInputGroup(inputs: subtitleInputs, defaultInput: nil)
        if writer.canAdd(group) { writer.add(group) }
    }

    for lane in lanes { guard lane.reader.startReading() else { throw lane.reader.error! } }
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)

    await withTaskGroup(of: Void.self) { group in
        for (i, lane) in lanes.enumerated() {
            group.addTask {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    var shift: CMTime?
                    lane.input.requestMediaDataWhenReady(on: DispatchQueue(label: "mux.lane\(i)")) {
                        while lane.input.isReadyForMoreMediaData {
                            if let sample = lane.output.copyNextSampleBuffer() {
                                if shift == nil {
                                    // Measured: a track that starts after zero gets its encoder
                                    // padding (the first buffer's trim) added to its start as well,
                                    // so start that much earlier to land exactly on the shift.
                                    let trim = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil)
                                        .map { CMTimeMakeFromDictionary(($0 as! CFDictionary)) } ?? .zero
                                    shift = lane.shift > .zero && trim.isValid ? lane.shift - trim : lane.shift
                                }
                                lane.input.append(shifted(sample, by: shift!))
                            } else {
                                lane.input.markAsFinished()
                                done.resume()
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "mux", code: 1) }
    for lane in lanes where lane.reader.status == .failed { throw lane.reader.error! }
}

let sem = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch { fail("\(error)") }
    sem.signal()
}
sem.wait()
