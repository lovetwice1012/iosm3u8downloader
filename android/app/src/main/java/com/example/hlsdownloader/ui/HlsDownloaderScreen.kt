package com.example.hlsdownloader.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.example.hlsdownloader.core.DownloadPhase
import com.example.hlsdownloader.core.HlsCandidate
import okhttp3.HttpUrl

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HlsDownloaderScreen(
    state: HlsDownloaderUiState,
    onInputChanged: (String) -> Unit,
    onStart: () -> Unit,
    onStartPlaybackCapture: () -> Unit,
    onFinishPlaybackCapture: () -> Unit,
    onCaptureEnteredBackground: () -> Unit,
    onDownload: (HlsCandidate) -> Unit,
    onCancel: () -> Unit,
    onLoadThumbnail: (HlsCandidate) -> Unit,
    onRefreshLog: () -> Unit,
    onClearBrowserData: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var diagnosticExpanded by remember { mutableStateOf(false) }
    var showClearBrowserDataConfirmation by remember { mutableStateOf(false) }

    DisposableEffect(lifecycleOwner, state.playbackCaptureSession) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && state.playbackCaptureSession != null) {
                onCaptureEnteredBackground()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("HLS Downloader", fontWeight = FontWeight.SemiBold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
    ) { insets ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(insets)
                .imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        ) {
            item {
                Column(
                    modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("リンクを貼るだけ", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    SecondaryText("m3u8の直接URLまたは動画ページを解析します。ページ内に複数のHLSがあれば、URLとサムネイルの一覧から選んでMP4にできます。")
                }
            }
            item {
                InputCard(
                    state = state,
                    onInputChanged = onInputChanged,
                    onPaste = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()?.let(onInputChanged)
                    },
                    onStart = onStart,
                    onStartPlaybackCapture = onStartPlaybackCapture,
                )
            }
            if (state.candidates.isNotEmpty()) {
                item {
                    CandidateListCard(
                        candidates = state.candidates,
                        thumbnails = state.thumbnails,
                        isBusy = state.isBusy,
                        onDownload = onDownload,
                        onLoadThumbnail = onLoadThumbnail,
                    )
                }
            }
            if (state.isOperationActive || state.isCancelling || state.isPreparingPlaybackCapture || state.isFinalizingPlaybackCapture) {
                item { ProgressCard(state, onCancel) }
            }
            state.errorMessage?.let { message -> item { ErrorCard(message) } }
            state.outputFile?.let { outputFile ->
                item {
                    CompletionCard(
                        fileName = outputFile.name,
                        segmentCount = state.downloadedSegmentCount,
                        onShare = { shareFile(context, outputFile) },
                    )
                }
            }
            if (state.diagnosticLog.isNotEmpty()) {
                item {
                    DiagnosticCard(
                        log = state.diagnosticLog,
                        expanded = diagnosticExpanded,
                        onExpandedChange = {
                            diagnosticExpanded = it
                            if (it) onRefreshLog()
                        },
                        onRefresh = onRefreshLog,
                        onCopy = { copyText(context, "HLSDownloader 診断ログ", state.diagnosticLog) },
                        onShare = { shareText(context, state.diagnosticLog) },
                    )
                }
            }
            item {
                CompatibilityCard(
                    isBusy = state.isBusy,
                    isClearingBrowserData = state.isClearingBrowserData,
                    browserDataMessage = state.browserDataMessage,
                    onClearBrowserData = { showClearBrowserDataConfirmation = true },
                )
            }
        }
    }

    if (showClearBrowserDataConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearBrowserDataConfirmation = false },
            title = { Text("ブラウザデータを消去") },
            text = {
                Text(
                    "再生解析ブラウザのCookie、ログイン状態、localStorage、IndexedDB、" +
                        "キャッシュをすべて消去します。この操作は元に戻せません。",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearBrowserDataConfirmation = false
                        onClearBrowserData()
                    },
                    enabled = !state.isBusy,
                ) { Text("消去する") }
            },
            dismissButton = {
                TextButton(onClick = { showClearBrowserDataConfirmation = false }) {
                    Text("キャンセル")
                }
            },
        )
    }

    state.playbackCaptureSession?.let { session ->
        PlaybackCaptureBrowser(
            session = session,
            isFinalizing = state.isFinalizingPlaybackCapture,
            onFinish = onFinishPlaybackCapture,
        )
    }
}

