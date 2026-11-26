#if os(iOS)
import Foundation

struct DownloadCandidate {
    let url: URL
    let track: Track
    let sourceID: String?
    var sourceName: String?
    var requestToken: String?
}

struct VerifiedDownload {
    let candidate: DownloadCandidate
    let file: URL
    let audio: DownloadAudioQuality
}

typealias FindDownload = @MainActor (
    Track, AudioQuality, @MainActor (DownloadCandidate) async throws -> VerifiedDownload
) async throws -> VerifiedDownload

enum DownloadAttemptFailure: LocalizedError {
    case transfer(String)
    case validation(String)
    case noRecording
    case restrictedRecording
    case noInterface
    case sourceUnavailable
    case missingQuality
    case noAddress
    case resolutionTimeout
    case noSources

    var errorDescription: String? {
        switch self {
        case .transfer(let reason), .validation(let reason): return reason
        case .noRecording: return "没有找到可确认的同一录音"
        case .restrictedRecording: return "候选录音受版权、付费或账号限制"
        case .noInterface: return "音源未提供可用平台的播放接口"
        case .sourceUnavailable: return "LX 音源未能初始化"
        case .missingQuality: return "音源未提供所选音质"
        case .noAddress: return "音源未返回所选音质的有效地址"
        case .resolutionTimeout: return "LX 音源解析超时"
        case .noSources: return "请先导入并启用 LX 音源"
        }
    }

    enum Stage: String, CaseIterable {
        case resolution = "音源解析"
        case transfer = "直链传输"
        case validation = "文件核验"
    }

    var stage: Stage {
        switch self {
        case .transfer: return .transfer
        case .validation: return .validation
        default: return .resolution
        }
    }
}

struct ExhaustedDownloadCandidates: LocalizedError {
    let failures: [DownloadAttemptFailure]

    var errorDescription: String? {
        let details = DownloadAttemptFailure.Stage.allCases.compactMap { stage -> String? in
            var seen = Set<String>()
            let reasons = failures.filter { $0.stage == stage }
                .map(\.localizedDescription).filter { seen.insert($0).inserted }
            guard !reasons.isEmpty else { return nil }
            return "\(stage.rawValue)：\(reasons.joined(separator: "、"))"
        }
        return (["已尝试所有可用音源"] + details).joined(separator: "\n")
    }
}
#endif
