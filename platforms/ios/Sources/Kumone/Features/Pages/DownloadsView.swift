#if os(iOS)
import SwiftUI

@MainActor
struct DownloadsView: View {
    @EnvironmentObject private var player: PlayerService
    private let downloads = DownloadManager.shared

    var body: some View {
        Group {
            if let error = downloads.storageError {
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
    }

    private var downloadList: some View {
        List {
            if !downloads.activeDownloads.isEmpty {
                Section("正在下载") {
                    ForEach(downloads.activeDownloads.values.sorted { $0.id < $1.id }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.track.name)
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
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.track.name)
                                Text(item.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重试") { downloads.download(item.track, quality: item.requestedQuality) }
                                .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("移除", role: .destructive) { downloads.dismissFailure(item.id) }
                        }
                    }
                }
            }
            ForEach(Array(downloads.records.enumerated()), id: \.element.id) { index, record in
                TrackRow(track: record.track, index: index + 1, style: .compact) {
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
    }
}

@MainActor
struct TrackDownloadMenu: View {
    let track: Track
    private let downloads = DownloadManager.shared

    var body: some View {
        let key = DownloadManager.key(for: track)
        if let record = downloads.record(for: track) {
            Button(role: .destructive) {
                downloads.delete(record)
            } label: {
                Label("删除离线下载", systemImage: "trash")
            }
            .accessibilityIdentifier("removeOfflineDownload")
        } else if let active = downloads.activeDownloads[key] {
            Menu {
                Button("取消下载") { downloads.cancel(key) }
            } label: {
                Label(active.fraction.map { "正在下载 \($0.formatted(.percent))" } ?? "正在准备下载",
                      systemImage: "arrow.down.circle")
            }
        } else if DownloadManager.permitsDownload(of: track) {
            Button {
                downloads.download(track, quality: downloads.failures[key]?.requestedQuality)
            } label: {
                Label(downloads.failures[key] == nil ? "下载" : "重试下载",
                      systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("downloadTrack")
        }
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
