// Renders a 7.1.4 mix to binaural stereo for ordinary headphones: every speaker is convolved
// with the head-related impulse responses for its direction (Apple's head model or a measured
// head from a SOFA file). Height comes through on any player, without Apple's spatial codec.
//
// usage: binaural [--hrtf apple|FILE.sofa] [--layout "az:el,…" (12 pairs, Apple 7.1.4 order)]
//                 [--top DEG] [--gain DB (default -5)]
// stdin:  f32le 48 kHz, 12 ch (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr)
// stdout: f32le 48 kHz, 2 ch. Same length as the input, no added delay; peaks kept below -1 dBFS.
import Accelerate
import Foundation

func fail(_ m: String) -> Never {
    FileHandle.standardError.write("binaural: \(m)\n".data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let hrtfSpec = opt("--hrtf") ?? "apple"
let top = Float(opt("--top") ?? "45") ?? 45
// measured: unit-energy head responses play ~5 dB louder than the 5.1 copy of the same mix
let gainDB = Float(opt("--gain") ?? "-5") ?? -5

let CH = 12, LFE = 3
var layout: [HRIRSet.Direction] = [(30, 0), (-30, 0), (0, 0), (0, 0), (90, 0), (-90, 0), (150, 0), (-150, 0),
                                   (45, top), (-45, top), (135, top), (-135, top)].map { HRIRSet.Direction(az: $0.0, el: $0.1) }
if let l = opt("--layout") {
    let pairs = l.split(separator: ",").map { $0.split(separator: ":").compactMap { Float($0) } }
    guard pairs.count == CH, pairs.allSatisfy({ $0.count == 2 }) else { fail("--layout needs 12 az:el pairs") }
    layout = pairs.map { HRIRSet.Direction(az: $0[0], el: $0[1]) }
}
let speakers = (0..<CH).filter { $0 != LFE }

let set: HRIRSet
do { set = try HRIRSet.load(hrtfSpec, speakers.map { layout[$0] }) } catch { fail("\(error)") }
FileHandle.standardError.write("binaural: \(set.name) head, \(speakers.count) speakers\n".data(using: .utf8)!)

// ---------- FFT overlap-add: hop N, FFT 2N, filters of length N ----------
let N = HRIRSet.length, F = 2 * N
let log2n = vDSP_Length(log2(Double(F)))
let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

func spectrum(_ x: [Float]) -> (re: [Float], im: [Float]) {
    var padded = x + [Float](repeating: 0, count: F - x.count)
    var re = [Float](repeating: 0, count: N), im = [Float](repeating: 0, count: N)
    re.withUnsafeMutableBufferPointer { r in
        im.withUnsafeMutableBufferPointer { i in
            var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            padded.withUnsafeMutableBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N) { vDSP_ctoz($0, 2, &s, 1, vDSP_Length(N)) }
            }
            vDSP_fft_zrip(fft, &s, 1, log2n, FFTDirection(FFT_FORWARD))
        }
    }
    return (re, im)
}
let filters = (0..<speakers.count).map { (spectrum(set.left[$0]), spectrum(set.right[$0])) }

/// acc += x · h, packed real-FFT layout (element 0 holds DC and Nyquist).
func mulAdd(_ xr: [Float], _ xi: [Float], _ h: (re: [Float], im: [Float]), _ ar: inout [Float], _ ai: inout [Float]) {
    ar[0] += xr[0] * h.re[0]
    ai[0] += xi[0] * h.im[0]
    for k in 1..<N {
        ar[k] += xr[k] * h.re[k] - xi[k] * h.im[k]
        ai[k] += xr[k] * h.im[k] + xi[k] * h.re[k]
    }
}

func inverse(_ r: [Float], _ i: [Float]) -> [Float] {
    var r = r, i = i
    var out = [Float](repeating: 0, count: F)
    r.withUnsafeMutableBufferPointer { rp in
        i.withUnsafeMutableBufferPointer { ip in
            var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(fft, &s, 1, log2n, FFTDirection(FFT_INVERSE))
            out.withUnsafeMutableBufferPointer { o in
                o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N) { vDSP_ztoc(&s, 1, $0, 2, vDSP_Length(N)) }
            }
        }
    }
    return out
}

