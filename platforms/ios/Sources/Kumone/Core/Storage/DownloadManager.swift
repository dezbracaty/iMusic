#if os(iOS)
import AVFoundation
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class DownloadManager {
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let track: Track
        let quality: String
        let qualityVerified: Bool?
        let fileName: String
        let createdAt: Date
        var publicFileName: String?
        var sourceID: String?
        var preferredSourceID: String?
        var sourceName: String?
        var sourcePlatform: String?
        var requestToken: String?
        var audio: DownloadAudioQuality?

        var sourceLabel: String? {
            guard let sourceName, let sourcePlatform else { return nil }
            return "\(LXCatalogPlatform.displayName(for: sourcePlatform)) · \(sourceName)"
        }

        var qualityLabel: String {
            if quality == AudioQuality.master.lxType, let audio {
                return "音源标称母带（身份未核验） · 实际 \(audio.specificationLabel)"
            }
            if let audio { return "实际 \(audio.label)" }
            let tier = AudioQuality(lxType: quality)?.downloadLabel ?? quality
            return qualityVerified == true ? "已确认 \(tier)" : "旧版请求 \(tier) · 实际音质未知"
        }
    }

    struct ActiveDownload: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        var fraction: Double?
        var candidateLabel: String?
    }

    struct Failure: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        let message: String
    }

    static let shared = DownloadManager(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true),
        musicDirectory: URL.documentsDirectory.appendingPathComponent("Music", isDirectory: true),
        findDownload: { try await LXUserAPIService.shared.findDownload(for: $0, quality: $1, verify: $2) },
        sourceRevision: { LXSourceStore.shared.configurationRevision },
        selectedSourceID: { LXSourceStore.shared.selectedID },
        notify: { ToastCenter.shared.show($0) }
    )
    private static let logger = Logger(subsystem: "com.jiajia2222.imusic.ios", category: "Downloads")

    private(set) var records: [Record] = []
    private(set) var activeDownloads: [String: ActiveDownload] = [:]
    private(set) var failures: [String: Failure] = [:]
    private(set) var storageError: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var session: URLSession?
    private let findDownload: FindDownload
    private let sourceRevision: @MainActor () -> Int
    private let selectedSourceID: @MainActor () -> String?
    @ObservationIgnored private var needsReload = false
    private let notify: @MainActor (String) -> Void
    private let reportTransfer: @Sendable (DownloadTransferReport) -> Void

    private let manifestURL: URL
    private let downloadDirectory: URL
    private let stagingDirectory: URL
    private let musicDirectory: URL

    init(directory: URL,
         musicDirectory: URL? = nil,
         findDownload: @escaping FindDownload,
         sourceRevision: @escaping @MainActor () -> Int = { 0 },
         selectedSourceID: @escaping @MainActor () -> String? = { nil },
         notify: @escaping @MainActor (String) -> Void = { _ in },
         reportTransfer: @escaping @Sendable (DownloadTransferReport) -> Void = { _ in }) {
        self.findDownload = findDownload
        self.sourceRevision = sourceRevision
        self.selectedSourceID = selectedSourceID
        self.notify = notify
        self.reportTransfer = reportTransfer
        self.musicDirectory = musicDirectory ?? directory.appendingPathComponent("Documents/Music", isDirectory: true)
        manifestURL = directory.appendingPathComponent("downloads.json")
        downloadDirectory = directory.appendingPathComponent("Downloads", isDirectory: true)
        stagingDirectory = downloadDirectory.appendingPathComponent(".staging", isDirectory: true)
        reload()
    }

    deinit { session?.invalidateAndCancel() }

    static func key(for track: Track) -> String {
        track.normalizedForLXPlayback().playbackKey
    }

    static func permitsDownload(of track: Track) -> Bool {
        track.fee == 0 && (track.embeddedPrivilege?.fee ?? 0) == 0
            && (track.embeddedPrivilege?.st ?? 0) >= 0
            && !track.noCopyright && !track.isCloud
    }

    func record(for track: Track) -> Record? {
        let key = Self.key(for: track)
        return records.first { $0.id == key && (try? existingFile(for: $0)) != nil }
    }

    func fileURL(for record: Record) -> URL {
        (try? existingFile(for: record)) ?? privateFile(for: record)
    }

    func alreadyDownloaded(_ track: Track, quality: AudioQuality) -> Bool {
        guard let record = record(for: track), record.quality == quality.lxType,
              (record.preferredSourceID ?? record.sourceID) == selectedSourceID() else { return false }
        if quality == .master {
            return record.sourcePlatform == DownloadMasterRule.platform
                && record.requestToken.map(DownloadMasterRule.requestKeys.contains) == true
                && record.audio?.matchesFileSpecifications(for: .master) == true
        }
        return record.qualityVerified == true
    }

    @discardableResult
    func retry(_ failure: Failure, quality: AudioQuality? = nil) -> Task<Void, Never>? {
        guard failures[failure.id]?.requestedQuality == failure.requestedQuality else { return nil }
        return download(failure.track, quality: quality ?? failure.requestedQuality)
    }

    func alternativeQualities(for failure: Failure) -> [AudioQuality] {
        AudioQuality.downloadOptions.filter {
            $0.lxType != failure.requestedQuality.lxType && !alreadyDownloaded(failure.track, quality: $0)
        }
    }

    static func localAsset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
        ])
    }

    @discardableResult
    func download(_ track: Track, quality: AudioQuality? = nil) -> Task<Void, Never>? {
        let track = track.normalizedForLXPlayback()
        let key = track.playbackKey
        guard tasks[key] == nil else { return nil }
        guard Self.permitsDownload(of: track) else {
            notify(DownloadError.restricted.localizedDescription)
            return nil
        }
        guard storageError == nil else {
            notify(DownloadError.storage.localizedDescription)
            return nil
        }

        let requestedQuality = quality ?? SettingsManager.shared.audioQuality
        guard !alreadyDownloaded(track, quality: requestedQuality) else { return nil }
        guard requestedQuality.canAttemptDownload else {
            reportFailure(for: track, quality: requestedQuality,
                          message: DownloadQualityError.unsupportedVerification.localizedDescription)
            return nil
        }
        let revision = sourceRevision()
        let sourceID = selectedSourceID()
        failures[key] = nil
        activeDownloads[key] = ActiveDownload(id: key, track: track, requestedQuality: requestedQuality)
        notify("正在下载《\(track.name)》")
        let task = Task {
            defer {
                activeDownloads[key] = nil
                tasks[key] = nil
                if tasks.isEmpty, needsReload { reload() }
            }
            do {
                try Task.checkCancellation()
                guard sourceRevision() == revision else { throw DownloadError.sourceChanged }
                let allowance = DownloadUnverifiedAllowance()
                let verified = try await findDownload(track, requestedQuality) { candidate in
                    try checkRevision(revision)
                    return try await verify(candidate, for: track, quality: requestedQuality, key: key,
                                            allowance: allowance)
                }
                let staged = verified.file
                defer { try? FileManager.default.removeItem(at: staged) }
                try checkRevision(revision)
                let fileName = "offline-\(UUID().uuidString).\(staged.pathExtension)"
                var item = Record(id: key, track: track, quality: requestedQuality.lxType,
                                  qualityVerified: requestedQuality != .master, fileName: fileName, createdAt: Date())
                item.preferredSourceID = sourceID
                item.sourceID = verified.candidate.sourceID
                item.sourceName = verified.candidate.sourceName
                item.sourcePlatform = SearchRecordingGroups.source(of: verified.candidate.track)
                item.requestToken = verified.candidate.requestToken
                item.audio = verified.audio
                item.publicFileName = try availableName(for: item)

                try install(item, from: staged)
                relocatePrivateFiles()
                if storageError == nil {
                    notify("已下载《\(track.name)》 · \(item.qualityLabel)")
                } else {
                    notify("已保存在应用内，暂时无法移至文件 App")
                }
            } catch {
                guard !Task.isCancelled else { return }
                reportFailure(for: track, quality: requestedQuality, message: Self.message(for: error))
            }
        }
        tasks[key] = task
        return task
    }

    private func reportFailure(for track: Track, quality: AudioQuality, message: String) {
        let key = Self.key(for: track)
        failures[key] = Failure(id: key, track: track, requestedQuality: quality, message: message)
        // The failure row carries the complete, stage-by-stage summary.
        let summary = message.components(separatedBy: .newlines).first ?? message
        notify("《\(track.name)》下载失败：\(summary)")
    }

    private func checkRevision(_ revision: Int) throws {
        try Task.checkCancellation()
        guard sourceRevision() == revision else { throw DownloadError.sourceChanged }
    }

    private func verify(_ candidate: DownloadCandidate, for track: Track, quality: AudioQuality,
                        key: String, allowance: DownloadUnverifiedAllowance) async throws -> VerifiedDownload {
        let platform = SearchRecordingGroups.source(of: candidate.track)
        if quality == .master {
            guard platform == DownloadMasterRule.platform,
                  candidate.requestToken.map(DownloadMasterRule.requestKeys.contains) == true else {
                throw DownloadAttemptFailure.masterRuleUnavailable
            }
        }
        if var active = activeDownloads[key] {
            active.fraction = nil
            active.candidateLabel = candidate.sourceName.map {
                "\(LXCatalogPlatform.displayName(for: platform)) · \($0)"
            }
            activeDownloads[key] = active
        }
        var staged: URL?
        do {
            let file = try await transfer(from: candidate.url, quality: quality, key: key,
                                          allowance: allowance)
            staged = file
            let crossCatalogue = platform != SearchRecordingGroups.source(of: track)
            try await Self.validateAudio(at: file, expectedDuration: candidate.track.duration,
                                         originalDuration: crossCatalogue ? track.duration : nil)
            try Task.checkCancellation()
            let audio = DownloadAudioQuality.inspect(file)
            guard let audio, audio.canCompare(to: quality) else {
                if quality == .master {
                    throw DownloadQualityError.masterSpecificationsUnverifiable(audio?.specificationLabel)
                }
                throw DownloadQualityError.unverifiable(audio?.label)
            }
            guard audio.matchesFileSpecifications(for: quality) else {
                if quality == .master { throw DownloadQualityError.masterSpecificationsMismatch(audio.specificationLabel) }
                throw DownloadQualityError.mismatch(audio.label)
            }
            return VerifiedDownload(candidate: candidate, file: file, audio: audio)
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            try Task.checkCancellation()
            if let failure = error as? DownloadError, !failure.isLocalStorageFailure {
                if staged != nil || failure == .invalidAudio || failure == .probeBudget {
                    throw DownloadAttemptFailure.validation(failure.localizedDescription)
                }
                throw DownloadAttemptFailure.transfer(failure.localizedDescription)
            }
            if let failure = error as? DownloadQualityError {
                throw DownloadAttemptFailure.validation(failure.localizedDescription)
            }
            if let failure = error as? URLError, !Self.isLocalFileFailure(failure) {
                if failure.code == .userAuthenticationRequired || failure.code == .userCancelledAuthentication {
                    throw DownloadAttemptFailure.transfer(DownloadError.unauthorized.localizedDescription)
                }
                if Self.isTLSFailure(failure) {
                    throw DownloadAttemptFailure.transfer("HTTPS 连接或证书校验失败")
                }
                throw DownloadAttemptFailure.transfer("下载连接失败或超时")
            }
            throw error
        }
    }

    private static func isTLSFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    private static func isLocalFileFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile, .cannotRemoveFile, .cannotMoveFile:
            return true
        default: return false
        }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func dismissFailure(_ id: String) { failures[id] = nil }

    func delete(_ record: Record) {
        guard records.contains(where: { $0.id == record.id && $0.fileName == record.fileName }) else { return }
        do {
            try commit(records.filter { $0.id != record.id }, replacing: record)
            notify("已删除离线下载")
        } catch {
            Self.logger.error("Download removal failed: \(error.localizedDescription, privacy: .private)")
            notify("无法删除离线下载，请重试")
        }
    }

    func reload() {
        guard tasks.isEmpty else {
            needsReload = true
            return
        }
        needsReload = false
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let stored: [Record]
            do {
                stored = try JSONDecoder().decode([Record].self, from: Data(contentsOf: manifestURL))
            } catch CocoaError.fileReadNoSuchFile {
                stored = []
            }
            // Recover interrupted removals before checking for files deleted
            // in Files. Only the app's private directory is swept.
            var ids = Set<String>()
            var visible: [Record] = []
            for record in stored {
                guard Self.isLocalName(record.fileName), ids.insert(record.id).inserted else { continue }
                try restoreDeletion(for: record, publicCopy: false)
                try restoreDeletion(for: record, publicCopy: true)
                if try existingFile(for: record) != nil { visible.append(record) }
            }
            if visible != stored { try save(visible) }
            else { records = visible }
            let storedNames = Set(visible.map(\.fileName))
            for url in try manager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: nil)
                where Self.isManagedFile(url) && !storedNames.contains(url.lastPathComponent) {
                try manager.removeItem(at: url)
            }
            for url in try manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: url)
            }
            relocatePrivateFiles()
        } catch {
            reportStorageError(error)
        }
    }

    private func install(_ record: Record, from staged: URL) throws {
        let manager = FileManager.default
        let ready = privateFile(for: record)
        try manager.moveItem(at: staged, to: ready)
        do {
            try commit([record] + records.filter { $0.id != record.id },
                       replacing: records.first { $0.id == record.id })
        } catch {
            try? manager.removeItem(at: ready)
            throw error
        }
    }

    private func commit(_ next: [Record], replacing record: Record?) throws {
        let manager = FileManager.default
        guard let record, let old = try existingFile(for: record) else {
            try save(next)
            return
        }
        let staged = stagedDeletion(for: record, publicCopy: old == publicFile(for: record))
        try manager.moveItem(at: old, to: staged)
        do {
            try save(next)
        } catch {
            try manager.moveItem(at: staged, to: old)
            throw error
        }
        // A crash after committing the manifest leaves private trash, which
        // reload safely removes because the old fileName is unreferenced.
        try? manager.removeItem(at: staged)
    }

    private func relocatePrivateFiles() {
        do {
            try prepareMusicDirectory()
            var pending = records
            var moves: [(from: URL, to: URL)] = []
            for index in pending.indices {
                let source = privateFile(for: pending[index])
                guard try Self.isRegularFile(source),
                      try Self.hasAudioFileHeader(at: source) else { continue }
                if pending[index].audio == nil { pending[index].audio = DownloadAudioQuality.inspect(source) }
                if let target = publicFile(for: pending[index]), try !Self.itemExists(target) {
                    moves.append((source, target))
                } else {
                    let name = try availableName(for: pending[index])
                    pending[index].publicFileName = name
                    moves.append((source, musicDirectory.appendingPathComponent(name)))
                }
            }
            // Reserve the destination in the private manifest first. If
            // interrupted, the complete private copy stays playable and
            // reload can retry the same move without creating a second copy.
            if pending != records { try save(pending) }
            for move in moves { try FileManager.default.moveItem(at: move.from, to: move.to) }
            storageError = nil
        } catch {
            reportStorageError(error)
        }
    }

    private func prepareMusicDirectory() throws {
        try FileManager.default.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        let values = try musicDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DownloadError.storage }
    }

    private func availableName(for record: Record) throws -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let title = record.track.name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        let stem = title.isEmpty ? "Music" : String(decoding: title.utf8.prefix(144), as: UTF8.self)
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        while true {
            let name = "\(stem) [\(UUID().uuidString.prefix(12))].\(ext)"
            if try !Self.itemExists(musicDirectory.appendingPathComponent(name)) { return name }
        }
    }

    private func existingFile(for record: Record) throws -> URL? {
        let privateURL = privateFile(for: record)
        if try Self.isRegularFile(privateURL) { return privateURL }
        guard let publicURL = publicFile(for: record) else { return nil }
        guard try Self.itemExists(musicDirectory) else { return nil }
        let values = try musicDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DownloadError.storage }
        return try Self.isRegularFile(publicURL) ? publicURL : nil
    }

    private func privateFile(for record: Record) -> URL {
        downloadDirectory.appendingPathComponent(record.fileName)
    }

    private func publicFile(for record: Record) -> URL? {
        guard let name = record.publicFileName, Self.isLocalName(name) else { return nil }
        return musicDirectory.appendingPathComponent(name)
    }

    private func restoreDeletion(for record: Record, publicCopy: Bool) throws {
        let staged = stagedDeletion(for: record, publicCopy: publicCopy)
        guard try Self.isRegularFile(staged) else { return }
        let destination: URL
        if publicCopy {
            guard let publicURL = publicFile(for: record) else { throw DownloadError.storage }
            try prepareMusicDirectory()
            destination = publicURL
        } else {
            destination = privateFile(for: record)
        }
        // Preserve both files if the original name was claimed externally.
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    private func stagedDeletion(for record: Record, publicCopy: Bool) -> URL {
        let prefix = publicCopy ? "removed-from-music-" : "deleted-"
        return stagingDirectory.appendingPathComponent(prefix + record.fileName)
    }

    private func save(_ next: [Record]) throws {
        try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
        records = next
    }

    private func reportStorageError(_ error: Error) {
        Self.logger.error("Download library storage failed: \(error.localizedDescription, privacy: .private)")
        storageError = DownloadError.storage.localizedDescription
    }

    private static func isLocalName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil
    }

    private static func itemExists(_ url: URL) throws -> Bool {
        try fileValues(url) != nil
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        guard let values = try fileValues(url) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func fileValues(_ url: URL) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
    }

    private static func isManagedFile(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "offline-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? DownloadError { return error.localizedDescription }
        if let error = error as? DownloadQualityError { return error.localizedDescription }
        if let error = error as? DownloadAttemptFailure { return error.localizedDescription }
        if let error = error as? ExhaustedDownloadCandidates { return error.localizedDescription }
        if error is LXUserAPIService.LXError || error is LXCatalogError {
            return PlaybackFailureMessage.source(error)
        }
        if error is CancellationError { return DownloadError.sourceChanged.localizedDescription }
        if let error = error as? URLError, !isLocalFileFailure(error) {
            return "网络传输失败，请检查连接后重试"
        }
        logger.error("Download failed: \(error.localizedDescription, privacy: .private)")
        return DownloadError.storage.localizedDescription
    }

    private static func validateAudio(at url: URL, expectedDuration: TimeInterval, originalDuration: TimeInterval?) async throws {
        guard try Self.hasAudioFileHeader(at: url) else { throw DownloadError.invalidAudio }
        let asset = localAsset(at: url)
        do {
            let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
            guard !protected else { throw DownloadError.protectedAudio }
            guard playable, duration.seconds.isFinite, duration.seconds > 0,
                  try await asset.loadTracks(withMediaType: .audio).count == 1,
                  try await asset.loadTracks(withMediaType: .video).isEmpty else {
                throw DownloadError.invalidAudio
            }
            // Preview files can otherwise look like complete, playable audio.
            let tolerance = min(10, max(2, expectedDuration * 0.05))
            if expectedDuration > 0, duration.seconds < expectedDuration - tolerance {
                throw DownloadError.incompleteAudio
            }
            if let originalDuration {
                guard abs(duration.seconds - expectedDuration) <= 2,
                      abs(duration.seconds - originalDuration) <= 2 else {
                    throw DownloadError.recordingDurationMismatch
                }
            } else if expectedDuration > 0, duration.seconds > expectedDuration + tolerance {
                throw DownloadError.recordingDurationMismatch
            }
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.invalidAudio
        }
    }

    /// Check the container before handing an untrusted response to AVFoundation.
    /// A mislabeled playlist must never cause the local asset to fetch segments.
    private static func hasAudioFileHeader(at url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = [UInt8](try file.read(upToCount: 12) ?? Data())
        guard header.count == 12 else { return false }
        func matches(_ text: String, at offset: Int = 0) -> Bool {
            header.dropFirst(offset).starts(with: text.utf8)
        }
        switch url.pathExtension.lowercased() {
        case "wav": return (matches("RIFF") || matches("RF64")) && matches("WAVE", at: 8)
        case "aif", "aiff", "aifc": return matches("FORM") && (matches("AIFF", at: 8) || matches("AIFC", at: 8))
        case "caf": return matches("caff")
        case "flac": return matches("fLaC") || matches("ID3")
        case "m4a": return matches("ftyp", at: 4)
        case "aac", "mp3": return matches("ID3") || (header[0] == 0xff && header[1] & 0xe0 == 0xe0)
        case "ogg", "opus": return matches("OggS")
        default: return false
        }
    }

    private func transfer(from url: URL, quality: AudioQuality, key: String,
                          allowance: DownloadUnverifiedAllowance) async throws -> URL {
        let current = session ?? DownloadStream.makeSession()
        session = current
        return try await DownloadStream.fetch(url, quality: quality, session: current, stagingDirectory: stagingDirectory,
                                              allowance: allowance, progress: { fraction in
            guard var item = self.activeDownloads[key] else { return }
            item.fraction = fraction
            self.activeDownloads[key] = item
        }, report: reportTransfer)
    }
}

