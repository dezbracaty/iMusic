import AVFoundation
import Foundation
import Network
import Testing
@testable import KumoneCore

@MainActor
struct OfflineDownloadTests {
    @Test("A failed LX download retries once, then plays from disk after reopening and deletes")
    func retryPlayAndDelete() async throws {
        let audio = try Self.fixture("tone-128", "m4a")
        let server = try await LocalAudioServer([
            "/song": [Reply(status: 503), Reply(contentType: "audio/mp4", audio: audio)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = Self.track()
        let resolver = Self.resolver(url: server.url("/song"))
        let downloads = DownloadManager(directory: directory, resolve: resolver.resolveDownloadMusicURL)
        let key = DownloadManager.key(for: track)
        let first = try #require(downloads.download(track, quality: .standard))
        #expect(downloads.activeDownloads[key] != nil)
        #expect(downloads.download(track, quality: .standard) == nil)
        await first.value
        #expect(downloads.failures[key]?.message == "服务器返回 HTTP 503")
        #expect(downloads.activeDownloads.isEmpty)
        #expect(downloads.records.isEmpty)
        #expect(try Self.stagedFiles(in: directory).isEmpty)

        let retry = try #require(downloads.download(track, quality: .standard))
        await retry.value
        let record = try #require(downloads.record(for: track))
        #expect(downloads.download(track, quality: .standard) == nil)
        #expect(downloads.failures.isEmpty)
        #expect(record.qualityVerified == true)
        #expect(record.publicFileName != nil)
        #expect(record.audio?.codec == "AAC")
        #expect(downloads.fileURL(for: record).deletingLastPathComponent().lastPathComponent == "Music")
        #expect(record.track.source == "tx")
        #expect(try Data(contentsOf: downloads.fileURL(for: record)) == audio)
        #expect(try Self.stagedFiles(in: directory).isEmpty)

        server.stop()
        let reopened = DownloadManager(directory: directory) { _, _ in
            Issue.record("Reading an offline copy must not resolve a remote URL")
            throw URLError(.notConnectedToInternet)
        }
        let restored = try #require(reopened.record(for: track))
        let file = reopened.fileURL(for: restored)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: DownloadManager.localAsset(at: file)))
        player.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while player.currentTime().seconds < 0.1 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.currentItem?.status == .readyToPlay)
        #expect(player.currentTime().seconds >= 0.1)
        player.pause()
        player.replaceCurrentItem(with: nil)

        reopened.delete(restored)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(reopened.record(for: track) == nil)
        reopened.reload()
        #expect(reopened.records.isEmpty)
        #expect(reopened.storageError == nil)
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("Unauthorized, streamed, partial, mislabeled and preview responses leave no saved files")
    func invalidResponses() async throws {
        let audio = Self.wave()
        let server = try await LocalAudioServer([
            "/unauthorized": [Reply(status: 403, audio: audio)],
            "/inline": [Reply(attachment: false, audio: audio)],
            "/partial": [Reply(status: 206, audio: audio)],
            "/playlist": [Reply(audio: Data("#EXTM3U\nhttps://example.invalid/segment".utf8))],
            "/preview": [Reply(audio: audio)],
            "/oversized": [Reply(length: 250_000_001, audio: audio)],
            "/auth-challenge": [Reply(status: 401, headers: ["WWW-Authenticate: Basic realm=\"test\""])],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, Int, String)] = [
            ("/unauthorized", 2, "服务器拒绝访问或要求身份验证"),
            ("/inline", 2, "音源未将此音频提供为下载文件"),
            ("/partial", 2, "音频不完整或仅提供试听"),
            ("/playlist", 2, "文件无法作为无 DRM 音频播放"),
            ("/preview", 60, "音频不完整或仅提供试听"),
            ("/oversized", 2, "音频超过 250 MB 的下载上限"),
            ("/auth-challenge", 2, "服务器拒绝访问或要求身份验证"),
        ]
        for (path, duration, message) in cases {
            let downloads = DownloadManager(directory: directory) { _, _ in
                .init(url: server.url(path), quality: "128k")
            }
            let track = Self.track(duration: duration)
            let job = try #require(downloads.download(track, quality: .standard))
            await job.value
            #expect(downloads.failures[DownloadManager.key(for: track)]?.message == message)
            #expect(downloads.records.isEmpty)
            #expect(downloads.activeDownloads.isEmpty)
            #expect(try Self.stagedFiles(in: directory).isEmpty)
        }
    }

    @Test("A cancelled or stale resolution can be retried without installing a file")
    func cancellationAndSourceChange() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var revision = 0
        let downloads = DownloadManager(directory: directory, resolve: { _, _ in
            revision += 1
            return .init(url: URL(string: "https://example.invalid/song.wav")!, quality: "128k")
        }, sourceRevision: { revision })
        let track = Self.track()
        let key = DownloadManager.key(for: track)
        let cancelled = try #require(downloads.download(track, quality: .standard))
        downloads.cancel(key)
        await cancelled.value
        #expect(downloads.records.isEmpty)
        #expect(downloads.failures.isEmpty)
        #expect(downloads.activeDownloads.isEmpty)

        let stale = try #require(downloads.download(track, quality: .standard))
        await stale.value
        #expect(downloads.failures[key]?.message == "音源配置已更改，请重试")
        #expect(downloads.records.isEmpty)
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("Legacy manifests reopen, interrupted deletion rolls back, and staged downloads are cleared")
    func recoverLegacyDownload() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("Downloads")
        let stage = storage.appendingPathComponent(".staging")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let track = Self.track()
        let legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        let manifest = try JSONSerialization.data(withJSONObject: [[
            "id": track.playbackKey, "track": legacy, "quality": "128k",
            "fileName": "legacy.wav", "createdAt": 0,
        ]])
        let manifestURL = directory.appendingPathComponent("downloads.json")
        let file = storage.appendingPathComponent("legacy.wav")
        let removed = stage.appendingPathComponent("deleted-legacy.wav")
        let orphan = storage.appendingPathComponent("offline-\(UUID().uuidString).wav")
        let part = stage.appendingPathComponent("partial.wav")
        for url in [removed, orphan, part] { try Self.wave().write(to: url) }

        // An unreadable manifest must be preserved along with potentially referenced files.
        try Data("broken manifest".utf8).write(to: manifestURL)
        let downloads = DownloadManager(directory: directory, resolve: { _, _ in throw URLError(.badURL) })
        #expect(downloads.storageError != nil)
        #expect(downloads.download(track, quality: .standard) == nil)
        #expect(FileManager.default.fileExists(atPath: removed.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        try manifest.write(to: manifestURL, options: .atomic)
        downloads.reload()
        #expect(downloads.storageError == nil)
        let restored = try #require(downloads.record(for: track))
        #expect(restored.qualityVerified == nil)
        #expect(restored.qualityLabel == "实际 PCM 16-bit")
        #expect(restored.publicFileName != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: downloads.fileURL(for: restored)) == Self.wave())
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Self.stagedFiles(in: directory).isEmpty)
        let persisted = try JSONDecoder().decode([DownloadManager.Record].self, from: Data(contentsOf: manifestURL))
        #expect(persisted == [restored])
    }

    @Test("Known paid, delisted, copyright-restricted and cloud tracks cannot start transfers")
    func deniesCatalogueRestrictions() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = DownloadManager(directory: directory) { _, _ in
            Issue.record("A catalogue restriction must stop resolution")
            throw URLError(.badURL)
        }
        for flags in [
            #""fee":1"#,
            #""fee":4"#,
            #""noCopyrightRcmd":{}"#,
            #""pc":{}"#,
            #""privilege":{"id":123,"st":-200}"#,
        ] {
            let track = try JSONDecoder().decode(Track.self, from: Data("""
                {"id":123,"name":"Test","source":"wy",\(flags)}
                """.utf8))
            #expect(downloads.download(track, quality: .standard) == nil)
        }
    }

    @Test("Downloads use the original catalogue even when streaming allows cross-provider fallback")
    func noCrossProviderFallback() async throws {
        let url = URL(string: "https://example.invalid/music.wav")!
        var catalogueMatches = 0
        let match = Self.track()
        let resolver = Self.resolver(url: url) { _, _ in
            catalogueMatches += 1
            return match
        }
        let original = Self.track(source: "wy")
        do {
            _ = try await resolver.resolveDownloadMusicURL(for: original, quality: AudioQuality.standard.rawValue)
            Issue.record("A different catalogue must not supply an offline copy")
        } catch let error as LXUserAPIService.LXError {
            guard case .missingCapability = error else { throw error }
        }
        #expect(catalogueMatches == 0)
        let streaming = try await resolver.resolveMusicURL(for: original, quality: AudioQuality.standard.rawValue)
        #expect(streaming.url == url)
        #expect(catalogueMatches == 1)
    }

    @Test("Downloads preserve the selected LX script and exact quality token")
    func usesExactScriptAndQuality() async throws {
        let backupURL = URL(string: "https://backup.example.invalid/tone.flac")!
        let preferred = Self.source(id: "selected", qualities: "'128k', 'flac24bit'") { """
            if (info.type === 'flac24bit') return 'https://selected.example.invalid/hires.flac';
            throw new Error('Unavailable');
            """ }
        let backup = Self.source(id: "backup", qualities: "'128k', '320k', 'flac'") { """
            return '\(backupURL.absoluteString)';
            """ }
        let resolver = LXUserAPIService(sourceSnapshot: { (0, [preferred, backup]) },
                                        platformFallbackEnabled: { false })
        let track = Self.track()
        await #expect(throws: DownloadQualityError.self) {
            try await resolver.resolveDownloadMusicURL(for: track, quality: AudioQuality.lossless.rawValue)
        }
        await #expect(throws: LXUserAPIService.LXError.self) {
            try await resolver.resolveDownloadMusicURL(for: track, quality: AudioQuality.standard.rawValue)
        }
        let exact = try await resolver.resolveDownloadMusicURL(for: track, quality: AudioQuality.hires.rawValue)
        #expect(exact.quality == "flac24bit")
        #expect(exact.url.host == "selected.example.invalid")
        #expect(exact.qualityIsVerified == false)
        let streaming = try await resolver.resolveMusicURL(for: track, quality: AudioQuality.standard.rawValue)
        #expect(streaming.url == backupURL)
    }

    @Test("Downloaded audio is measured in both AAC tiers and FLAC bit depths")
    func measuresAudioTiers() throws {
        let formats: [(String, String, AudioQuality, AudioQuality)] = [
            ("tone-128", "m4a", .standard, .exhigh),
            ("tone-320", "m4a", .exhigh, .standard),
            ("tone-16", "flac", .lossless, .hires),
            ("tone-24", "flac", .hires, .lossless),
        ]
        for (name, ext, exact, mismatch) in formats {
            let audio = try #require(DownloadAudioQuality.inspect(Self.fixtureURL(name, ext)))
            #expect(audio.matches(exact))
            #expect(!audio.matches(mismatch))
        }
    }

    @Test("An incorrect replacement leaves the old copy, and a verified alternative replaces it")
    func verifiesReplacementBeforeCommit() async throws {
        let originalAudio = try Self.fixture("tone-128", "m4a")
        let replacementAudio = try Self.fixture("tone-16", "flac")
        let server = try await LocalAudioServer([
            "/standard": [Reply(contentType: "audio/mp4", audio: originalAudio)],
            "/lossless": [Reply(contentType: "audio/mp4", audio: originalAudio),
                          Reply(contentType: "audio/flac", audio: replacementAudio)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var sourceID = "selected"
        var requests = 0
        let downloads = DownloadManager(directory: directory, resolve: { _, quality in
            requests += 1
            return .init(url: server.url("/" + quality), quality: AudioQuality(rawValue: quality)!.lxType)
        }, selectedSourceID: { sourceID })
        let track = Self.track()
        let key = DownloadManager.key(for: track)
        await (try #require(downloads.download(track, quality: .standard))).value
        let original = try #require(downloads.record(for: track))
        let originalURL = downloads.fileURL(for: original)
        #expect(downloads.download(track, quality: .standard) == nil)

        await (try #require(downloads.download(track, quality: .lossless))).value
        let failure = try #require(downloads.failures[key])
        #expect(failure.message.contains("音质不符"))
        #expect(downloads.record(for: track) == original)
        #expect(try Data(contentsOf: originalURL) == originalAudio)
        #expect(try Self.stagedFiles(in: directory).isEmpty)

        sourceID = "different-script"
        downloads.retry(failure)
        #expect(downloads.activeDownloads.isEmpty)
        #expect(requests == 2)
        #expect(!downloads.alreadyDownloaded(track, quality: .standard))
        await (try #require(downloads.download(track, quality: .lossless))).value
        let replacement = try #require(downloads.record(for: track))
        #expect(replacement.sourceID == "different-script")
        #expect(replacement.qualityLabel == "实际 FLAC 16-bit")
        #expect(try Data(contentsOf: downloads.fileURL(for: replacement)) == replacementAudio)
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(downloads.records.count == 1)
    }

    @Test("A destination conflict keeps the external file and deletion in Files removes the library entry")
    func externalDeletionAndMigrationConflict() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("Downloads")
        let music = directory.appendingPathComponent("Documents/Music")
        for folder in [storage, music] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let track = Self.track()
        var pending = DownloadManager.Record(id: track.playbackKey, track: track, quality: "128k",
                                             qualityVerified: false, fileName: "legacy.wav", createdAt: Date())
        pending.publicFileName = "claimed.wav"
        try JSONEncoder().encode([pending]).write(to: directory.appendingPathComponent("downloads.json"))
        try Self.wave().write(to: storage.appendingPathComponent(pending.fileName))
        let external = music.appendingPathComponent("claimed.wav")
        let externalBytes = Data("external file".utf8)
        try externalBytes.write(to: external)

        let downloads = DownloadManager(directory: directory, musicDirectory: music) { _, _ in throw URLError(.badURL) }
        let record = try #require(downloads.record(for: track))
        let file = downloads.fileURL(for: record)
        #expect(file != external)
        #expect(file.deletingLastPathComponent().path == music.path)
        #expect(try Data(contentsOf: external) == externalBytes)
        #expect(try Data(contentsOf: file) == Self.wave())
        try FileManager.default.removeItem(at: file)
        #expect(downloads.record(for: track) == nil)
        downloads.reload()
        #expect(downloads.records.isEmpty)
        #expect(try Data(contentsOf: external) == externalBytes)
    }

    @Test("Migration leaves unrecognized legacy bytes private, and interrupted public deletion rolls back")
    func recoversPublicDeletionWithoutExportingUnknownFiles() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let track = Self.track()
        let questionable = Self.track(source: "wy")
        let old = DownloadManager.Record(id: track.playbackKey, track: track, quality: "128k",
                                         qualityVerified: false, fileName: "legacy.wav", createdAt: Date())
        let unknown = DownloadManager.Record(id: questionable.playbackKey, track: questionable, quality: "128k",
                                             qualityVerified: nil, fileName: "unrecognized.m4a", createdAt: Date())
        let manifest = directory.appendingPathComponent("downloads.json")
        try JSONEncoder().encode([old, unknown]).write(to: manifest)
        try Self.wave().write(to: storage.appendingPathComponent(old.fileName))
        try Data("unexpected legacy data".utf8).write(to: storage.appendingPathComponent(unknown.fileName))
        let store = DownloadManager(directory: directory) { _, _ in throw URLError(.badURL) }
        let migrated = try #require(store.record(for: track))
        let file = store.fileURL(for: migrated)
        let privateCopy = try #require(store.record(for: questionable))
        #expect(privateCopy.publicFileName == nil)
        #expect(privateCopy.qualityLabel.contains("实际音质未知"))
        #expect(store.fileURL(for: privateCopy).deletingLastPathComponent().path == storage.path)
        let exposed = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(exposed == [file.lastPathComponent])

        let trash = storage.appendingPathComponent(".staging/removed-from-music-" + migrated.fileName)
        try FileManager.default.moveItem(at: file, to: trash)
        store.reload()
        #expect(store.record(for: track) == migrated)
        #expect(try Data(contentsOf: file) == Self.wave())
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    private static func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "AudioFixtures"))
    }

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name, ext))
    }

    private static func source(id: String, qualities: String, body: () -> String) -> LXSourceStore.Source {
        LXSourceStore.Source(
            id: id, name: id, description: "Synthetic test audio", version: "1.0.0",
            author: "iMusic tests", homepage: "", script: """
                lx.on(lx.EVENT_NAMES.request, async ({ info }) => { \(body()) })
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true, sources: { tx: { type: 'music', actions: ['musicUrl'], qualitys: [\(qualities)] } }
                })
                """, sourceURL: nil
        )
    }

    private static func resolver(url: URL, match: (@MainActor (Track, String) async -> Track?)? = nil) -> LXUserAPIService {
        let source = LXSourceStore.Source(
            id: "offline-audio-fixture", name: "Offline WAV fixture",
            description: "Synthetic test audio", version: "1.0.0", author: "iMusic tests",
            homepage: "", script: """
                lx.on(lx.EVENT_NAMES.request, async () => '\(url.absoluteString)')
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true, sources: { tx: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } }
                })
                """, sourceURL: nil
        )
        return LXUserAPIService(sourceSnapshot: { (0, [source]) },
                                catalogueMatch: match, platformFallbackEnabled: { true })
    }

    private static func track(source: String = "tx", duration: Int = 2) -> Track {
        Track(id: 123, name: "Local test tone", artists: [ArtistRef(id: 1, name: "Fixture")],
              album: AlbumRef(id: 1, name: "Tests", picUrl: nil), durationMS: duration * 1000,
              source: source, sourceMetadata: ["songmid": "synthetic-audio"])
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func stagedFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Downloads/.staging").path)
    }

    private static func wave() -> Data {
        // Two seconds of a quiet, synthesized 440 Hz mono tone.
        let sampleRate: UInt32 = 8_000
        let sampleCount = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            data.append(Swift.withUnsafeBytes(of: &littleEndian) { Data($0) })
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(sampleCount * 2)
        for sample in 0..<sampleCount {
            append(Int16(sin(2 * Double.pi * 440 * Double(sample) / Double(sampleRate)) * 2_000))
        }
        return data
    }
}