@Composable
private fun InputCard(
    state: HlsDownloaderUiState,
    onInputChanged: (String) -> Unit,
    onPaste: () -> Unit,
    onStart: () -> Unit,
    onStartPlaybackCapture: () -> Unit,
) = AppCard {
    Text("動画リンク", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    OutlinedTextField(
        value = state.inputUrl,
        onValueChange = onInputChanged,
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text("https://example.com/video/master.m3u8") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        enabled = !state.isBusy,
        minLines = 2,
        maxLines = 5,
        shape = RoundedCornerShape(12.dp),
    )
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = onPaste, enabled = !state.isBusy) { Text("貼り付け") }
        Button(onClick = onStart, enabled = state.canStart, modifier = Modifier.weight(1f)) {
            Text("解析 / ダウンロード")
        }
    }
    Divider()
    OutlinedButton(
        onClick = onStartPlaybackCapture,
        enabled = state.canStart,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text("再生しながら解析（アルファ）")
    }
    SecondaryText("ページをアプリ内で開き、実際に再生操作をしてHLS通信を検出します。検出後に解析を終了すると候補一覧へ追加します。")
}

@Composable
private fun CandidateListCard(
    candidates: List<HlsCandidate>,
    thumbnails: Map<String, ByteArray>,
    isBusy: Boolean,
    onDownload: (HlsCandidate) -> Unit,
    onLoadThumbnail: (HlsCandidate) -> Unit,
) = AppCard {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("検出されたHLS", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        SecondaryText("${candidates.size}件")
    }
    SecondaryText("保存する動画を選んでください。URLのパスとクエリ値は画面上では伏せていますが、ダウンロード時には元のURLを使用します。")
    candidates.forEachIndexed { index, candidate ->
        CandidateRow(
            candidate = candidate,
            thumbnail = thumbnails[candidate.id],
            isBusy = isBusy,
            onDownload = { onDownload(candidate) },
            onLoadThumbnail = { onLoadThumbnail(candidate) },
        )
        if (index != candidates.lastIndex) Divider(modifier = Modifier.padding(vertical = 4.dp))
    }
}

@Composable
private fun CandidateRow(
    candidate: HlsCandidate,
    thumbnail: ByteArray?,
    isBusy: Boolean,
    onDownload: () -> Unit,
    onLoadThumbnail: () -> Unit,
) {
    LaunchedEffect(candidate.id) { onLoadThumbnail() }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            CandidateThumbnail(thumbnail, candidate.thumbnailUrl != null)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    candidate.title ?: candidate.playlistUrl.host.ifBlank { "HLS動画" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    CandidateBadge(candidate.origin.title)
                    if (candidate.iframeDepth > 0) CandidateBadge("iframe ${candidate.iframeDepth}階層")
                }
                Text(
                    displayUrl(candidate.playlistUrl),
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                if (candidate.pageUrl.host != candidate.playlistUrl.host) {
                    Text(
                        "検出元: ${candidate.pageUrl.host}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
        Button(onClick = onDownload, enabled = !isBusy, modifier = Modifier.fillMaxWidth()) {
            Text("この動画をダウンロード")
        }
    }
}

@Composable
private fun CandidateThumbnail(data: ByteArray?, hasRemoteThumbnail: Boolean) {
    val bitmap = remember(data) {
        data?.let(::decodeThumbnail)?.asImageBitmap()
    }
    Box(
        modifier = Modifier
            .width(120.dp)
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(10.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(bitmap, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Text(if (hasRemoteThumbnail) "▧" else "▶", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun decodeThumbnail(data: ByteArray): android.graphics.Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    var sampleSize = 1
    val maximumDimension = 480
    while (
        bounds.outWidth / sampleSize > maximumDimension * 2 ||
        bounds.outHeight / sampleSize > maximumDimension * 2
    ) {
        if (sampleSize > Int.MAX_VALUE / 2) return null
        sampleSize *= 2
    }
    return BitmapFactory.decodeByteArray(
        data,
        0,
        data.size,
        BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = android.graphics.Bitmap.Config.RGB_565
        },
    )
}

@Composable
private fun CandidateBadge(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f), CircleShape)
            .padding(horizontal = 7.dp, vertical = 3.dp),
        maxLines = 1,
    )
}

@Composable
private fun ProgressCard(state: HlsDownloaderUiState, onCancel: () -> Unit) = AppCard {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(progressTitle(state), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        if (state.progress.totalItems > 0) SecondaryText("${state.progress.completedItems} / ${state.progress.totalItems}")
    }
    val fraction = state.progress.fraction
    if (state.isCancelling || fraction == null) {
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
    } else {
        LinearProgressIndicator(progress = fraction.toFloat(), modifier = Modifier.fillMaxWidth())
    }
    if (!state.isCancelling && !state.isFinalizingPlaybackCapture) {
        OutlinedButton(
            onClick = onCancel,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
        ) { Text("キャンセル") }
    }
}

private fun progressTitle(state: HlsDownloaderUiState): String = when {
    state.isCancelling -> "キャンセル処理中"
    state.isPreparingPlaybackCapture -> "再生解析を準備中"
    state.isFinalizingPlaybackCapture -> "検出結果を確定中"
    else -> state.progress.phase.title
}

@Composable
private fun ErrorCard(message: String) = AppCard {
    Text("⚠  処理できませんでした", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.error)
    Text(message, style = MaterialTheme.typography.bodyMedium)
}

@Composable
private fun CompletionCard(fileName: String, segmentCount: Int, onShare: () -> Unit) = AppCard {
    Text("✓  MP4を作成しました", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color(0xff248a3d))
    Text(fileName, style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
    SecondaryText("${segmentCount}個の断片を結合")
    Button(onClick = onShare, modifier = Modifier.fillMaxWidth()) { Text("ファイルに保存・共有") }
}

@Composable
private fun DiagnosticCard(
    log: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onRefresh: () -> Unit,
    onCopy: () -> Unit,
    onShare: () -> Unit,
) = AppCard {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("診断ログ", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onRefresh) { Text("更新") }
    }
    SecondaryText("HTML・iframe・JavaScript実行後の探索経路と失敗理由を記録します。URLは識別子化し、クエリ値・Cookie・Referer・HTML本文は記録しません。")
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onExpandedChange(!expanded) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (expanded) "ログを隠す" else "ログを表示", modifier = Modifier.weight(1f))
        Text(if (expanded) "▲" else "▼")
    }
    AnimatedVisibility(expanded) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(220.dp)
                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                .padding(10.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(log, style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace))
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = onCopy, modifier = Modifier.weight(1f)) { Text("コピー") }
        OutlinedButton(onClick = onShare, modifier = Modifier.weight(1f)) { Text("共有") }
    }
}

