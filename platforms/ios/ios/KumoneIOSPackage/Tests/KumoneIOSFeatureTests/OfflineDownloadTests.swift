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
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload,
                                        selectedSourceID: { "offline-audio-fixture" })
        let key = DownloadManager.key(for: track)
        let first = try #require(downloads.download(track, quality: .standard))
        #expect(downloads.activeDownloads[key] != nil)
        #expect(downloads.download(track, quality: .standard) == nil)
        await first.value
        #expect(downloads.failures[key]?.message.contains("服务器返回 HTTP 503") == true)
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

    @Test("Unauthorized, explicitly restricted, partial, mislabeled and preview responses leave no files")
    func invalidResponses() async throws {
        let audio = Self.wave()
        let server = try await LocalAudioServer([
            "/unauthorized": [Reply(status: 403, audio: audio)],
            "/denied": [Reply(attachment: false, headers: ["X-Download-Allowed: false"], audio: audio)],
            "/no-store": [Reply(headers: ["Cache-Control: private, no-store"], audio: audio)],
            "/generic-playlist": [Reply(attachment: false, contentType: "application/octet-stream",
                                      audio: Data("#EXTM3U\nhttps://example.invalid/segment".utf8))],
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
            ("/denied", 2, "服务器明确限制保存此文件"),
            ("/no-store", 2, "服务器明确限制保存此文件"),
            ("/generic-playlist", 2, "文件无法作为无 DRM 音频播放"),
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

    @Test("An explicitly restricted URL and a lower-quality backup are skipped before an exact download")
    func fallsBackAfterFetchAndValidationFailures() async throws {
        let lower = try Self.fixture("tone-128", "m4a")
        let verified = try Self.fixture("tone-320", "m4a")
        let server = try await LocalAudioServer([
            "/inline": [Reply(attachment: false, headers: ["Cache-Control: no-store"],
                              contentType: "audio/mp4", audio: verified)],
            "/lower": [Reply(contentType: "audio/mp4", audio: lower)],
            "/exact": [Reply(contentType: "audio/mp4", audio: verified)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [("preferred", "/inline"), ("low", "/lower"), ("backup", "/exact")].map { id, path in
            Self.source(id: id, qualities: "'128k', '320k'") {
                "if (info.type === '320k') return '\(server.url(path).absoluteString)'; throw Error('unexpected tier');"
            }
        }
        var track = Self.track()
        track.sourceMetadata["lx.quality.128k.size"] = "1 MB"
        let resolver = LXUserAPIService(sourceSnapshot: { (0, sources) }, platformFallbackEnabled: { false })
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload,
                                        selectedSourceID: { "preferred" })
        await (try #require(downloads.download(track, quality: .exhigh))).value
        let record = try #require(downloads.record(for: track))
        #expect(record.sourceID == "backup")
        #expect(record.sourceLabel == "QQ 音乐 · backup")
        #expect(record.quality == "320k")
        #expect(try Data(contentsOf: downloads.fileURL(for: record)) == verified)
        #expect(downloads.alreadyDownloaded(track, quality: .exhigh))
        #expect(downloads.failures.isEmpty)
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("A Hi-Res failure can explicitly switch to 320 kbps and save a full headerless MP3")
    func changesQualityFromFailedItemAndSavesHeaderlessMP3() async throws {
        let mp3 = try Self.fixture("tone-mp3-320", "mp3")
        let directPath = "/audio/receipt?token=fixture-secret"
        let server = try await LocalAudioServer([
            directPath: [Reply(attachment: false, contentType: "application/octet-stream", audio: mp3)],
            "/no-store": [Reply(attachment: false, headers: ["Cache-Control: no-store"],
                               contentType: "audio/mpeg", audio: mp3)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferred = Self.source(id: "preferred", qualities: "'master', 'flac24bit', '320k'", platform: "kg") {
            """
            if (info.type === 'flac24bit') return 'http://example.invalid/file?token=fixture-secret';
            if (info.type === '320k' || info.type === 'master') return '\(server.url(directPath).absoluteString)';
            throw Error('unexpected tier');
            """
        }
        let backup = Self.source(id: "no-store", qualities: "'flac24bit'", platform: "kg") {
            "return '\(server.url("/no-store").absoluteString)';"
        }
        let lower = Self.source(id: "only-medium", qualities: "'320k'", platform: "kg") {
            "throw Error('private script detail');"
        }
        let resolver = LXUserAPIService(sourceSnapshot: { (0, [preferred, backup, lower]) },
                                        platformFallbackEnabled: { false })
        let track = Self.track(source: "kg")
        let streaming = try await resolver.resolveMusicURL(for: track, quality: AudioQuality.master.rawValue)
        #expect(streaming.quality == "jymaster")
        #expect(!streaming.qualityIsVerified)

        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload,
                                        selectedSourceID: { "preferred" })
        let key = DownloadManager.key(for: track)
        await (try #require(downloads.download(track, quality: .hires))).value
        let failure = try #require(downloads.failures[key])
        #expect(downloads.records.isEmpty)
        #expect(failure.requestedQuality == .hires)
        #expect(failure.message.contains("音源解析："))
        #expect(failure.message.contains("未提供所选音质"))
        #expect(failure.message.contains("直链传输："))
        #expect(failure.message.contains("需要 HTTPS"))
        #expect(failure.message.contains("明确限制保存"))
        #expect(!failure.message.contains("fixture-secret"))
        #expect(try Self.stagedFiles(in: directory).isEmpty)

        #expect(downloads.alternativeQualities(for: failure).contains(.exhigh))
        #expect(!downloads.alternativeQualities(for: failure).contains(.hires))
        let changed = try #require(downloads.retry(failure, quality: .exhigh))
        #expect(downloads.activeDownloads[key]?.requestedQuality == .exhigh)
        await changed.value
        let record = try #require(downloads.record(for: track))
        #expect(record.quality == "320k")
        #expect(record.audio?.bitRate.map { (319_900...320_100).contains($0) } == true)
        #expect(record.qualityLabel == "实际 MP3 约 320 kbps")
        let file = downloads.fileURL(for: record)
        #expect(file.pathExtension == "mp3")
        #expect(try Data(contentsOf: file) == mp3)
        #expect(downloads.failures[key] == nil)
    }

    @Test("Hi-Res uses flac only after native routes fail, and saves verified 24-bit audio",
          arguments: [false, true])
    func resolvesHiResThroughVerifiedLosslessKey(nativeBackupSucceeds: Bool) async throws {
        let aac = try Self.fixture("tone-192", "m4a")
        let flac = try Self.fixture("tone-24", "flac")
        let good = Reply(attachment: false, contentType: "audio/flac", audio: flac)
        let server = try await LocalAudioServer([
            "/native-aac": [Reply(attachment: false, contentType: "audio/mp4", audio: aac)],
            "/native-backup": [nativeBackupSucceeds ? good : Reply(status: 404)],
            "/lossless-24": [good],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferred = Self.source(id: "preferred", qualities: "'flac24bit', 'flac'", platform: "kg") {
            """
            if (info.type === 'flac24bit') return '\(server.url("/native-aac").absoluteString)';
            if (info.type === 'flac') return '\(server.url("/lossless-24").absoluteString)';
            throw Error('unexpected tier');
            """
        }
        let backup = Self.source(id: "backup", qualities: "'flac24bit'", platform: "kg") {
            "if (info.type === 'flac24bit') return '\(server.url("/native-backup").absoluteString)';"
        }
        let resolver = LXUserAPIService(sourceSnapshot: { (0, [preferred, backup]) })
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload,
                                        selectedSourceID: { "preferred" })
        let track = Self.track(source: "kg", songmid: "synthetic-live")
        await (try #require(downloads.download(track, quality: .hires))).value
        let record = try #require(downloads.record(for: track))
        #expect(record.quality == "flac24bit")
        #expect(record.requestToken == (nativeBackupSucceeds ? "flac24bit" : "flac"))
        #expect(record.sourceID == (nativeBackupSucceeds ? "backup" : "preferred"))
        #expect(record.sourcePlatform == "kg")
        #expect(record.qualityVerified == true)
        #expect(record.qualityLabel == "实际 FLAC 24-bit")
        #expect(try Data(contentsOf: downloads.fileURL(for: record)) == flac)
        let nativePaths = ["/native-aac", "/native-backup"]
        #expect(server.requestedPaths == (nativeBackupSucceeds ? nativePaths : nativePaths + ["/lossless-24"]))
        #expect(try Self.stagedFiles(in: directory).isEmpty)

        let reopened = DownloadManager(directory: directory, findDownload: resolver.findDownload)
        #expect(reopened.record(for: track) == record)
    }

    @Test("Hi-Res rejects 16-bit and lossy alias results and fetches a shared URL once")
    func refusesLowerQualityThroughLosslessKey() async throws {
        let aac = try Self.fixture("tone-192", "m4a")
        let flac16 = try Self.fixture("tone-16", "flac")
        let flac24 = try Self.fixture("tone-24", "flac")
        let lossy = Reply(attachment: false, contentType: "audio/mp4", audio: aac)
        let server = try await LocalAudioServer([
            "/same-url": [lossy, Reply(contentType: "audio/flac", audio: flac24)],
            "/alias-flac16": [Reply(contentType: "audio/flac", audio: flac16)],
            "/alias-aac": [lossy],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [
            Self.source(id: "shared", qualities: "'flac24bit', 'flac'", platform: "kg") {
                "return '\(server.url("/same-url").absoluteString)';"
            },
            Self.source(id: "16-bit", qualities: "'flac'", platform: "kg") {
                "if (info.type === 'flac') return '\(server.url("/alias-flac16").absoluteString)';"
            },
            Self.source(id: "lossy", qualities: "'flac'", platform: "kg") {
                "if (info.type === 'flac') return '\(server.url("/alias-aac").absoluteString)';"
            },
        ]
        let resolver = LXUserAPIService(sourceSnapshot: { (0, sources) })
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload)
        let track = Self.track(source: "kg")
        await (try #require(downloads.download(track, quality: .hires))).value
        let failure = try #require(downloads.failures[DownloadManager.key(for: track)])
        #expect(failure.requestedQuality == .hires)
        #expect(failure.message.contains("FLAC 16-bit"))
        #expect(failure.message.contains("AAC 约 192 kbps"))
        #expect(downloads.records.isEmpty)
        #expect(server.requestedPaths == ["/same-url", "/alias-flac16", "/alias-aac"])
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("An authorized inline audio file is saved without attachment")
    func acceptsInlineAudio() async throws {
        let audio = try Self.fixture("tone-mp3-320", "mp3")
        let server = try await LocalAudioServer([
            "/audio": [Reply(attachment: false, headers: ["Content-Disposition: inline"],
                            contentType: "audio/mpeg", audio: audio)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = DownloadManager(directory: directory) { _, _ in
            .init(url: server.url("/audio"), quality: "320k")
        }
        let track = Self.track()
        await (try #require(downloads.download(track, quality: .exhigh))).value
        let record = try #require(downloads.record(for: track))
        #expect(try Data(contentsOf: downloads.fileURL(for: record)) == audio)
    }

    @Test("Exhaustion distinguishes missing tiers, resolution failure, authorization and wrong audio")
    func exhaustedCandidatesReportSpecificReasons() async throws {
        let lower = try Self.fixture("tone-128", "m4a")
        let server = try await LocalAudioServer([
            "/forbidden": [Reply(status: 403)],
            "/lower": [Reply(contentType: "audio/mp4", audio: lower)],
        ])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [
            Self.source(id: "restricted", qualities: "'320k'") { "return '\(server.url("/forbidden").absoluteString)';" },
            Self.source(id: "unavailable", qualities: "'128k'") { "throw Error('do not call me');" },
            Self.source(id: "resolution", qualities: "'320k'") { "throw Error('private token');" },
            Self.source(id: "lower", qualities: "'320k'") { "return '\(server.url("/lower").absoluteString)';" },
        ]
        let resolver = LXUserAPIService(sourceSnapshot: { (0, sources) })
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload)
        let track = Self.track()
        await (try #require(downloads.download(track, quality: .exhigh))).value
        let message = try #require(downloads.failures[DownloadManager.key(for: track)]?.message)
        for reason in ["所有可用音源", "音源解析：", "直链传输：", "文件核验：",
                       "要求身份验证", "音质不符", "未提供所选音质", "有效地址"] {
            #expect(message.contains(reason))
        }
        #expect(!message.contains("private token"))
        #expect(downloads.records.isEmpty)
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("A cross-platform download requires a unique same recording and uses that platform's ID")
    func crossCatalogueRejectsOtherEditAndUsesMatchedID() async throws {
        let verified = try Self.fixture("tone-16", "flac")
        let server = try await LocalAudioServer(["/exact": [Reply(contentType: "application/flac", audio: verified)]])
        defer { server.stop() }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Self.track(source: "wy")
        let exact = Self.track(songmid: "matched-qq-id")
        let other = Self.track(album: "Tests (Live)", songmid: "other-qq-id")
        let ambiguous = Self.track(songmid: "second-qq-id")
        #expect(SearchRecordingGroups.uniqueDownloadMatch(original, among: [exact, other]) == exact)
        #expect(SearchRecordingGroups.uniqueDownloadMatch(original, among: [exact, ambiguous]) == nil)
        #expect(SearchRecordingGroups.uniqueDownloadMatch(original, among: [Self.track(artist: "Another singer")]) == nil)

        let source = Self.source(id: "qq", qualities: "'flac'") {
            """
            if (info.type === 'flac' && info.musicInfo.songmid === 'matched-qq-id')
                return '\(server.url("/exact").absoluteString)';
            throw Error('wrong recording');
            """
        }
        var match = other
        let resolver = LXUserAPIService(sourceSnapshot: { (0, [source]) }, downloadMatch: { _, _ in match },
                                        platformFallbackEnabled: { false })
        let downloads = DownloadManager(directory: directory, findDownload: resolver.findDownload)
        await (try #require(downloads.download(original, quality: .lossless))).value
        #expect(downloads.records.isEmpty)
        let failure = try #require(downloads.failures[DownloadManager.key(for: original)])
        #expect(failure.message.contains("同一录音"))
        #expect(!failure.message.contains("有效地址"))

        match = exact
        await (try #require(downloads.retry(failure))).value
        let record = try #require(downloads.record(for: original))
        #expect(record.track.source == "wy")
        #expect(record.sourcePlatform == "tx")
        #expect(try Data(contentsOf: downloads.fileURL(for: record)) == verified)
        #expect(try Self.stagedFiles(in: directory).isEmpty)
    }

    @Test("Downloaded audio is measured in both AAC tiers, FLAC and ALAC bit depths")
    func measuresAudioTiers() throws {
        let formats: [(String, String, AudioQuality)] = [
            ("tone-128", "m4a", .standard), ("tone-320", "m4a", .exhigh),
            ("tone-16", "flac", .lossless), ("tone-24", "flac", .hires),
            ("tone-alac", "m4a", .lossless),
        ]
        for (name, ext, exact) in formats {
            let audio = try #require(DownloadAudioQuality.inspect(Self.fixtureURL(name, ext)))
            #expect(audio.matches(exact))
        }
        let flac16 = try #require(DownloadAudioQuality.inspect(Self.fixtureURL("tone-16", "flac")))
        let flac24 = try #require(DownloadAudioQuality.inspect(Self.fixtureURL("tone-24", "flac")))
        #expect(!flac16.matches(.hires))
        #expect(flac24.matches(.lossless))
        #expect(!DownloadAudioQuality(codec: "AAC", bitRate: 199_000, bitDepth: nil).matches(.exhigh))
        #expect(DownloadAudioQuality(codec: "MP3", bitRate: 149_000, bitDepth: nil).matches(.standard))
        #expect(!DownloadAudioQuality(codec: "FLAC", bitRate: nil, bitDepth: nil).canCompare(to: .hires))
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
        #expect(!downloads.alreadyDownloaded(track, quality: .standard))
        await (try #require(downloads.retry(failure))).value
        #expect(requests == 3)
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

    private static func source(id: String, qualities: String, platform: String = "tx",
                               body: () -> String) -> LXSourceStore.Source {
        LXSourceStore.Source(
            id: id, name: id, description: "Synthetic test audio", version: "1.0.0",
            author: "iMusic tests", homepage: "", script: """
                lx.on(lx.EVENT_NAMES.request, async ({ info }) => { \(body()) })
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true, sources: { \(platform): { type: 'music', actions: ['musicUrl'], qualitys: [\(qualities)] } }
                })
                """, sourceURL: nil
        )
    }

    private static func resolver(url: URL) -> LXUserAPIService {
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
        return LXUserAPIService(sourceSnapshot: { (0, [source]) })
    }

    private static func track(source: String = "tx", duration: Int = 2, artist: String = "Fixture",
                              album: String = "Tests", songmid: String = "synthetic-audio") -> Track {
        Track(id: 123, name: "Local test tone", artists: [ArtistRef(id: 1, name: artist)],
              album: AlbumRef(id: 1, name: album, picUrl: nil), durationMS: duration * 1000,
              source: source, sourceMetadata: ["songmid": songmid])
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

private extension DownloadManager {
    /// Use one synthetic route for tests unrelated to source iteration.
    convenience init(directory: URL, musicDirectory: URL? = nil,
                     resolve: @escaping @MainActor (Track, String) async throws -> LXUserAPIService.ResolvedURL,
                     sourceRevision: @escaping @MainActor () -> Int = { 0 },
                     selectedSourceID: @escaping @MainActor () -> String? = { nil }) {
        self.init(directory: directory, musicDirectory: musicDirectory, findDownload: { track, quality, verify in
            let resolved = try await resolve(track, quality.rawValue)
            guard resolved.quality == quality.lxType else { throw DownloadAttemptFailure.missingQuality }
            return try await verify(DownloadCandidate(url: resolved.url, track: track, sourceID: selectedSourceID()))
        }, sourceRevision: sourceRevision, selectedSourceID: selectedSourceID)
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
    private var paths: [String] = []

    var requestedPaths: [String] { queue.sync { paths } }

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
            self.paths.append(path)
            let reply = self.replies[path]?.isEmpty == false ? self.replies[path]?.removeFirst() : nil
            connection.send(content: (reply ?? Reply(status: 404)).response, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