private struct Reply: Sendable {
    var status = 200
    var attachment = true
    var length: Int?
    var headers: [String] = []
    var contentType = "audio/wav"
    var audio = Data()

    var response: Data {
        var lines = ["HTTP/1.1 \(status) Test", "Content-Type: \(contentType)", "Connection: close",
                     "Content-Length: \(length ?? audio.count)"] + headers
        if attachment { lines.append("Content-Disposition: attachment; filename=fixture.wav") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + audio
    }
}

private final class LocalAudioServer: @unchecked Sendable {
    private let listener: NWListener
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "imusic.tests.offline-audio")
    // Requests and replies are confined to the listener's serial queue.
    private var replies: [String: [Reply]]

    init(_ replies: [String: [Reply]]) async throws {
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = self.queue
        let readyPort: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = readyPort
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.respond(to: connection)
        }
    }

    func stop() { listener.cancel() }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")! }

    private func respond(to connection: NWConnection, received: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = received + data
            let text = String(decoding: request, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if complete || request.count > 32_768 { connection.cancel() }
                else { self.respond(to: connection, received: request) }
                return
            }
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let reply = self.replies[path]?.isEmpty == false ? self.replies[path]?.removeFirst() : nil
            connection.send(content: (reply ?? Reply(status: 404)).response, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
