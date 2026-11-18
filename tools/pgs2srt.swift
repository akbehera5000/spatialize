// Reads Blu-ray picture subtitles (PGS, a .sup stream) and turns them into SRT text with Apple's
// Vision text recognition, so QuickTime can show them as normal subtitles.
// usage: pgs2srt IN.sup [LANGUAGE (ISO 639-2, e.g. eng)] > out.srt
import AppKit
import Foundation
import Vision

func fail(_ m: String) -> Never {
    FileHandle.standardError.write("pgs2srt: \(m)\n".data(using: .utf8)!)
    exit(1)
}
let args = CommandLine.arguments
guard args.count >= 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("usage: pgs2srt IN.sup [LANG]") }
let lang = args.count > 2 ? args[2] : "eng"

// ISO 639-2 → the BCP 47 codes Vision understands
let visionLang: [String: String] = [
    "eng": "en-US", "fre": "fr-FR", "fra": "fr-FR", "ger": "de-DE", "deu": "de-DE", "ita": "it-IT",
    "spa": "es-ES", "por": "pt-BR", "chi": "zh-Hans", "zho": "zh-Hans", "kor": "ko-KR", "jpn": "ja-JP",
    "rus": "ru-RU", "ukr": "uk-UA", "tha": "th-TH", "vie": "vi-VT", "ara": "ar-SA", "tur": "tr-TR",
    "dut": "nl-NL", "nld": "nl-NL", "pol": "pl-PL", "cze": "cs-CZ", "ces": "cs-CZ", "dan": "da-DK",
    "swe": "sv-SE", "nor": "no-NO", "fin": "fi-FI", "ind": "id-ID", "msa": "ms-MY", "may": "ms-MY",
    "rum": "ro-RO", "ron": "ro-RO", "hun": "hu-HU", "hrv": "hr-HR", "slv": "sl-SI", "bul": "bg-BG",
    "gre": "el-GR", "ell": "el-GR", "heb": "he-IL", "est": "et-EE", "lav": "lv-LV", "lit": "lt-LT",
    "ice": "is-IS", "isl": "is-IS", "srp": "sr-Latn",
]
let request0 = VNRecognizeTextRequest()
let supported = Set((try? request0.supportedRecognitionLanguages()) ?? [])
let wanted = visionLang[lang] ?? "en-US"
// Vision lists some languages without a region; match on the base code too
let recogLang = supported.first(where: { $0 == wanted }) ?? supported.first(where: { $0.hasPrefix(String(wanted.prefix(2))) })
if recogLang == nil { fail("text recognition doesn't support \(lang) on this Mac") }

// ---------- PGS parsing ----------

struct Object { var width = 0, height = 0, rle = Data() }
struct Placement { let objectID: Int, x: Int, y: Int }
struct Cue { var start: Double, end: Double = -1, image: CGImage }

var palettes: [Int: [UInt32]] = [:]     // palette id → 256 RGBA (premultiplied for drawing)
var objects: [Int: Object] = [:]
var cues: [Cue] = []
var pending: (pts: Double, paletteID: Int, placements: [Placement], width: Int, height: Int)?
var openCue: Int?

func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1]) }
func u24(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 16 | u16(d, o + 1) }
func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) << 16 | UInt32(u16(d, o + 2)) }

/// Decodes the run-length pixel data of one object into palette indices.
func decodeRLE(_ o: Object) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: o.width * o.height)
    var i = o.rle.startIndex, x = 0, y = 0
    let end = o.rle.endIndex
    func next() -> Int? { guard i < end else { return nil }; defer { i += 1 }; return Int(o.rle[i]) }
    while y < o.height, let b = next() {
        var color = 0, run = 1
        if b != 0 { color = b } else {
            guard let f = next() else { break }
            if f == 0 { x = 0; y += 1; continue }
            switch f >> 6 {
            case 0: run = f & 0x3F
            case 1: run = (f & 0x3F) << 8 | (next() ?? 0)
            case 2: run = f & 0x3F; color = next() ?? 0
            default: run = (f & 0x3F) << 8 | (next() ?? 0); color = next() ?? 0
            }
        }
        for _ in 0..<run where x < o.width { px[y * o.width + x] = UInt8(color); x += 1 }
    }
    return px
}

