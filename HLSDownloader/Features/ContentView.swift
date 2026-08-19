import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = DownloadViewModel()
    @State private var diagnosticLogExpanded = false
    @State private var isWVDImporterPresented = false
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
                    if viewModel.hasWidevineCandidates {
                        widevineCredentialCard
                    }

                    if viewModel.isBusy {
                        progressCard
                    }
                    if let error = viewModel.errorMessage {
                        errorCard(error)
                    }
                    if let outputURL = viewModel.outputURL {
                        completionCard(outputURL)
                    }
                    if !viewModel.diagnosticLog.isEmpty {
                        diagnosticLogCard
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
        .fullScreenCover(
            isPresented: playbackCapturePresentation,
            onDismiss: { viewModel.finishPlaybackCapture() }
        ) {
            if let session = viewModel.playbackCaptureSession {
                PlaybackCaptureBrowser(session: session, viewModel: viewModel)
            } else {
                ProgressView("再生解析を準備中…")
            }
        }
        .fileImporter(
            isPresented: $isWVDImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "wvd") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            viewModel.importWidevineCredential(from: url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.playbackCaptureDidEnterBackground()
            }
        }
    }

    private var playbackCapturePresentation: Binding<Bool> {
        Binding(
            get: { viewModel.isPlaybackCapturePresented },
            set: { isPresented in
                if !isPresented { viewModel.finishPlaybackCapture() }
            }
        )
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("リンクを貼るだけ")
                .font(.title2.bold())
            Text("m3u8/MPDの直接URLまたは動画ページを解析します。ページ内に複数の動画があれば、URLとサムネイルの一覧から選べます。")
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
                .disabled(viewModel.isBusy)

            HStack(spacing: 12) {
                Button {
                    viewModel.paste()
                    urlFieldFocused = false
                } label: {
                    Label("貼り付け", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)

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

            Divider()

            Button {
                urlFieldFocused = false
                viewModel.startPlaybackCapture()
            } label: {
                Label("再生ページを開いて解析（アルファ）", systemImage: "waveform.path.ecg.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canStart)

            Text("ページをアプリ内で開き、実際の再生操作からHLS、DASH/MPD、Widevine EMEとライセンス要求の試行を自動判定します。検出後に解析を終了すると候補一覧へ追加します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var candidateListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("検出された動画", systemImage: "play.rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.candidatePresentations.count)件")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("保存する動画を選んでください。URLのパスとクエリ値は画面上では伏せていますが、ダウンロード時には元のURLを使用します。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 16) {
                ForEach(viewModel.candidatePresentations) { presentation in
                    candidateRow(presentation)
                    if presentation.id != viewModel.candidatePresentations.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func candidateRow(_ presentation: CandidatePresentation) -> some View {
        let candidate = presentation.candidate
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                candidateThumbnail(candidate)

                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.title ?? candidate.playlistURL.host ?? candidate.kind.fallbackTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(candidate.kind.badgeTitle)
                            .candidateBadgeStyle()
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

            if presentation.resolutionChoices.count > 1 {
                HStack(spacing: 12) {
                    Label(
                        "\(presentation.resolutionChoices.count)画質",
                        systemImage: "rectangle.on.rectangle"
                    )
                    .font(.footnote.weight(.medium))
                    Spacer()
                    Picker(
                        "解像度",
                        selection: Binding(
                            get: {
                                viewModel.selectedResolutionChoice(for: presentation)?.id
                                    ?? presentation.resolutionChoices[0].id
                            },
                            set: { selectedID in
                                guard let choice = presentation.resolutionChoices.first(where: {
                                    $0.id == selectedID
                                }) else { return }
                                viewModel.selectResolutionChoice(choice, for: presentation)
                            }
                        )
                    ) {
                        ForEach(presentation.resolutionChoices) { choice in
                            Text(choice.displayTitle).tag(choice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.isBusy)
                    .accessibilityHint("選択した解像度でダウンロードします")
                }
            }

            if candidate.kind == .widevineDASH {
                Button {
                    viewModel.download(presentation)
                } label: {
                    Label("ダウンロード・保存", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canDownload(presentation))

                Text(widevineCandidateStatus(candidate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    viewModel.download(presentation)
                } label: {
                    Label("この動画をダウンロード", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canDownload(presentation))
            }
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
                    Image(
                        systemName: candidate.kind == .widevineDASH
                            ? "lock.shield"
                            : (candidate.thumbnailURL == nil ? "play.rectangle" : "photo")
                    )
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

    private var widevineCredentialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Widevine L3（アルファ）", systemImage: "lock.shield")
                .font(.headline)

            if viewModel.hasWidevineCredential {
                Label("WVDはKeychainに保存済みです", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("使用を許可されたWidevine L3のWVDファイルを読み込んでください。WVDの内容は診断ログへ出力しません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    isWVDImporterPresented = true
                } label: {
                    Label(
                        viewModel.hasWidevineCredential ? "WVDを入れ替え" : "WVDを読み込む",
                        systemImage: "key.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)

                if viewModel.hasWidevineCredential {
                    Button(role: .destructive) {
                        viewModel.deleteWidevineCredential()
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)
                }
            }

            if let message = viewModel.widevineCredentialMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.isWidevineProcessingConfigured {
                Label(
                    "このビルドではWidevine処理プロバイダを利用できません。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private func widevineCandidateStatus(_ candidate: HLSCandidate) -> String {
        let detection: String
        if candidate.widevinePlaybackContext?.isHighConfidence == true {
            detection = "再生時のWidevine EMEとライセンス要求を関連付けました。"
        } else if candidate.widevinePlaybackContext != nil {
            detection = "再生時のライセンス要求候補を検出しました。"
        } else {
            detection = "Widevine MPDを検出しました（ライセンス要求は未検出）。"
        }
        guard isDownloadableWidevineDomain(candidate.playlistURL) else {
            return detection + " 許可ドメイン外のため再生・保存できません。"
        }
        guard viewModel.hasWidevineCredential else {
            return detection + " 保存にはWidevine L3のWVD読み込みが必要です。"
        }
        guard viewModel.isWidevineProcessingConfigured else {
            return detection + " Widevine処理プロバイダの組み込みが必要です。"
        }
        return detection + " 許可ドメインのWidevine候補です。"
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(progressTitle)
                    .font(.headline)
                Spacer()
                if viewModel.progress.totalItems > 0 {
                    Text("\(viewModel.progress.completedItems) / \(viewModel.progress.totalItems)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isCancelling {
                ProgressView()
            } else if let fraction = viewModel.progress.fraction {
                ProgressView(value: fraction)
                    .accessibilityValue("\(Int(fraction * 100))パーセント")
            } else {
                ProgressView()
            }

            if !viewModel.isCancelling && !viewModel.isFinalizingPlaybackCapture {
                Button("キャンセル", role: .destructive) {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var progressTitle: String {
        if viewModel.isCancelling { return "キャンセル処理中" }
        if viewModel.isPreparingPlaybackCapture { return "再生解析を準備中" }
        if viewModel.isFinalizingPlaybackCapture { return "検出結果を確定中" }
        return viewModel.progress.phase.title
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
            Label(
                completionTitle(for: outputURL),
                systemImage: "checkmark.circle.fill"
            )
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

    private func completionTitle(for outputURL: URL) -> String {
        switch outputURL.pathExtension.lowercased() {
        case "wav": return "WAVを作成しました"
        case "webm": return "WebMを保存しました"
        default: return "MP4を作成しました"
        }
    }

    private var diagnosticLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("診断ログ", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("更新") {
                    viewModel.refreshDiagnosticLog()
                }
                .buttonStyle(.borderless)
            }

            Text("HTML・iframe・JavaScript実行後の探索経路と失敗理由を記録します。URLは識別子化し、クエリ値・Cookie・Referer・HTML本文は記録しません。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("ログを表示", isExpanded: $diagnosticLogExpanded) {
                ScrollView([.horizontal, .vertical]) {
                    Text(viewModel.diagnosticLog)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(height: 220)
            }
            .onChange(of: diagnosticLogExpanded) { _, isExpanded in
                if isExpanded { viewModel.refreshDiagnosticLog() }
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.copyDiagnosticLog()
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(item: viewModel.diagnosticLog) {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var compatibilityNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("対応範囲", systemImage: "info.circle")
                .font(.headline)
            Text("video/sourceタグ、ページ内設定、iframe、プレイヤー初期化後のfetch/XHRを探索します。HLS/DASHに加えてMP4/MOV/M4A/MP3/Ogg/Opus/WebMと完了Blobを検証し、音声trackだけならPCM WAV、video WebMならWebM、それ以外の動画はMP4で保存します。単体TS/AAC/AC3/EAC3は安全にclear判定できないため保存非対応、MSE単体は検出表示のみで、元manifestを優先します。")
            Text("Widevine DASH/MPDは `isDownloadableWidevineDomain` の許可hostだけを候補化します。その他のWidevineは再生・保存とも拒否し、DRMなしHLSは従来どおり全ドメインで処理します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("再生操作後にURLが生成されるページはアルファ版の再生解析を試せます。iOS標準DRMはFairPlayで、Widevineは標準WKWebView/AVFoundationの再生機能ではありません。FairPlayは復号済みMP4/WAVとして書き出せず、SAMPLE-AESもFairPlay key formatではなくidentity key formatだけが保存対象です。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("再生解析は前面表示中だけ動作します。候補選択後の保存はiOS 26でバックグラウンド継続を要求し、利用できない署名・OSでは短時間の完了猶予へ切り替わります。")
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
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawScheme = components?.scheme?.lowercased() ?? ""
        let scheme = ["http", "https"].contains(rawScheme) ? rawScheme : "other"
        let rawHost = components?.host ?? "unknown-host"
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let port = components?.port.map { ":\($0)" } ?? ""
        let pathDepth = url.path.split(separator: "/").count
        let extensionClass: String
        switch url.pathExtension.lowercased() {
        case "m3u8": extensionClass = "m3u8"
        case "mpd": extensionClass = "mpd"
        case "": extensionClass = "なし"
        default: extensionClass = "その他"
        }
        let queryClass = components?.percentEncodedQuery == nil ? "なし" : "あり"
        return "\(scheme)://\(host)\(port)/…（path \(pathDepth)階層・ext \(extensionClass)・query \(queryClass)）"
    }
}

private struct PlaybackCaptureBrowser: View {
    @ObservedObject var session: PlaybackCaptureSession
    @ObservedObject var viewModel: DownloadViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PlaybackCaptureWebView(webView: session.webView)
                .allowsHitTesting(!viewModel.isFinalizingPlaybackCapture)
                .overlay {
                    if viewModel.isFinalizingPlaybackCapture {
                        ZStack {
                            Color.black.opacity(0.28)
                            ProgressView("検出結果を確定中…")
                                .padding(18)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            Divider()
            controls
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("再生解析", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Text("ALPHA")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                Spacer()
                Text(captureSummary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("ページ内の再生ボタンを押して動画を少し再生してください。MPD、Widevine EME、ライセンス要求の試行も自動で観測します。このブラウザーの標準Cookieとサイトデータは端末内の永続プロファイルに保存され、サイトが定めた期限内は次回もログイン状態を利用できます。候補が増えたら「解析を終了」を押します。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let host = session.currentURL?.host {
                Text("表示中: \(host)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var captureSummary: String {
        let hlsCount = session.references.filter { $0.kind == .hls }.count
        let widevineCount = session.references.filter { $0.kind == .widevineDASH }.count
        let progressiveCount = session.references.filter { $0.kind == .progressive }.count
        let eme = session.detectedWidevineKeySystem ? " / EME検出" : ""
        let mse = session.detectedMediaSource ? " / MSE検出" : ""
        return "HLS \(hlsCount) / file \(progressiveCount) / Blob \(session.capturedBlobCount) / Widevine \(widevineCount) / license要求 \(session.licenseRequests.count)\(eme)\(mse)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 28, height: 28)
            }
            .disabled(!session.canGoBack || viewModel.isFinalizingPlaybackCapture)
            .accessibilityLabel("戻る")

            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.forward")
                    .frame(width: 28, height: 28)
            }
            .disabled(!session.canGoForward || viewModel.isFinalizingPlaybackCapture)
            .accessibilityLabel("進む")

            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .disabled(viewModel.isFinalizingPlaybackCapture)
            .accessibilityLabel("再読み込み")

            Spacer()

            Button {
                viewModel.finishPlaybackCapture()
            } label: {
                if viewModel.isFinalizingPlaybackCapture {
                    ProgressView()
                        .frame(minWidth: 108)
                } else {
                    Label("解析を終了", systemImage: "checkmark.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isFinalizingPlaybackCapture)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct PlaybackCaptureWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
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

private extension MediaCandidateKind {
    var badgeTitle: String {
        switch self {
        case .hls: return "HLS"
        case .widevineDASH: return "Widevine DASH"
        case .progressive: return "動画・音声ファイル"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .hls: return "HLS動画"
        case .widevineDASH: return "Widevine動画"
        case .progressive: return "動画・音声ファイル"
        }
    }
}

#Preview {
    ContentView()
}
