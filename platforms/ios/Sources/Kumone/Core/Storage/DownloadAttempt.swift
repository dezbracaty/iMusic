#if os(iOS)
import Foundation

struct DownloadCandidate {
    let url: URL
    let track: Track
    let sourceID: String?
    var sourceName: String?
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
    case media(String)
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
        case .media(let reason): return reason
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

    var isMediaFailure: Bool {
        if case .media = self { return true }
        return false
    }
}

struct ExhaustedDownloadCandidates: LocalizedError {
    let failures: [DownloadAttemptFailure]

    var errorDescription: String? {
        let ordered = failures.filter(\.isMediaFailure) + failures.filter { !$0.isMediaFailure }
        var seen = Set<String>()
        let reasons = ordered.map(\.localizedDescription).filter { seen.insert($0).inserted }
        return "已尝试所有可用音源。\(reasons.joined(separator: "；"))"
    }
}
#endif
