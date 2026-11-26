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
    }

    struct ActiveDownload: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        var fraction: Double?
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
        resolve: { try await LXUserAPIService.shared.resolveDownloadMusicURL(for: $0, quality: $1) },
        sourceRevision: { LXSourceStore.shared.configurationRevision },
        notify: { ToastCenter.shared.show($0) }
    )
    private static let logger = Logger(subsystem: "com.jiajia2222.imusic.ios", category: "Downloads")

    private(set) var records: [Record] = []
    private(set) var activeDownloads: [String: ActiveDownload] = [:]
    private(set) var failures: [String: Failure] = [:]
    private(set) var storageError: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var transfers: [Int: Transfer] = [:]
    @ObservationIgnored private var session: URLSession?
    private let resolve: @MainActor (Track, String) async throws -> LXUserAPIService.ResolvedURL
    private let sourceRevision: @MainActor () -> Int
    private let notify: @MainActor (String) -> Void

    private let manifestURL: URL
    private let downloadDirectory: URL
    private let stagingDirectory: URL

    private struct Transfer {
        let key: String
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<URL, Error>
    }

    init(directory: URL,
         resolve: @escaping @MainActor (Track, String) async throws -> LXUserAPIService.ResolvedURL,
         sourceRevision: @escaping @MainActor () -> Int = { 0 },
         notify: @escaping @MainActor (String) -> Void = { _ in }) {
        self.resolve = resolve
        self.sourceRevision = sourceRevision
        self.notify = notify
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
        guard let record = records.first(where: { $0.id == key }),
              FileManager.default.fileExists(atPath: fileURL(for: record).path) else { return nil }
        return record
    }

    func fileURL(for record: Record) -> URL {
        downloadDirectory.appendingPathComponent(record.fileName)
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
        guard tasks[key] == nil, record(for: track) == nil else { return nil }
        guard Self.permitsDownload(of: track) else {
            notify(DownloadError.restricted.localizedDescription)
            return nil
        }
        guard storageError == nil else {
            notify(DownloadError.storage.localizedDescription)
            return nil
        }

        let requestedQuality = quality ?? SettingsManager.shared.audioQuality
        let revision = sourceRevision()
        failures[key] = nil
        activeDownloads[key] = ActiveDownload(id: key, track: track, requestedQuality: requestedQuality)
        notify("正在下载《\(track.name)》")
        let task = Task {
            defer {
                activeDownloads[key] = nil
                tasks[key] = nil
            }
            do {
                try Task.checkCancellation()
                guard sourceRevision() == revision else { throw DownloadError.sourceChanged }
                let resolved = try await resolve(track, requestedQuality.rawValue)
                try Task.checkCancellation()
                guard sourceRevision() == revision else { throw DownloadError.sourceChanged }
                let staged = try await transfer(from: resolved.url, key: key)
                defer { try? FileManager.default.removeItem(at: staged) }
                try await Self.validateAudio(at: staged, expectedDuration: track.duration)
                try Task.checkCancellation()
                guard sourceRevision() == revision else { throw DownloadError.sourceChanged }

                let fileName = "offline-\(UUID().uuidString).\(staged.pathExtension)"
                let item = Record(id: key, track: track, quality: resolved.quality,
                                  qualityVerified: resolved.qualityIsVerified,
                                  fileName: fileName, createdAt: Date())
                let destination = fileURL(for: item)
                try FileManager.default.moveItem(at: staged, to: destination)
                do {
                    try save([item] + records.filter { $0.id != key })
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                notify("已下载《\(track.name)》")
            } catch {
                guard !Task.isCancelled else { return }
                let message = Self.message(for: error)
                failures[key] = Failure(id: key, track: track, requestedQuality: requestedQuality, message: message)
                notify("《\(track.name)》下载失败：\(message)")
            }
        }
        tasks[key] = task
        return task
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func dismissFailure(_ id: String) { failures[id] = nil }

    func delete(_ record: Record) {
        // A menu may still refer to a record that was deleted and replaced.
        guard records.contains(where: { $0.id == record.id && $0.fileName == record.fileName }) else { return }
        let file = fileURL(for: record)
        let staged = stagedDeletion(for: record)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: file.path) {
                try manager.moveItem(at: file, to: staged)
            }
            do {
                try save(records.filter { $0.id != record.id })
            } catch {
                if manager.fileExists(atPath: staged.path) {
                    try manager.moveItem(at: staged, to: file)
                }
                throw error
            }
            try manager.removeItemIfPresent(at: staged)
            notify("已删除离线下载")
        } catch {
            Self.logger.error("Download removal failed: \(error.localizedDescription, privacy: .private)")
            notify("无法删除离线下载，请重试")
        }
    }

    func reload() {
        guard tasks.isEmpty else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let stored: [Record]
            do {
                stored = try JSONDecoder().decode([Record].self, from: Data(contentsOf: manifestURL))
            } catch CocoaError.fileReadNoSuchFile {
                stored = []
            }
            var ids = Set<String>()
            var visible: [Record] = []
            for record in stored {
                guard Self.isLocalName(record.fileName) else { continue }
                let file = fileURL(for: record)
                let staged = stagedDeletion(for: record)
                if manager.fileExists(atPath: staged.path), !manager.fileExists(atPath: file.path) {
                    try manager.moveItem(at: staged, to: file)
                }
                if manager.fileExists(atPath: file.path), ids.insert(record.id).inserted {
                    visible.append(record)
                }
            }
            // A crash before the atomic manifest write can leave a new final
            // file unreferenced. Legacy filenames are kept and never swept.
            let storedNames = Set(stored.map(\.fileName))
            for url in try manager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: nil)
                where Self.isManagedFile(url) && !storedNames.contains(url.lastPathComponent) {
                try manager.removeItem(at: url)
            }
            for url in try manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: url)
            }
            records = visible
            storageError = nil
        } catch {
            Self.logger.error("Download library load failed: \(error.localizedDescription, privacy: .private)")
            storageError = DownloadError.storage.localizedDescription
        }
    }

    private func save(_ next: [Record]) throws {
        try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
        records = next
    }

    private func stagedDeletion(for record: Record) -> URL {
        stagingDirectory.appendingPathComponent("deleted-\(record.fileName)")
    }

    private static func isLocalName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func isManagedFile(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "offline-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? DownloadError { return error.localizedDescription }
        if error is LXUserAPIService.LXError || error is LXCatalogError {
            return PlaybackFailureMessage.source(error)
        }
        if error is CancellationError { return DownloadError.sourceChanged.localizedDescription }
        if error is URLError { return "网络传输失败，请检查连接后重试" }
        logger.error("Download failed: \(error.localizedDescription, privacy: .private)")
        return DownloadError.storage.localizedDescription
    }

    private static func validateAudio(at url: URL, expectedDuration: TimeInterval) async throws {
        guard try Self.hasAudioFileHeader(at: url) else { throw DownloadError.invalidAudio }
        let asset = localAsset(at: url)
        do {
            let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
            guard playable, !protected, duration.seconds.isFinite, duration.seconds > 0,
                  try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                  try await asset.loadTracks(withMediaType: .video).isEmpty else {
                throw DownloadError.invalidAudio
            }
            // Preview files can otherwise look like complete, playable audio.
            let tolerance = min(10, max(2, expectedDuration * 0.05))
            if expectedDuration > 0, duration.seconds < expectedDuration - tolerance {
                throw DownloadError.incompleteAudio
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
        switch url.pathExtension {
        case "wav": return (matches("RIFF") || matches("RF64")) && matches("WAVE", at: 8)
        case "aif", "aiff": return matches("FORM") && (matches("AIFF", at: 8) || matches("AIFC", at: 8))
        case "caf": return matches("caff")
        case "flac": return matches("fLaC") || matches("ID3")
        case "m4a": return matches("ftyp", at: 4)
        case "aac", "mp3": return matches("ID3") || (header[0] == 0xff && header[1] & 0xe0 == 0xe0)
        default: return false
        }
    }

    private func transfer(from url: URL, key: String) async throws -> URL {
        guard DownloadSessionDelegate.permits(url) else { throw DownloadError.unsafeURL }
        let session: URLSession
        if let current = self.session {
            session = current
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 15 * 60
            session = URLSession(configuration: configuration,
                                 delegate: DownloadSessionDelegate(owner: self, stagingDirectory: stagingDirectory),
                                 delegateQueue: nil)
            self.session = session
        }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfers[task.taskIdentifier] = Transfer(key: key, task: task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    fileprivate func updateProgress(taskID: Int, fraction: Double) {
        guard let key = transfers[taskID]?.key, var item = activeDownloads[key],
              fraction > (item.fraction ?? 0) else { return }
        item.fraction = fraction
        activeDownloads[key] = item
    }

    fileprivate func finishTransfer(taskID: Int, result: Result<URL, Error>) {
        guard let transfer = transfers.removeValue(forKey: taskID) else {
            if let url = try? result.get() { try? FileManager.default.removeItem(at: url) }
            return
        }
        if case .failure = result { transfer.task.cancel() }
        transfer.continuation.resume(with: result)
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        do { try removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }
}

private enum DownloadError: LocalizedError {
    case restricted, unsafeURL, unauthorized, notOffered, invalidAudio, incompleteAudio
    case tooLarge, http(Int), storage, sourceChanged

    var errorDescription: String? {
        switch self {
        case .restricted: return "此歌曲受版权、付费或账号限制"
        case .unsafeURL: return "音源未提供安全的下载地址"
        case .unauthorized: return "服务器拒绝访问或要求身份验证"
        case .notOffered: return "音源未将此音频提供为下载文件"
        case .invalidAudio: return "文件无法作为无 DRM 音频播放"
        case .incompleteAudio: return "音频不完整或仅提供试听"
        case .tooLarge: return "音频超过 250 MB 的下载上限"
        case .http(let status): return "服务器返回 HTTP \(status)"
        case .storage: return "无法访问下载存储，请检查设备空间后重试"
        case .sourceChanged: return "音源配置已更改，请重试"
        }
    }
}

private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var owner: DownloadManager?
    private let stagingDirectory: URL
    private static let maximumBytes: Int64 = 250_000_000

    init(owner: DownloadManager, stagingDirectory: URL) {
        self.owner = owner
        self.stagingDirectory = stagingDirectory
    }

    static func permits(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.permits(url),
              response.url?.scheme != "https" || url.scheme == "https" else {
            finish(task, with: .failure(DownloadError.unsafeURL))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            finish(task, with: .failure(DownloadError.unauthorized))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            _ = try Self.fileExtension(response: downloadTask.response, bytes: totalBytesWritten)
        } catch {
            finish(downloadTask, with: .failure(error))
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(100, floor(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)) / 100
        Task { @MainActor [weak owner] in
            owner?.updateProgress(taskID: downloadTask.taskIdentifier, fraction: fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let ext = try Self.fileExtension(response: downloadTask.response, bytes: Int64(size))
            guard size > 0 else { throw DownloadError.invalidAudio }
            let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            // URLSession removes its temporary file when this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            finish(downloadTask, with: .success(destination))
        } catch {
            finish(downloadTask, with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, with: .failure(error)) }
    }

    private func finish(_ task: URLSessionTask, with result: Result<URL, Error>) {
        Task { @MainActor [weak owner] in
            if let owner {
                owner.finishTransfer(taskID: task.taskIdentifier, result: result)
            } else if let url = try? result.get() {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func fileExtension(response: URLResponse?, bytes: Int64) throws -> String {
        guard let response = response as? HTTPURLResponse else { throw DownloadError.invalidAudio }
        guard let url = response.url, permits(url) else { throw DownloadError.unsafeURL }
        switch response.statusCode {
        case 200: break
        case 401, 403, 407: throw DownloadError.unauthorized
        case 206: throw DownloadError.incompleteAudio
        default: throw DownloadError.http(response.statusCode)
        }
        guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw DownloadError.incompleteAudio
        }
        // LX musicUrl grants a playback URL. Require the HTTP server to
        // explicitly offer a file download before saving that URL offline.
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespaces)
        guard disposition?.lowercased() == "attachment" else { throw DownloadError.notOffered }
        guard bytes <= maximumBytes, response.expectedContentLength <= maximumBytes else {
            throw DownloadError.tooLarge
        }
        switch response.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/wave", "audio/x-wav", "audio/vnd.wave": return "wav"
        case "audio/aac", "audio/aacp", "audio/x-aac": return "aac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "application/octet-stream", nil:
            let ext = (response.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "").lowercased()
            let fallback = url.pathExtension.lowercased()
            let extensions = ["mp3", "m4a", "flac", "wav", "aac", "aif", "aiff", "caf"]
            if extensions.contains(ext) { return ext }
            if extensions.contains(fallback) { return fallback }
            fallthrough
        default: throw DownloadError.invalidAudio
        }
    }
}
#endif
