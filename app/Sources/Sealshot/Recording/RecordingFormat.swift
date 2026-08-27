import AVFoundation

/// Output container + codec for recordings. Pure; drives writer settings.
enum RecordingFormat: String, CaseIterable, Codable {
    case hevcMov   // smaller, hardware-encoded, Apple-native
    case h264Mp4   // maximum compatibility

    var fileExtension: String {
        switch self { case .hevcMov: return "mov"; case .h264Mp4: return "mp4" }
    }
    var avFileType: AVFileType {
        switch self { case .hevcMov: return .mov; case .h264Mp4: return .mp4 }
    }
    var videoCodec: AVVideoCodecType {
        switch self { case .hevcMov: return .hevc; case .h264Mp4: return .h264 }
    }
    var displayName: String {
        switch self { case .hevcMov: return "HEVC (.mov)"; case .h264Mp4: return "H.264 (.mp4)" }
    }
    /// UTI of the original container, stored in the encrypted header so the
    /// playback resource loader reports the right content type to AVPlayer.
    var uti: String {
        switch self { case .hevcMov: return "com.apple.quicktime-movie"; case .h264Mp4: return "public.mpeg-4" }
    }
}
