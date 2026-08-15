import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DownloadViewModel()
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    inputCard

                    if !viewModel.candidates.isEmpty {
                        candidateListCard
                    }

                    if viewModel.isRunning {
                        progressCard
                    }
                    if let error = viewModel.errorMessage {
                        errorCard(error)
                    }
                    if let outputURL = viewModel.outputURL {
                        completionCard(outputURL)
                    }

                    compatibilityNote
                }
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("HLS Downloader")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("リンクを貼るだけ")
                .font(.title2.bold())
            Text("m3u8の直接URLまたは動画ページを解析します。ページ内に複数のHLSがあれば、URLとサムネイルの一覧から選んでMP4にできます。")
                .foregroundStyle(.secondary)
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("動画リンク")
                .font(.headline)

            TextField("https://example.com/video/master.m3u8", text: $viewModel.inputURL, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .focused($urlFieldFocused)
                .lineLimit(2...5)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("動画リンク")
                .disabled(viewModel.isRunning)

            HStack(spacing: 12) {
                Button {
                    viewModel.paste()
                    urlFieldFocused = false
                } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunning)

                Button {
                    urlFieldFocused = false
                    viewModel.start()
                } label: {
                    Label("解析 / ダウンロード", systemImage: "magnifyingglass.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            }
        }
        .cardStyle()
    }

    private var candidateListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("検出されたHLS", systemImage: "play.rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.candidates.count)件")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("保存する動画を選んでください。クエリ値は画面上では伏せていますが、ダウンロード時には元のURLを使用します。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 16) {
                ForEach(viewModel.candidates) { candidate in
                    candidateRow(candidate)
                    if candidate.id != viewModel.candidates.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
    }

    private func candidateRow(_ candidate: HLSCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                candidateThumbnail(candidate)

                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.title ?? candidate.playlistURL.host ?? "HLS動画")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(candidate.origin.title)
                            .candidateBadgeStyle()
                        if candidate.iframeDepth > 0 {
                            Text("iframe \(candidate.iframeDepth)階層")
                                .candidateBadgeStyle()
                        }
                    }

                    Text(displayURL(candidate.playlistURL))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    if candidate.pageURL.host != candidate.playlistURL.host,
                       let pageHost = candidate.pageURL.host {
                        Text("検出元: \(pageHost)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                viewModel.download(candidate)
            } label: {
                Label("この動画をダウンロード", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func candidateThumbnail(_ candidate: HLSCandidate) -> some View {
        Group {
            if let image = viewModel.thumbnails[candidate.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    Image(systemName: candidate.thumbnailURL == nil ? "play.rectangle" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 120, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .task(id: candidate.id) {
            await viewModel.loadThumbnail(for: candidate)
        }
        .accessibilityHidden(true)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.progress.phase.title)
                    .font(.headline)
                Spacer()
                if viewModel.progress.totalItems > 0 {
                    Text("\(viewModel.progress.completedItems) / \(viewModel.progress.totalItems)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = viewModel.progress.fraction {
                ProgressView(value: fraction)
                    .accessibilityValue("\(Int(fraction * 100))パーセント")
            } else {
                ProgressView()
            }

            Button("キャンセル", role: .destructive) {
                viewModel.cancel()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("処理できませんでした", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .textSelection(.enabled)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private func completionCard(_ outputURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MP4を作成しました", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(outputURL.lastPathComponent)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
            Text("\(viewModel.downloadedSegmentCount)個の断片を結合")
                .foregroundStyle(.secondary)

            ShareLink(item: outputURL) {
                Label("ファイルに保存・共有", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .cardStyle()
    }

    private var compatibilityNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("対応範囲", systemImage: "info.circle")
                .font(.headline)
            Text("video/sourceタグ、ページ内設定、iframe、プレイヤー初期化後のfetch/XHRを探索します。終了済みVOD、相対URL、master playlist、別音声、TS/fMP4、BYTERANGE、identity AES-128に対応します。")
            Text("再生操作をしないとURLが生成されないサイト、Safariのログイン状態、Worker内だけの通信、ライブ配信、FairPlay/SAMPLE-AESには対応できない場合があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("保存する権利または許可のあるコンテンツにだけ使用してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("MPEG-TSのMP4化にはFFmpegKit / FFmpeg（LGPL-3.0）を使用します。[ライセンス](https://github.com/lovetwice1012/iosm3u8downloader/blob/main/HLSDownloader/Resources/ThirdPartyNotices.txt)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .cardStyle()
    }

    private func displayURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let hadQuery = components.percentEncodedQuery != nil
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.percentEncodedQuery = nil
        return (components.string ?? url.absoluteString) + (hadQuery ? "?…" : "")
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension View {
    func candidateBadgeStyle() -> some View {
        self
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

#Preview {
    ContentView()
}
