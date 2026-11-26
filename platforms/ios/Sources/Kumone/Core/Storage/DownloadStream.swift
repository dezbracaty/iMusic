#if os(iOS)
import Foundation
import Synchronization

struct DownloadTransferReport: Sendable {
    var mainBytes = 0
    var rangeBytes = 0
    var rangeRequests = 0
}

@MainActor
final class DownloadUnverifiedAllowance {
    private(set) var isAvailable = true

    func consume() -> Bool {
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }
}

/// Uses a full GET with a bounded prefix first so a passing candidate can
/// continue on the same response. Counts bytes yielded to this client, not
/// bytes already buffered by Foundation or the network stack.
enum DownloadStream {
    static let maximumBytes = 250_000_000
    static let prefixLimit = 128 * 1024
    static let rangeLimit = 256 * 1024
    private static let blockSize = 64 * 1024

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        return URLSession(configuration: configuration)
    }

    static func fetch(
        _ url: URL, quality: AudioQuality, session: URLSession, stagingDirectory: URL,
        allowance: DownloadUnverifiedAllowance, progress: @MainActor @Sendable (Double) -> Void,
        report: @Sendable (DownloadTransferReport) -> Void
    ) async throws -> URL {
        guard permits(url) else { throw DownloadError.unsafeURL }
        var statistics = DownloadTransferReport()
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, rawResponse) = try await requestBytes(request, using: session)
        defer {
            bytes.task.cancel()
            report(statistics)
        }
        let response = try checkedResponse(rawResponse, range: false)
        let hint = try extensionHint(response)
        let expected = response.hasIdentityEncoding ? Int(response.expectedContentLength) : -1
        var reader = Reader(iterator: bytes.makeAsyncIterator(), expected: expected)
        var prefix = Data()
        var probe = DownloadMediaProbe(fileExtension: nil)
        var qualified = false
        defer { statistics.mainBytes = reader.count }

        for limit in [42, 4 * 1024, 32 * 1024, prefixLimit] {
            prefix.append(try await reader.read(upTo: limit - prefix.count))
            probe = DownloadMediaProbe.inspect(prefix)
            if probe.fileExtension == nil, isNonAudioText(prefix) {
                throw DownloadError.invalidAudio
            }
            if prefix.count >= 12, probe.fileExtension == nil, hint == nil, !prefix.starts(with: "ID3".utf8) {
                throw DownloadError.invalidAudio
            }
            qualified = try canContinue(probe.audio, quality: quality)
            if qualified || reader.ended || (expected >= 0 && reader.count >= expected) { break }
            if let nextOffset = probe.nextBoxOffset, nextOffset >= prefixLimit { break }
        }
        guard !prefix.isEmpty else { throw DownloadError.invalidAudio }
        let reachedEnd = reader.ended || (expected >= 0 && reader.count == expected)

        if !qualified, !reachedEnd, let nextOffset = probe.nextBoxOffset,
           let ranged = try await fetchMovieMetadata(
               after: nextOffset, original: response, session: session, report: &statistics
           ) {
            qualified = try canContinue(ranged.audio, quality: quality)
        }
        // A large ID3 tag can put the first complete audio frame after the
        // prefix. Keep it eligible for the single compatibility transfer.
        guard hint != nil || probe.fileExtension != nil || prefix.starts(with: "ID3".utf8) else {
            throw DownloadError.invalidAudio
        }
        if !qualified, !reachedEnd, await !allowance.consume() {
            throw DownloadError.probeBudget
        }

        let extensionToUse = hint ?? probe.fileExtension
        var staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(extensionToUse ?? "part")
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else { throw DownloadError.storage }
        do {
            let file = try FileHandle(forWritingTo: staged)
            do {
                try file.write(contentsOf: prefix)
                var percentage = 0
                while !reader.ended, expected < 0 || reader.count < expected {
                    let block = try await reader.read(upTo: min(blockSize, maximumBytes + 1 - reader.count))
                    guard reader.count <= maximumBytes else { throw DownloadError.tooLarge }
                    if expected >= 0, reader.count > expected { throw DownloadError.incompleteAudio }
                    try file.write(contentsOf: block)
                    if expected > 0 {
                        let next = 100 * reader.count / expected
                        if next > percentage {
                            percentage = next
                            await progress(Double(next) / 100)
                        }
                    }
                }
                guard expected < 0 || reader.count == expected else { throw DownloadError.incompleteAudio }
                try file.close()
            } catch {
                try? file.close()
                throw error
            }
            if extensionToUse == nil {
                guard let detected = try detectTaggedExtension(at: staged) else { throw DownloadError.invalidAudio }
                let renamed = staged.deletingPathExtension().appendingPathExtension(detected)
                try FileManager.default.moveItem(at: staged, to: renamed)
                staged = renamed
            }
            try Task.checkCancellation()
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    private static func canContinue(_ audio: DownloadAudioQuality?, quality: AudioQuality) throws -> Bool {
        guard let audio, audio.canCompare(to: quality) else { return false }
        if audio.matches(quality) { return true }
        // An AAC descriptor's bitrate may be nominal rather than the rate
        // reported by the complete audio file. Reject definite format/depth
        // mismatches here and leave ambiguous lossy rates for final validation.
        if audio.codec == "AAC", quality == .standard || quality == .higher || quality == .exhigh {
            return false
        }
        throw DownloadQualityError.mismatch(audio.label)
    }

    private static func fetchMovieMetadata(
        after offset: Int, original: HTTPURLResponse, session: URLSession,
        report: inout DownloadTransferReport
    ) async throws -> DownloadMediaProbe? {
        let total = Int(original.expectedContentLength)
        guard original.hasIdentityEncoding, let tag = original.value(forHTTPHeaderField: "ETag"),
              tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count > 2,
              offset >= 0, total > offset, total - offset <= rangeLimit, let url = original.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("bytes=\(offset)-\(total - 1)", forHTTPHeaderField: "Range")
        request.setValue(tag, forHTTPHeaderField: "If-Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        report.rangeRequests += 1
        do {
            let (bytes, rawResponse) = try await requestBytes(request, using: session)
            defer { bytes.task.cancel() }
            let response = try checkedResponse(rawResponse, range: true)
            // A CDN that ignores Range sends 200. No bytes are iterated from
            // that response, since the original GET can still continue.
            guard response.statusCode == 206, response.url == url, response.hasIdentityEncoding,
                  response.value(forHTTPHeaderField: "ETag") == tag,
                  response.value(forHTTPHeaderField: "Content-Range")?.lowercased() == "bytes \(offset)-\(total - 1)/\(total)",
                  response.expectedContentLength < 0 || Int(response.expectedContentLength) == total - offset else { return nil }
            var reader = Reader(iterator: bytes.makeAsyncIterator(), expected: total - offset)
            defer { report.rangeBytes += reader.count }
            let data = try await reader.read(upTo: total - offset)
            guard data.count == total - offset else { return nil }
            return DownloadMediaProbe.inspectMovie(data, base: offset)
        } catch let error as DownloadError {
            switch error {
            case .unauthorized, .saveProhibited, .unsafeURL: throw error
            default: return nil
            }
        } catch let error as URLError {
            try Task.checkCancellation()
            if error.code == .userAuthenticationRequired || error.code == .userCancelledAuthentication {
                throw DownloadError.unauthorized
            }
            return nil
        }
    }

    private static func requestBytes(_ request: URLRequest, using session: URLSession) async throws
        -> (URLSession.AsyncBytes, URLResponse) {
        let delegate = DownloadHTTPDelegate()
        do {
            return try await session.bytes(for: request, delegate: delegate)
        } catch {
            try Task.checkCancellation()
            if delegate.refusedAuthentication { throw DownloadError.unauthorized }
            throw error
        }
    }

    private static func detectTaggedExtension(at url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let tag = try file.read(upToCount: 10), tag.count == 10, tag.starts(with: "ID3".utf8),
              tag[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
        let size = tag[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        let footer = tag[3] == 4 && tag[5] & 0x10 != 0 ? 10 : 0
        try file.seek(toOffset: UInt64(10 + size + footer))
        return DownloadMediaProbe.inspect(try file.read(upToCount: 42) ?? Data()).fileExtension
    }

    private static func isNonAudioText(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["#extm3u", "#extinf", "[playlist]", "<!doctype", "<html", "<?xml", "<mpd"]
            .contains(where: prefix.hasPrefix)
    }

    fileprivate static func permits(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    fileprivate static func explicitlyDeniesDownload(_ response: HTTPURLResponse) -> Bool {
        let allowed = response.value(forHTTPHeaderField: "X-Download-Allowed")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        let directives = response.value(forHTTPHeaderField: "Cache-Control")?
            .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return allowed.map { ["false", "0", "no"].contains($0) } == true || directives.contains("no-store")
    }

    private static func checkedResponse(_ raw: URLResponse, range: Bool) throws -> HTTPURLResponse {
        guard let response = raw as? HTTPURLResponse else { throw DownloadError.invalidAudio }
        guard let url = response.url, permits(url) else { throw DownloadError.unsafeURL }
        switch response.statusCode {
        case 401, 403, 407: throw DownloadError.unauthorized
        case 451: throw DownloadError.saveProhibited
        default: break
        }
        guard !explicitlyDeniesDownload(response) else {
            throw DownloadError.saveProhibited
        }
        switch response.statusCode {
        case 200: break
        case 206 where range: break
        case 206: throw DownloadError.incompleteAudio
        case 300..<400: throw DownloadError.unsafeURL
        default: throw DownloadError.http(response.statusCode)
        }
        if response.statusCode == 200, response.value(forHTTPHeaderField: "Content-Range") != nil {
            throw DownloadError.incompleteAudio
        }
        guard response.expectedContentLength <= maximumBytes else { throw DownloadError.tooLarge }
        return response
    }

    private static func extensionHint(_ response: HTTPURLResponse) throws -> String? {
        switch response.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3", "audio/x-mpeg", "audio/x-mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/flac", "audio/x-flac", "application/flac": return "flac"
        case "audio/wav", "audio/wave", "audio/x-wav", "audio/vnd.wave": return "wav"
        case "audio/aac", "audio/aacp", "audio/x-aac": return "aac"
        case "audio/aiff", "audio/x-aiff", "audio/aifc", "audio/x-aifc": return "aiff"
        case "audio/caf", "audio/x-caf": return "caf"
        case "application/octet-stream", "application/download", "application/x-download", nil:
            let name = response.suggestedFilename.map { ($0 as NSString).pathExtension.lowercased() }
            let extensions = ["mp3", "m4a", "mp4", "flac", "wav", "aac", "aif", "aiff", "aifc", "caf"]
            guard let ext = [name, response.url?.pathExtension.lowercased()].compactMap({ $0 })
                .first(where: extensions.contains) else { return nil }
            return ext == "mp4" ? "m4a" : ext
        default: throw DownloadError.invalidAudio
        }
    }

    private struct Reader {
        var iterator: URLSession.AsyncBytes.AsyncIterator
        let expected: Int
        var count = 0
        var ended = false

        mutating func read(upTo limit: Int) async throws -> Data {
            try Task.checkCancellation()
            var result = Data()
            result.reserveCapacity(limit)
            do {
                while result.count < limit {
                    guard let byte = try await iterator.next() else {
                        ended = true
                        break
                    }
                    result.append(byte)
                    count += 1
                }
            } catch let error as URLError where error.code == .networkConnectionLost && count < expected {
                throw DownloadError.incompleteAudio
            }
            return result
        }
    }
}

private extension HTTPURLResponse {
    var hasIdentityEncoding: Bool {
        let encoding = value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        return encoding == nil || encoding == "identity"
    }
}

private final class DownloadHTTPDelegate: NSObject, URLSessionTaskDelegate {
    private let authentication = Mutex(false)

    var refusedAuthentication: Bool { authentication.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard !DownloadStream.explicitlyDeniesDownload(response), let url = request.url,
              DownloadStream.permits(url),
              response.url?.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https" else {
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
            authentication.withLock { $0 = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
#endif
