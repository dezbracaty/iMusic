#if os(iOS)
import AudioToolbox
import Foundation

enum DownloadQualityError: LocalizedError {
    case unsupportedVerification
    case mismatch(String)
    case unverifiable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedVerification: return "当前无法校验这档音质，请选择 128、320 kbps 或无损档位"
        case .mismatch(let received): return "文件音质与所选音质不符（收到 \(received)）"
        case .unverifiable(let received):
            return received.map { "无法核验返回文件的所选音质（识别为 \($0)）" } ?? "无法核验返回文件的编码或音质"
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
            return isLossy && bitRate.map { (125_440...160_000).contains($0) } == true
        case .higher, .exhigh:
            return isLossy && bitRate.map { (313_600...384_000).contains($0) } == true
        case .lossless:
            return isLossless && bitDepth.map { $0 >= 16 } == true
        case .hires:
            return isLossless && bitDepth.map { $0 >= 24 } == true
        case .master, .atmos, .dolby, .surround:
            return false
        }
    }

    func canCompare(to quality: AudioQuality) -> Bool {
        switch quality {
        case .standard, .higher, .exhigh:
            return isLossy ? bitRate != nil : isLossless
        case .lossless, .hires:
            return isLossless ? bitDepth != nil : isLossy
        case .master, .atmos, .dolby, .surround:
            return false
        }
    }

    private var isLossy: Bool { codec == "MP3" || codec == "AAC" }

    private var isLossless: Bool { codec == "FLAC" || codec == "ALAC" || codec == "PCM" }

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
        case kAudioFormatLinearPCM:
            codec = format.mFormatFlags & kAudioFormatFlagIsFloat == 0 ? "PCM" : "PCM Float"
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
        switch self {
        case .lossless: return "无损 16-bit 或以上"
        case .hires: return "Hi-Res 无损 24-bit 或以上"
        default: return sourceDisplayName
        }
    }
}
#endif