/// Renders a display set as dark text on white (what text recognition reads best), cropped to
/// the subtitle and scaled up.
func render(_ set: (pts: Double, paletteID: Int, placements: [Placement], width: Int, height: Int)) -> CGImage? {
    guard let pal = palettes[set.paletteID] else { return nil }
    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    var decoded: [(Placement, Object, [UInt8])] = []
    for p in set.placements {
        guard let o = objects[p.objectID], o.width > 0, o.height > 0 else { continue }
        decoded.append((p, o, decodeRLE(o)))
        minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x + o.width); maxY = max(maxY, p.y + o.height)
    }
    guard !decoded.isEmpty else { return nil }
    let pad = 16, scale = 2
    let w = (maxX - minX + 2 * pad), h = (maxY - minY + 2 * pad)
    var gray = [UInt8](repeating: 255, count: w * h)
    for (p, o, px) in decoded {
        for yy in 0..<o.height {
            for xx in 0..<o.width {
                let c = pal[Int(px[yy * o.width + xx])]
                let (luma, alpha) = (Double((c >> 24) & 0xFF) / 255, Double(c & 0xFF) / 255)
                // subtitle fill is bright, its outline dark: ink = how bright and opaque it is
                let ink = alpha * luma
                gray[(p.y - minY + pad + yy) * w + (p.x - minX + pad + xx)] = UInt8(max(0, min(255, 255 * (1 - ink))))
            }
        }
    }
    let cs = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: nil, width: w * scale, height: h * scale, bitsPerComponent: 8, bytesPerRow: w * scale,
                              space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let provider = CGDataProvider(data: Data(gray) as CFData),
          let src = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: cs,
                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true,
                            intent: .defaultIntent)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w * scale, height: h * scale))
    return ctx.makeImage()
}

var o = data.startIndex
while o + 13 <= data.endIndex {
    guard data[o] == 0x50, data[o + 1] == 0x47 else { o += 1; continue } // "PG"
    let seg = data.subdata(in: o..<min(data.endIndex, o + 13))
    let pts = Double(u32(seg, 2)) / 90000
    let type = seg[seg.startIndex + 10]
    let size = u16(seg, 11)
    let body = data.subdata(in: (o + 13)..<min(data.endIndex, o + 13 + size))
    o += 13 + size
    switch type {
    case 0x14: // palette
        guard body.count >= 2 else { continue }
        let id = Int(body[body.startIndex])
        var pal = palettes[id] ?? [UInt32](repeating: 0, count: 256)
        var k = 2
        while k + 5 <= body.count {
            let idx = Int(body[body.startIndex + k])
            let yv = UInt32(body[body.startIndex + k + 1]), a = UInt32(body[body.startIndex + k + 4])
            pal[idx] = yv << 24 | a // only luma and alpha matter for reading text
            k += 5
        }
        palettes[id] = pal
    case 0x15: // object
        guard body.count >= 4 else { continue }
        let id = u16(body, 0)
        let flags = body[body.startIndex + 3]
        if flags & 0x80 != 0, body.count >= 11 {
            var obj = Object()
            obj.width = u16(body, 7); obj.height = u16(body, 9)
            obj.rle = body.subdata(in: (body.startIndex + 11)..<body.endIndex)
            objects[id] = obj
        } else {
            objects[id, default: Object()].rle.append(body.subdata(in: (body.startIndex + 4)..<body.endIndex))
        }
    case 0x16: // presentation composition
        guard body.count >= 11 else { continue }
        let width = u16(body, 0), height = u16(body, 2)
        let paletteID = Int(body[body.startIndex + 9])
        let n = Int(body[body.startIndex + 10])
        var placements: [Placement] = []
        var k = 11
        for _ in 0..<n where k + 8 <= body.count {
            let objID = u16(body, k), cropped = body[body.startIndex + k + 3] & 0x80 != 0
            placements.append(Placement(objectID: objID, x: u16(body, k + 4), y: u16(body, k + 6)))
            k += cropped ? 16 : 8
        }
        // any new composition ends the subtitle on screen
        if let c = openCue { cues[c].end = pts; openCue = nil }
        pending = placements.isEmpty ? nil : (pts, paletteID, placements, width, height)
    case 0x80: // end of display set: everything for the pending composition has arrived
        if let set = pending, let img = render(set) {
            cues.append(Cue(start: set.pts, image: img))
            openCue = cues.count - 1
        }
        pending = nil
    default:
        break
    }
}
if let c = openCue { cues[c].end = cues[c].start + 4 }

// ---------- OCR ----------

var texts = [String](repeating: "", count: cues.count)
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: cues.count) { i in
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    if let recogLang { req.recognitionLanguages = [recogLang] }
    let handler = VNImageRequestHandler(cgImage: cues[i].image, options: [:])
    try? handler.perform([req])
    let lines = (req.results ?? [])
        .sorted { $0.boundingBox.midY > $1.boundingBox.midY } // top line first
        .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    lock.lock(); texts[i] = lines.joined(separator: "\n"); lock.unlock()
}

func stamp(_ t: Double) -> String {
    let ms = Int((max(0, t) * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}
var out = "", n = 0
for (i, cue) in cues.enumerated() where !texts[i].isEmpty && cue.end > cue.start {
    n += 1
    out += "\(n)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(texts[i])\n\n"
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
FileHandle.standardError.write("pgs2srt: \(n) subtitles from \(cues.count) pictures (\(recogLang ?? "?"))\n".data(using: .utf8)!)