// ---------- limiter: look-ahead, -1 dBFS, latency removed ----------
let look = 48
let ceiling: Float = 0.891
var delayL = [Float](repeating: 0, count: look), delayR = [Float](repeating: 0, count: look)
var need = [Float](repeating: 1, count: look)   // gain each delayed sample needs
var dpos = 0
var g: Float = 1
let attack: Float = exp(-5 / Float(look)), release: Float = exp(-1 / Float(0.15 * 48000))
var toSkip = look
var outBuf: [Float] = []
outBuf.reserveCapacity(2 * N)
let makeup = pow(10, gainDB / 20)

func limit(_ l: Float, _ r: Float) {
    let peak = max(abs(l), abs(r))
    let want = peak > ceiling ? ceiling / peak : 1
    // the oldest sample leaves the delay line; the newest enters with its requirement
    let oldL = delayL[dpos], oldR = delayR[dpos]
    delayL[dpos] = l; delayR[dpos] = r; need[dpos] = want
    dpos = (dpos + 1) % look
    let target = need.min()!
    let coef: Float = target < g ? attack : release
    g = target + (g - target) * coef
    if toSkip > 0 { toSkip -= 1; return }
    outBuf.append(max(-0.999, min(0.999, oldL * g)))
    outBuf.append(max(-0.999, min(0.999, oldR * g)))
}

// ---------- run ----------
let stdin = FileHandle.standardInput, stdout = FileHandle.standardOutput
var pending = Data()
var tailL = [Float](repeating: 0, count: N), tailR = [Float](repeating: 0, count: N)
let frameBytes = CH * 4

func process(block frames: [Float], count: Int) {
    var accLr = [Float](repeating: 0, count: N), accLi = accLr, accRr = accLr, accRi = accLr
    var lfe = [Float](repeating: 0, count: N)
    var x = [Float](repeating: 0, count: N)
    for (k, ch) in speakers.enumerated() {
        var any = false
        for f in 0..<count { x[f] = frames[f * CH + ch]; if x[f] != 0 { any = true } }
        for f in count..<N { x[f] = 0 }
        if !any { continue }
        let s = spectrum(x)
        mulAdd(s.re, s.im, filters[k].0, &accLr, &accLi)
        mulAdd(s.re, s.im, filters[k].1, &accRr, &accRi)
    }
    for f in 0..<count { lfe[f] = frames[f * CH + LFE] * 0.7 }
    let scale = makeup / Float(4 * F)
    let yl = inverse(accLr, accLi), yr = inverse(accRr, accRi)
    outBuf.removeAll(keepingCapacity: true)
    for f in 0..<count {
        limit((yl[f] + tailL[f]) * scale + lfe[f] * makeup, (yr[f] + tailR[f]) * scale + lfe[f] * makeup)
    }
    // keep the convolution tails for the next block (the hop may be shorter at the very end)
    var nl = [Float](repeating: 0, count: N), nr = nl
    for k in 0..<N {
        let src = count + k
        nl[k] = (src < N ? tailL[src] : 0) + (src < F ? yl[src] : 0)
        nr[k] = (src < N ? tailR[src] : 0) + (src < F ? yr[src] : 0)
    }
    tailL = nl; tailR = nr
    if !outBuf.isEmpty { outBuf.withUnsafeBytes { stdout.write(Data($0)) } }
}

signal(SIGPIPE, SIG_IGN)
var eof = false
while !eof {
    let chunk = stdin.readData(ofLength: N * frameBytes - pending.count)
    if chunk.isEmpty { eof = true } else { pending.append(chunk) }
    if pending.count == N * frameBytes || (eof && pending.count >= frameBytes) {
        let frames = pending.count / frameBytes
        let samples = pending.prefix(frames * frameBytes).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        pending.removeAll(keepingCapacity: true)
        process(block: samples, count: frames)
    }
}
// flush the limiter's look-ahead so the output is exactly as long as the input
outBuf.removeAll()
for _ in 0..<look { limit(0, 0) }
if !outBuf.isEmpty { outBuf.withUnsafeBytes { stdout.write(Data($0)) } }
