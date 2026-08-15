package com.example.hlsdownloader.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import okhttp3.Cookie
import okhttp3.HttpUrl
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

private class SegmentProgressTracker(
    private val totalItems: Int,
    private val progress: ProgressHandler,
) {
    private val mutex = Mutex()
    private var completedItems = 0

    suspend fun segmentCompleted() {
        mutex.lock()
        try {
            completedItems += 1
            progress(DownloadProgress(DownloadPhase.DOWNLOADING, completedItems, totalItems))
        } finally {
            mutex.unlock()
        }
    }
}

class HlsDownloadService(
    private val mediaComposer: MediaComposer,
    private val client: HlsHttpClient = HlsHttpClient(),
    dynamicInspector: DynamicPageInspector? = null,
    private val diagnostics: DiagnosticLogStore = DiagnosticLogStore(),
) {
    private val sourceResolver = SourceResolver(client, dynamicInspector, diagnostics.sink)
    private val planBuilder = DownloadPlanBuilder(sourceResolver)
    private val segmentDownloader = SegmentDownloader(client, maximumConcurrentDownloads = 6)

    suspend fun discover(input: String): HlsDiscoveryResult = try {
        sourceResolver.discover(input).also { result ->
            diagnostics.record(
                "service",
                "discovery completed candidates=${result.candidates.size} direct=${result.isDirectPlaylist}",
            )
        }
    } catch (error: CancellationException) {
        diagnostics.record("service", "discovery cancelled")
        throw error
    } catch (error: Throwable) {
        diagnostics.record("service", "discovery failed error=${DiagnosticPrivacy.errorCode(error)}")
        throw error
    }

    suspend fun importDynamicInspection(
        inspection: DynamicPageInspection,
        rootUrl: HttpUrl,
    ): List<HlsCandidate> = sourceResolver.importDynamicInspection(inspection, rootUrl)

    fun cookiesFor(url: HttpUrl): List<Cookie> = client.cookiesFor(url)

    fun resetDiagnosticLog() {
        diagnostics.reset()
        diagnostics.record("session", "started")
    }

    fun diagnosticLogText(): String = diagnostics.renderedText()

    fun recordDiagnostic(category: String, message: String) {
        diagnostics.record(category, message)
    }

    suspend fun thumbnailData(candidate: HlsCandidate): ByteArray? {
        val thumbnailUrl = candidate.thumbnailUrl ?: return null
        if (!AutomaticNavigationPolicy.isAllowedFrameNavigation(candidate.pageUrl, thumbnailUrl)) return null
        return try {
            val payload = client.fetchLimited(thumbnailUrl, candidate.pageUrl, 8 * 1024 * 1024)
            payload.data.takeIf { data ->
                data.isNotEmpty() && data.size <= 8 * 1024 * 1024 &&
                    (payload.mimeType?.lowercase(Locale.US)?.startsWith("image/") == true || hasImageSignature(data))
            }
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun download(
        input: String,
        outputDirectory: File,
        progress: ProgressHandler = {},
    ): DownloadResult {
        progress(DownloadProgress(DownloadPhase.RESOLVING, 0, 0))
        val document = sourceResolver.resolve(input)
        return downloadDocument(document, outputDirectory, progress)
    }

    suspend fun download(
        candidate: HlsCandidate,
        outputDirectory: File,
        progress: ProgressHandler = {},
    ): DownloadResult {
        diagnostics.record(
            "service",
            "candidate selected origin=${candidate.origin.name.lowercase()} depth=${candidate.iframeDepth} " +
                DiagnosticPrivacy.urlSummary(candidate.playlistUrl),
        )
        progress(DownloadProgress(DownloadPhase.RESOLVING, 0, 0))
        val document = candidate.document ?: sourceResolver.load(candidate.request, candidate.requestReferer)
        return downloadDocument(document, outputDirectory, progress)
    }

    private suspend fun downloadDocument(
        document: PlaylistDocument,
        outputDirectory: File,
        progress: ProgressHandler,
    ): DownloadResult {
        outputDirectory.mkdirs()
        if (!outputDirectory.isDirectory) throw HlsException.ExportFailed("保存先を作成できません")
        val jobDirectory = File(outputDirectory, ".hls-job-${UUID.randomUUID()}")
        if (!jobDirectory.mkdirs()) throw HlsException.ExportFailed("一時保存先を作成できません")
        var temporaryOutput: File? = null

        try {
            val plan = planBuilder.build(document)
            diagnostics.record(
                "download",
                "plan ready mainSegments=${plan.main.segments.size} " +
                    "audioSegments=${plan.audio?.segments?.size ?: 0} total=${plan.segmentCount} " +
                    DiagnosticPrivacy.urlSummary(plan.sourceUrl),
            )
            progress(DownloadProgress(DownloadPhase.DOWNLOADING, 0, plan.segmentCount))
            val progressTracker = SegmentProgressTracker(plan.segmentCount, progress)
            val segmentProgress: ProgressHandler = { progressTracker.segmentCompleted() }
            val downloaded = coroutineScope {
                val main = async {
                    segmentDownloader.download(
                        playlist = plan.main,
                        prefix = "main",
                        directory = jobDirectory,
                        totalSegments = plan.segmentCount,
                        progress = segmentProgress,
                    )
                }
                val audio = plan.audio?.let { playlist ->
                    async {
                        segmentDownloader.download(
                            playlist = playlist,
                            prefix = "audio",
                            directory = jobDirectory,
                            totalSegments = plan.segmentCount,
                            progress = segmentProgress,
                        )
                    }
                }
                main.await() to audio?.await()
            }

            progress(DownloadProgress(DownloadPhase.COMPOSING, 0, 0))
            diagnostics.record(
                "compose",
                "started mainFiles=${downloaded.first.size} audioFiles=${downloaded.second?.size ?: 0}",
            )
            val finalOutput = uniqueOutputFile(outputDirectory, plan.sourceUrl)
            temporaryOutput = File(outputDirectory, ".${finalOutput.name}.${UUID.randomUUID()}.partial")
            mediaComposer.compose(downloaded.first, downloaded.second, temporaryOutput)
            if (!temporaryOutput.isFile || temporaryOutput.length() <= 0L) {
                throw HlsException.ExportFailed("変換結果が作成されませんでした")
            }
            try {
                Files.move(
                    temporaryOutput.toPath(),
                    finalOutput.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: Throwable) {
                Files.move(
                    temporaryOutput.toPath(),
                    finalOutput.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            temporaryOutput = null
            jobDirectory.deleteRecursively()
            progress(DownloadProgress(DownloadPhase.COMPLETED, 1, 1))
            diagnostics.record("download", "completed segments=${plan.segmentCount}")
            return DownloadResult(finalOutput, plan.sourceUrl, plan.segmentCount)
        } catch (error: CancellationException) {
            diagnostics.record("download", "cancelled")
            temporaryOutput?.delete()
            jobDirectory.deleteRecursively()
            throw error
        } catch (error: Throwable) {
            diagnostics.record("download", "failed error=${DiagnosticPrivacy.errorSummary(error)}")
            temporaryOutput?.delete()
            jobDirectory.deleteRecursively()
            throw error
        }
    }

    private fun uniqueOutputFile(directory: File, sourceUrl: HttpUrl): File {
        val rawBase = sourceUrl.pathSegments.lastOrNull()
            ?.substringBeforeLast('.', "")
            ?.replace(Regex("[^A-Za-z0-9._-]+"), "-")
            ?.trim('-', '.', '_')
            ?.take(48)
            ?.ifEmpty { null }
            ?: "HLS"
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        var candidate = File(directory, "$rawBase-$stamp.mp4")
        var suffix = 2
        while (candidate.exists()) candidate = File(directory, "$rawBase-$stamp-${suffix++}.mp4")
        return candidate
    }

    private fun hasImageSignature(data: ByteArray): Boolean {
        if (data.startsWith(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()))) return true
        if (data.startsWith(byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))) return true
        if (data.startsWith("GIF8".toByteArray())) return true
        if (data.size >= 12 && data.copyOfRange(0, 4).decodeToString() == "RIFF" &&
            data.copyOfRange(8, 12).decodeToString() == "WEBP"
        ) return true
        if (data.size >= 12 && data.copyOfRange(4, 8).decodeToString() == "ftyp") {
            val brand = data.copyOfRange(8, 12).decodeToString().lowercase(Locale.US)
            return brand.startsWith("hei") || brand.startsWith("mif") || brand.startsWith("avif")
        }
        return false
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
        size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
