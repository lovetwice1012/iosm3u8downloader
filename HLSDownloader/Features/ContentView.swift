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
            Text("m3u8またはm3u8を含むページを解析し、最高画質のVOD断片を取得して1つのMP4にまとめます。")
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

            HStack(spacing: 12) {
                Button {
                    viewModel.paste()
                    urlFieldFocused = false
                } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Button {
                    urlFieldFocused = false
                    viewModel.start()
                } label: {
                    Label("ダウンロード", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)
            }
        }
        .cardStyle()
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
            Text("終了済みVOD、相対URL、master playlist、別音声、TS/fMP4、BYTERANGE、identity AES-128に対応します。ライブ配信、FairPlay/SAMPLE-AES、ログイン必須ページは対象外です。")
            Text("保存する権利または許可のあるコンテンツにだけ使用してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .cardStyle()
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
}

