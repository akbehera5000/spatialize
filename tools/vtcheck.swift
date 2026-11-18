// Prints "yes" if this Mac decodes the codec in hardware (what QuickTime needs), else "no".
// usage: vtcheck av1|hevc|h264|prores|vp9
import VideoToolbox

let codecs: [String: CMVideoCodecType] = [
    "av1": kCMVideoCodecType_AV1, "hevc": kCMVideoCodecType_HEVC, "h264": kCMVideoCodecType_H264,
    "prores": kCMVideoCodecType_AppleProRes422, "vp9": kCMVideoCodecType_VP9,
]
let name = CommandLine.arguments.dropFirst().first?.lowercased() ?? ""
print(codecs[name].map { VTIsHardwareDecodeSupported($0) } == true ? "yes" : "no")
