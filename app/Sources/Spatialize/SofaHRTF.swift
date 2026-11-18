import Accelerate
import CMySofa
import Foundation
import simd

/// A measured head (HRTF) from a SOFA file, as filter spectra ready for block convolution.
final class SofaHRTF {
    let count: Int
    let directions: [SIMD3<Float>]
    /// Per measurement: [left re, left im, right re, right im], packed real-FFT format, length `block`.
    let spectra: [[[Float]]]

    init(url: URL, block: Int) throws {
        var m: Int32 = 0
        var ir: UnsafeMutablePointer<Float>?
        var dir: UnsafeMutablePointer<Float>?
        let status = sofa_load(url.path, 48000, Int32(block), &m, &ir, &dir)
        guard status == 0, let ir, let dir, m > 0 else {
            throw Shell.Failure(message: "not a readable SOFA HRTF (error \(status))")
        }
        defer { sofa_free(ir); sofa_free(dir) }
        count = Int(m)
        directions = (0..<count).map { SIMD3(dir[3 * $0], dir[3 * $0 + 1], dir[3 * $0 + 2]) }

        let fftN = 2 * block
        let log2n = vDSP_Length(log2(Double(fftN)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var specs: [[[Float]]] = []
        specs.reserveCapacity(count)
        var padded = [Float](repeating: 0, count: fftN)
        for i in 0..<count {
            var four: [[Float]] = []
            for ear in 0..<2 {
                for k in 0..<fftN { padded[k] = k < block ? ir[(2 * i + ear) * block + k] : 0 }
                var re = [Float](repeating: 0, count: block), im = [Float](repeating: 0, count: block)
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { mm in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: mm.baseAddress!)
                        padded.withUnsafeBufferPointer { p in
                            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: block) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(block))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
                four.append(re); four.append(im)
            }
            specs.append(four)
        }
        spectra = specs
    }

    /// Index of the measurement closest to a head-relative direction (x forward, y left, z up).
    func nearest(_ d: SIMD3<Float>) -> Int {
        var best = 0
        var bestDot: Float = -2
        for (i, v) in directions.enumerated() {
            let dot = simd_dot(v, d)
            if dot > bestDot { bestDot = dot; best = i }
        }
        return best
    }
}
