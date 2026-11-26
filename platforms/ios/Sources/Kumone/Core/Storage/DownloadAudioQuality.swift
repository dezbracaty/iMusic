#if os(iOS)
import AudioToolbox
import Foundation

enum DownloadQualityError: LocalizedError {
    case unsupportedVerification
    case mismatch(String)
    case unverifiable(String?)
    case masterSpecificationsMismatch(String)
    case masterSpecificationsUnverifiable(String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedVerification: return "当前无法校验这档音质，请选择 128、320 kbps 或无损档位"
        case .mismatch(let received): return "文件音质与所选音质不符（收到 \(received)）"
        case .unverifiable(let received):
            return received.map { "无法核验返回文件的所选音质（识别为 \($0)）" } ?? "无法核验返回文件的编码或音质"
        case .masterSpecificationsMismatch(let received):
            return "酷狗母带下载需 192 kHz、24-bit 或以上无损（收到 \(received)），可换档下载"
        case .masterSpecificationsUnverifiable(let received):
            let detail = received.map { "（识别为 \($0)）" } ?? ""
            return "无法核验母带请求返回文件的无损位深和采样率\(detail)，可换档下载"
        }
    }
}

enum DownloadMasterRule {
    static let platform = "kg"
    static let requestKeys = ["master", "jymaster", "viper_tape"]
    // Kugou's VIPER certification lists 192 kHz for Master and 96 kHz for
    // Hi-Res: https://ksyx.kugou.com/authorise.html
    // Require high-bit-depth lossless for this download option. These checks
    // establish file specifications only, not the recording's provenance.
    static let sampleRate = 192_000
    static let minimumBitDepth = 24
}

struct DownloadAudioQuality: Codable, Hashable {
    let codec: String
    let bitRate: Int?
    let bitDepth: Int?
    let sampleRate: Int?

    init(codec: String, bitRate: Int?, bitDepth: Int?, sampleRate: Int? = nil) {
        self.codec = codec
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
    }

    var label: String {
        if let bitDepth { return "\(codec) \(bitDepth)-bit" }
        if let bitRate { return "\(codec) 约 \(Int((Double(bitRate) / 1_000).rounded())) kbps" }
        return codec
    }

    var specificationLabel: String {
        guard let sampleRate else { return label }
        let kilohertz = (Double(sampleRate) / 1_000).formatted(.number.precision(.fractionLength(0...3)))
        return "\(label) · \(kilohertz) kHz"
    }

    // The file reader may report an average rather than the encoder's nominal rate.
    func matchesFileSpecifications(for quality: AudioQuality) -> Bool {
        switch quality {
        case .standard:
            return isLossy && bitRate.map { (125_440...160_000).contains($0) } == true
        case .higher, .exhigh:
            return isLossy && bitRate.map { (313_600...384_000).contains($0) } == true
        case .lossless:
            return isLossless && bitDepth.map { $0 >= 16 } == true
        case .hires:
            return isLossless && bitDepth.map { $0 >= 24 } == true
        case .master:
            return isLossless && sampleRate == DownloadMasterRule.sampleRate
                && bitDepth.map { $0 >= DownloadMasterRule.minimumBitDepth } == true
        case .atmos, .dolby, .surround:
            return false
        }
    }

    func canCompare(to quality: AudioQuality) -> Bool {
        switch quality {
        case .standard, .higher, .exhigh:
            return isLossy ? bitRate != nil : isLossless
        case .lossless, .hires:
            return isLossless ? bitDepth != nil : isLossy
        case .master:
            return isLossy || codec == "PCM Float" || (isLossless && bitDepth != nil && sampleRate != nil)
        case .atmos, .dolby, .surround:
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
        let sampleRate = format.mSampleRate
        let measuredSampleRate = sampleRate > 0 && sampleRate < Double(Int32.max)
            ? Int(exactly: sampleRate) : nil
        return Self(codec: codec, bitRate: hasRate ? Int(rate) : nil, bitDepth: depth > 0 ? Int(depth) : nil,
                    sampleRate: measuredSampleRate)
    }
}

extension AudioQuality {
    static let downloadOptions: [Self] = [.master, .hires, .lossless, .exhigh, .standard]

    var canAttemptDownload: Bool {
        Self.downloadOptions.contains { $0.lxType == lxType }
    }

    var downloadLabel: String {
        switch self {
        case .master: return "母带 / Master（酷狗规格核验）"
        case .lossless: return "无损 16-bit 或以上"
        case .hires: return "Hi-Res 无损 24-bit 或以上"
        default: return sourceDisplayName
        }
    }
}
#endif
