// Diagnostic: decodes a file's first audio track through AVFoundation (Apple's own decoder and
// renderer) to 2 (stereo) or 12 (Atmos 7.1.4) channels, raw f32le interleaved on stdout.
// usage: probe FILE 2|12 > out.f32
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let ch = Int(CommandLine.arguments[2]) ?? 2
let sem = DispatchSemaphore(value: 0)
Task {
    let asset = AVURLAsset(url: url)
    let track = try! await asset.loadTracks(withMediaType: .audio)[0]
    let reader = try! AVAssetReader(asset: asset)
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = ch == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Atmos_7_1_4
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: ch,
        AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
    ]
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(out)
    reader.startReading()
    while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        FileHandle.standardOutput.write(Data(bytes: ptr!, count: len))
    }
    if reader.status == .failed { FileHandle.standardError.write("probe: \(reader.error!)\n".data(using: .utf8)!) }
    sem.signal()
}
sem.wait()
