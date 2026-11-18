// Encodes raw interleaved f32le 7.1.4 audio from stdin into an Apple APAC (Apple Positional
// Audio Codec) CAF file tagged with the Atmos 7.1.4 channel layout, so macOS can spatialize it.
// Channel order on stdin: L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr.
// usage: apacenc OUT.caf [SAMPLE_RATE=48000] [BITRATE=0 (encoder default)]
import AudioToolbox
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("apacenc: \(msg)\n".data(using: .utf8)!)
    exit(1)
}
func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (\(status))") }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: apacenc OUT.caf [SAMPLE_RATE] [BITRATE]") }
let outURL = URL(fileURLWithPath: args[1]) as CFURL
let sampleRate = args.count > 2 ? Double(args[2]) ?? 48000 : 48000
let bitrate = args.count > 3 ? UInt32(args[3]) ?? 0 : 0
// 4th argument "hoaN": N-channel ambisonics (ACN order, SN3D), e.g. hoa16 = 3rd order
let hoaChannels: UInt32? = args.count > 4 && args[4].hasPrefix("hoa") ? UInt32(args[4].dropFirst(3)) : nil
let channels: UInt32 = hoaChannels ?? 12
let layoutTag = hoaChannels.map { kAudioChannelLayoutTag_HOA_ACN_SN3D | $0 } ?? kAudioChannelLayoutTag_Atmos_7_1_4

var pcm = AudioStreamBasicDescription(
    mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)

var apac = AudioStreamBasicDescription()
apac.mSampleRate = sampleRate
apac.mFormatID = kAudioFormatAPAC
apac.mChannelsPerFrame = channels

var layout = AudioChannelLayout()
layout.mChannelLayoutTag = layoutTag

var file: ExtAudioFileRef?
check(ExtAudioFileCreateWithURL(outURL, kAudioFileCAFType, &apac, &layout,
                                AudioFileFlags.eraseFile.rawValue, &file), "create APAC file")
guard let file else { fail("no file") }
check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                              UInt32(MemoryLayout.size(ofValue: pcm)), &pcm), "set client format")
check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientChannelLayout,
                              UInt32(MemoryLayout.size(ofValue: layout)), &layout), "set client layout")

if bitrate > 0 {
    var conv: AudioConverterRef?
    var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
    check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &conv), "get converter")
    if let conv {
        var br = bitrate
        check(AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate,
                                        UInt32(MemoryLayout.size(ofValue: br)), &br), "set bitrate")
        var nilConfig: CFArray? = nil
        check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                      UInt32(MemoryLayout<CFArray?>.size), &nilConfig), "apply bitrate")
    }
}

let framesPerChunk = 4096
let bytesPerChunk = framesPerChunk * Int(channels) * 4
let stdin = FileHandle.standardInput
var buffer = [UInt8](repeating: 0, count: bytesPerChunk)
var total: Int64 = 0
var pending = 0
// Optional progress for the app: A2A_PROGRESS=1 A2A_DURATION=secs A2A_LANE A2A_FROM A2A_TO
let env = ProcessInfo.processInfo.environment
let reportProgress = env["A2A_PROGRESS"] == "1"
let duration = Double(env["A2A_DURATION"] ?? "") ?? 0
let lane = env["A2A_LANE"] ?? "audio"
let from = Double(env["A2A_FROM"] ?? "") ?? 0
let to = Double(env["A2A_TO"] ?? "") ?? 1
var lastReport = Date.distantPast
func report() {
    guard reportProgress, duration > 0, Date().timeIntervalSince(lastReport) > 0.5 else { return }
    lastReport = Date()
    let f = min(1, Double(total) / sampleRate / duration)
    print(String(format: "@progress %@ %.4f", lane, from + (to - from) * f))
    fflush(stdout)
}

while true {
    // fill the chunk completely unless the stream ends
    while pending < bytesPerChunk {
        let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress! + pending, bytesPerChunk - pending) }
        if n <= 0 { break }
        pending += n
    }
    let frames = pending / (Int(channels) * 4)
    if frames == 0 { break }
    buffer.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(frames * Int(channels) * 4),
                                  mData: raw.baseAddress))
        check(ExtAudioFileWrite(file, UInt32(frames), &list), "encode")
    }
    total += Int64(frames)
    report()
    let used = frames * Int(channels) * 4
    if pending < bytesPerChunk { break }
    pending -= used
}
_ = stdin
check(ExtAudioFileDispose(file), "finish file")
FileHandle.standardError.write(String(format: "apacenc: encoded %.1f s\n", Double(total) / sampleRate).data(using: .utf8)!)
