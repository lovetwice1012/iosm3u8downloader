package com.example.hlsdownloader.capture

import android.content.Context
import com.example.hlsdownloader.core.DiagnosticEvent
import com.example.hlsdownloader.core.DiagnosticSink
import com.example.hlsdownloader.core.DynamicMediaReference
import com.example.hlsdownloader.core.DynamicPageInspection
import com.example.hlsdownloader.core.DynamicPageInspector
import com.example.hlsdownloader.core.HlsCandidateOrigin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.HttpUrl

/** Headless/best-effort fallback used by normal HTML discovery. */
class WebViewDynamicPageInspector(
    context: Context,
    private val diagnosticSink: DiagnosticSink? = null,
) : DynamicPageInspector {
    private val applicationContext = context.applicationContext

    override suspend fun inspect(url: HttpUrl, seedCookies: List<Cookie>): DynamicPageInspection {
        val session = PlaybackCaptureSession.create(
            context = applicationContext,
            rootUrl = url,
            seedCookies = seedCookies,
            interactive = false,
            diagnosticSink = { category, message ->
                diagnosticSink?.invoke(DiagnosticEvent(category, message))
            },
        )
        return try {
            session.start()
            session.awaitSettled()
            session.snapshotAndStop().toDynamicPageInspection().also { session.dispose() }
        } catch (error: CancellationException) {
            runCatching { session.snapshotAndStop() }
            session.dispose()
            throw error
        } catch (error: Throwable) {
            runCatching { session.snapshotAndStop() }
            session.dispose()
            diagnosticSink?.invoke(
                DiagnosticEvent("webview", "hidden inspection failed error=${error::class.simpleName ?: "error"}"),
            )
            DynamicPageInspection.EMPTY
        }
    }
}

suspend fun PlaybackCaptureSnapshot.toDynamicPageInspection(): DynamicPageInspection =
    withContext(Dispatchers.Default) {
        DynamicPageInspection(
            media = media.map { reference ->
                DynamicMediaReference(
                    url = reference.url,
                    pageUrl = reference.pageUrl,
                    requestReferer = reference.requestReferer,
                    title = reference.title,
                    thumbnailUrl = reference.thumbnailUrl,
                    iframeDepth = reference.iframeDepth,
                    origin = reference.origin.toCoreOrigin(),
                )
            },
            cookies = cookies,
        )
    }

private fun CaptureOrigin.toCoreOrigin(): HlsCandidateOrigin = when (this) {
    CaptureOrigin.VIDEO -> HlsCandidateOrigin.VIDEO
    CaptureOrigin.SOURCE -> HlsCandidateOrigin.SOURCE
    CaptureOrigin.INLINE_SCRIPT -> HlsCandidateOrigin.INLINE_SCRIPT
    CaptureOrigin.IFRAME -> HlsCandidateOrigin.IFRAME
    CaptureOrigin.RUNTIME -> HlsCandidateOrigin.RUNTIME
}
