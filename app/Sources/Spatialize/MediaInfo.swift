import Foundation
import VideoToolbox

/// What ffprobe tells us about a movie, reduced to what the app shows and decides on.
struct MediaInfo {
    struct Video {
        var codec: String
        var width: Int
        var height: Int
        var fps: Double
        var bitDepth: Int
        var isHDR: Bool
        var transfer: String
        var dolbyVisionProfile: Int?
    }

    struct AudioTrack: Identifiable, Hashable {
        var id: Int          // index among audio tracks (ffmpeg a:N)
        var codec: String
        var profile: String
        var channels: Int
        var language: String
        var title: String
        var isAtmos: Bool

        var codecName: String {
            switch codec {
            case "truehd": return "Dolby TrueHD"
            case "eac3": return "Dolby Digital Plus"
            case "ac3": return "Dolby Digital"
            case "dts": return profile.isEmpty ? "DTS" : profile
            case "aac": return "AAC"
            case "flac": return "FLAC"
            case "opus": return "Opus"
            default: return codec.uppercased()
            }
        }
        var channelName: String {
            switch channels {
            case 1: return "Mono"
            case 2: return "Stereo"
            case 6: return "5.1"
            case 8: return "7.1"
            default: return "\(channels) ch"
            }
        }
        var languageName: String { MediaInfo.languageName(language) }
        /// How well this track can be spatialized: objects > multichannel > stereo.
        var score: Int {
            (isAtmos ? 100 : 0) + (codec == "truehd" ? 20 : codec == "eac3" ? 15 : codec == "ac3" ? 10 : 0) + channels
        }
    }

    struct SubtitleTrack: Identifiable, Hashable {
        var id: Int          // index among subtitle tracks (ffmpeg s:N)
        var codec: String
        var language: String
        var title: String
        var forced: Bool
        var isText: Bool { ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec) }
        var languageName: String { MediaInfo.languageName(language) }
        var formatName: String {
            switch codec {
            case "subrip", "srt": return "SRT"
            case "ass", "ssa": return "ASS"
            case "hdmv_pgs_subtitle": return "PGS (image)"
            case "dvd_subtitle": return "VobSub (image)"
            case "webvtt": return "WebVTT"
            default: return codec.uppercased()
            }
        }
    }

    var url: URL
    var duration: Double
    var fileSize: Int64
    var title: String
    var video: Video?
    var audio: [AudioTrack]
    var subtitles: [SubtitleTrack]

    var bestAudio: AudioTrack? { audio.max { $0.score < $1.score } }

    /// Whether this Mac can play the video in QuickTime without converting.
    var videoPlaysAsIs: Bool {
        guard let v = video else { return false }
        switch v.codec {
        case "h264": return true
        case "hevc": return v.dolbyVisionProfile != 7
        case "av1": return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        case "vp9": return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        default: return false
        }
    }

    static func languageName(_ code: String) -> String {
        guard !code.isEmpty, code != "und" else { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    // MARK: - probing

    static func load(_ url: URL, ffprobe: URL) async throws -> MediaInfo {
        let data = try await Shell.output(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        var info = MediaInfo(
            url: url,
            duration: Double(probe.format?.duration ?? "") ?? 0,
            fileSize: Int64(probe.format?.size ?? "") ?? 0,
            title: cleanTitle(url.deletingPathExtension().lastPathComponent),
            video: nil, audio: [], subtitles: [])
        for s in probe.streams {
            switch s.codec_type {
            case "video" where info.video == nil && s.disposition?.attached_pic != 1:
                let fpsParts = (s.r_frame_rate ?? "0/1").split(separator: "/").compactMap { Double($0) }
                let fps = fpsParts.count == 2 && fpsParts[1] > 0 ? fpsParts[0] / fpsParts[1] : 0
                let trc = s.color_transfer ?? ""
                info.video = Video(
                    codec: s.codec_name ?? "?", width: s.width ?? 0, height: s.height ?? 0, fps: fps,
                    bitDepth: (s.pix_fmt ?? "").contains("10") ? 10 : (s.pix_fmt ?? "").contains("12") ? 12 : 8,
                    isHDR: trc == "smpte2084" || trc == "arib-std-b67", transfer: trc,
                    dolbyVisionProfile: s.side_data_list?.compactMap { $0.dv_profile }.first)
            case "audio":
                let title = s.tags?.title ?? ""
                let profile = s.profile ?? ""
                info.audio.append(AudioTrack(
                    id: info.audio.count, codec: s.codec_name ?? "?", profile: profile,
                    channels: s.channels ?? 2, language: s.tags?.language ?? "und", title: title,
                    isAtmos: profile.localizedCaseInsensitiveContains("atmos") || title.localizedCaseInsensitiveContains("atmos")))
            case "subtitle":
                info.subtitles.append(SubtitleTrack(
                    id: info.subtitles.count, codec: s.codec_name ?? "?", language: s.tags?.language ?? "und",
                    title: s.tags?.title ?? "", forced: s.disposition?.forced == 1))
            default: break
            }
        }
        return info
    }

    /// "Gravity (2013) UPSCALED 2160p 4K HDR10 ... .mkv" → "Gravity (2013)"
    static func cleanTitle(_ name: String) -> String {
        let s = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        if let r = s.range(of: #"^.*?\((19|20)\d{2}\)"#, options: .regularExpression) { return String(s[r]) }
        if let r = s.range(of: #"\b(2160p|1080p|720p|4K|UHD|BluRay|WEB|HDR|x26[45]|AV1|HEVC)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let t = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return s
    }
}

// MARK: - ffprobe JSON

private struct Probe: Decodable {
    struct Format: Decodable { var duration: String?; var size: String? }
    struct Tags: Decodable { var language: String?; var title: String? }
    struct Disposition: Decodable { var forced: Int?; var attached_pic: Int? }
    struct SideData: Decodable { var dv_profile: Int? }
    struct Stream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var profile: String?
        var channels: Int?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var color_transfer: String?
        var r_frame_rate: String?
        var tags: Tags?
        var disposition: Disposition?
        var side_data_list: [SideData]?
    }
    var streams: [Stream]
    var format: Format?
}

// MARK: - running tools

enum Shell {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func output(_ tool: URL, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = tool
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // read before waiting so a large output can't fill the pipe and stall the tool
                var errData = Data()
                let errReader = DispatchQueue(label: "stderr")
                errReader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                errReader.sync {}
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "\(tool.lastPathComponent) failed" : msg))
                }
            }
        }
    }
}