enum DownloadError: LocalizedError, Equatable {
    case restricted, unsafeURL, unauthorized, saveProhibited, invalidAudio, incompleteAudio
    case tooLarge, http(Int), storage, sourceChanged, protectedAudio, recordingDurationMismatch, probeBudget

    var isLocalStorageFailure: Bool {
        switch self {
        case .storage, .sourceChanged: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .restricted: return "此歌曲受版权、付费或账号限制"
        case .unsafeURL: return "需要 HTTPS 直链，且跳转不能降为不安全地址"
        case .unauthorized: return "服务器拒绝访问或要求身份验证"
        case .saveProhibited: return "服务器明确限制保存此文件"
        case .invalidAudio: return "文件无法作为无 DRM 音频播放"
        case .protectedAudio: return "音频文件受 DRM 保护"
        case .recordingDurationMismatch: return "返回的音频时长与匹配录音不符"
        case .incompleteAudio: return "音频不完整或仅提供试听"
        case .tooLarge: return "音频超过 250 MB 的下载上限"
        case .probeBudget: return "探测无法确认音质，本次已尝试过一个需要整文件核验的候选"
        case .http(let status): return "服务器返回 HTTP \(status)"
        case .storage: return "无法访问下载存储，请检查设备空间后重试"
        case .sourceChanged: return "音源配置已更改，请重试"
        }
    }
}

#endif
