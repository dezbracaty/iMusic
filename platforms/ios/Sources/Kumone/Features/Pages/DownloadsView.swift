#if os(iOS)
import SwiftUI

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var player: PlayerService
    private let downloads = DownloadManager.shared

    var body: some View {
        Group {
            if let error = downloads.storageError, downloads.records.isEmpty {
                ContentUnavailableView {
                    Label("无法读取下载", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试", action: downloads.reload)
                }
            } else if downloads.records.isEmpty && downloads.activeDownloads.isEmpty && downloads.failures.isEmpty {
                ContentUnavailableView {
                    Label("还没有下载的歌曲", systemImage: "arrow.down.circle")
                } description: {
                    Text("从歌曲菜单下载音源提供的文件，随时在这里离线播放。")
                }
                .accessibilityIdentifier("downloadsEmpty")
            } else {
                downloadList
            }
        }
        .navigationTitle("已下载")
        .task { downloads.reload() }
    }

    private var downloadList: some View {
        List {
            if let error = downloads.storageError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("重新检查文件 App 目录", action: downloads.reload)
                }
            }
            if !downloads.activeDownloads.isEmpty {
                Section("正在下载") {
                    ForEach(downloads.activeDownloads.values.sorted { $0.id < $1.id }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.track.name)
                                Text(item.requestedQuality.downloadLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let candidate = item.candidateLabel {
                                    Text(candidate).font(.caption).foregroundStyle(.secondary)
                                }
                                if let fraction = item.fraction {
                                    ProgressView(value: fraction)
                                        .accessibilityLabel("下载进度")
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("正在准备下载")
                                }
                            }
                            Button("取消") { downloads.cancel(item.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !downloads.failures.isEmpty {
                Section("下载失败") {
                    ForEach(downloads.failures.values.sorted { $0.id < $1.id }) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.track.name)
                            Text("请求：\(item.requestedQuality.downloadLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                if item.requestedQuality.canVerifyDownload {
                                    Button("重试原档位") { downloads.retry(item) }
                                        .accessibilityIdentifier("retryOriginalDownloadQuality")
                                }
                                let alternatives = downloads.alternativeQualities(for: item)
                                if !alternatives.isEmpty {
                                    Menu("换档下载") {
                                        ForEach(alternatives) { quality in
                                            Button(quality.downloadLabel) { downloads.retry(item, quality: quality) }
                                                .accessibilityIdentifier("retryDownload-\(quality.lxType)")
                                        }
                                    }
                                    .accessibilityIdentifier("changeDownloadQuality")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("移除", role: .destructive) { downloads.dismissFailure(item.id) }
                        }
                    }
                }
            }
            ForEach(Array(downloads.records.enumerated()), id: \.element.id) { index, record in
                TrackRow(track: record.track, index: index + 1, style: .compact, subtitleDetail: record.qualityLabel) {
                    player.play(tracks: downloads.records.map(\.track), source: .none, startAt: record.track)
                }
            }
            PlayerClearanceSpacer()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, Theme.Layout.contentInset - 16, for: .scrollContent)
        .accessibilityIdentifier("downloadsList")
        .refreshable { downloads.reload() }
    }
}

@MainActor
struct TrackDownloadMenu: View {
    let track: Track
    var alternatives: [Track] = []
    private let downloads = DownloadManager.shared
    @ObservedObject private var sources = LXSourceStore.shared
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        let key = DownloadManager.key(for: track)
        let record = downloads.record(for: track)
        if let record {
            Text(record.qualityLabel)
            if let source = record.sourceLabel { Text("下载来源：\(source)") }
        }
        if let active = downloads.activeDownloads[key] {
            Menu {
                Button("取消下载") { downloads.cancel(key) }
            } label: {
                Label(active.fraction.map { "正在下载 \($0.formatted(.percent))" } ?? "正在准备下载",
                      systemImage: "arrow.down.circle")
            }
        } else {
            let candidates = ([track] + alternatives).filter(DownloadManager.permitsDownload)
            if !candidates.isEmpty {
                Menu {
                    if candidates.count == 1, let candidate = candidates.first {
                        qualityOptions(for: candidate)
                    } else {
                        ForEach(candidates, id: \.playbackKey) { candidate in
                            Menu(platformName(for: candidate)) { qualityOptions(for: candidate) }
                        }
                    }
                } label: {
                    Label(record != nil && candidates.count == 1 ? "更换下载版本" : "下载", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("downloadTrack")
            }
        }
        if let record {
            Button(role: .destructive) {
                downloads.delete(record)
            } label: {
                Label("删除离线下载", systemImage: "trash")
            }
            .accessibilityIdentifier("removeOfflineDownload")
        }
    }

    @ViewBuilder
    private func qualityOptions(for candidate: Track) -> some View {
        Text("优先 \(platformName(for: candidate)) · \(sources.selectedSource?.name ?? "未选择 LX 音源")")
        let preferred = settings.audioQuality
        if !preferred.canVerifyDownload {
            Button("所选音质：\(preferred.downloadLabel)") {
                downloads.download(candidate, quality: preferred)
            }
        }
        ForEach(AudioQuality.verifiableDownloads) { quality in
            let installed = downloads.alreadyDownloaded(candidate, quality: quality)
            Button {
                downloads.download(candidate, quality: quality)
            } label: {
                let name = installed ? "\(quality.downloadLabel) · 已下载" : quality.downloadLabel
                if quality.lxType == preferred.lxType {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
            .disabled(installed || downloads.activeDownloads[DownloadManager.key(for: candidate)] != nil)
        }
    }

    private func platformName(for track: Track) -> String {
        LXCatalogPlatform.displayName(for: SearchRecordingGroups.source(of: track))
    }
}

@MainActor
struct TrackDownloadIndicator: View {
    let track: Track
    private let downloads = DownloadManager.shared

    var body: some View {
        if downloads.record(for: track) != nil {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("已下载")
        }
    }
}
#endif