@Composable
private fun CompatibilityCard(
    isBusy: Boolean,
    isClearingBrowserData: Boolean,
    browserDataMessage: String?,
    onClearBrowserData: () -> Unit,
) = AppCard {
    Text("ⓘ  対応範囲", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    Text("video/sourceタグ、ページ内設定、iframe、プレイヤー初期化後のfetch/XHRを探索します。終了済みVOD、相対URL、master playlist、別音声、TS/fMP4、BYTERANGE、identity AES-128に対応します。")
    SecondaryText("再生操作後にURLが生成されるページはアルファ版の再生解析を試せます。Worker内だけの通信、ライブ配信、Widevineには対応できない場合があります。")
    SecondaryText("再生解析ブラウザのCookie・ログイン状態・localStorage・IndexedDB・キャッシュは、通常の有効期限に従ってアプリ内の専用プロファイルへ保持されます。Chromeとは共有されません。")
    SecondaryText("再生解析は前面表示中だけ動作します。候補選択後の保存はバックグラウンド処理へ引き継ぎますが、OSや端末の省電力設定により停止される場合があります。")
    OutlinedButton(
        onClick = onClearBrowserData,
        enabled = !isBusy,
        modifier = Modifier.fillMaxWidth(),
    ) {
        if (isClearingBrowserData) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
        }
        Text(if (isClearingBrowserData) "消去中" else "ブラウザデータを消去")
    }
    browserDataMessage?.let { SecondaryText(it) }
    SecondaryText("保存する権利または許可のあるコンテンツにだけ使用してください。")
    SecondaryText("MPEG-TSのMP4化にはFFmpegKit / FFmpeg（LGPL-3.0）を使用します。")
}

@Composable
private fun AppCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.widthIn(max = 720.dp).fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

@Composable
private fun SecondaryText(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

private fun displayUrl(url: HttpUrl): String {
    val host = if (':' in url.host) "[${url.host}]" else url.host
    val defaultPort = (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80)
    val port = if (defaultPort) "" else ":${url.port}"
    val extensionClass = when {
        url.encodedPath.endsWith(".m3u8", ignoreCase = true) -> "m3u8"
        url.pathSegments.lastOrNull()?.contains('.') == true -> "その他"
        else -> "なし"
    }
    val pathDepth = url.pathSegments.count { it.isNotEmpty() }
    val queryClass = if (url.querySize == 0) "なし" else "あり"
    return "${url.scheme}://$host$port/…（path ${pathDepth}階層・ext $extensionClass・query $queryClass）"
}

private fun copyText(context: Context, label: String, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}

private fun shareText(context: Context, text: String) {
    context.startActivity(
        Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            },
            "診断ログを共有",
        ),
    )
}

private fun shareFile(context: Context, file: java.io.File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    context.startActivity(
        Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = "video/mp4"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
            "MP4を共有",
        ),
    )
}
