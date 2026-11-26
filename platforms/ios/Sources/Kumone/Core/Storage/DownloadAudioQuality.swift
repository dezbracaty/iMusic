#if os(iOS)
import AudioToolbox
import Foundation

enum DownloadQualityError: LocalizedError {
    case unavailable, unsupportedVerification
    case mismatch(String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "所选音源未提供这首歌的指定音质"
        case .unsupportedVerification: return "当前无法校验这档音质，请选择 128、320 kbps 或 FLAC"
        case .mismatch(let received):
            if let received { return "文件音质与所选音质不符（收到 \(received)）" }
            return "无法确认返回文件符合所选音质"
        }
    }
}

struct DownloadAudioQuality: Codable, Hashable {
    let codec: String
    let bitRate: Int?
    let bitDepth: Int?

    var label: String {
        if let bitDepth { return "\(codec) \(bitDepth)-bit" }
        if let bitRate { return "\(codec) 约 \(Int((Double(bitRate) / 1_000).rounded())) kbps" }
        return codec
    }

    // The file reader may report an average rather than the encoder's nominal rate.
    func matches(_ quality: AudioQuality) -> Bool {
        switch quality {
        case .standard:
            return isLossy && bitRate.map { (125_440...130_560).contains($0) } == true
        case .higher, .exhigh:
            return isLossy && bitRate.map { (313_600...326_400).contains($0) } == true
        case .lossless:
            return codec == "FLAC" && bitDepth == 16
        case .hires:
            return codec == "FLAC" && bitDepth == 24
        case .master, .atmos, .dolby, .surround:
            return false
        }
    }

    private var isLossy: Bool { codec == "MP3" || codec == "AAC" }

    static func inspect(_ url: URL) -> Self? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else { return nil }
        var rate: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: rate))
        let hasRate = AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate) == noErr && rate > 0
        let codec: String
        switch format.mFormatID {
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "AAC"
        case kAudioFormatFLAC: codec = "FLAC"
        case kAudioFormatAppleLossless: codec = "ALAC"
        case kAudioFormatLinearPCM: codec = "PCM"
        default: return nil
        }
        var depth = format.mBitsPerChannel
        if depth == 0, codec == "FLAC" || codec == "ALAC" {
            switch format.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: depth = 16
            case kAppleLosslessFormatFlag_20BitSourceData: depth = 20
            case kAppleLosslessFormatFlag_24BitSourceData: depth = 24
            case kAppleLosslessFormatFlag_32BitSourceData: depth = 32
            default: break
            }
        }
        return Self(codec: codec, bitRate: hasRate ? Int(rate) : nil, bitDepth: depth > 0 ? Int(depth) : nil)
    }
}

extension AudioQuality {
    static let verifiableDownloads: [Self] = [.hires, .lossless, .exhigh, .standard]

    var canVerifyDownload: Bool {
        Self.verifiableDownloads.contains { $0.lxType == lxType }
    }

    var downloadLabel: String {
        self == .lossless ? "无损 FLAC 16-bit" : sourceDisplayName
    }
}
#endif
