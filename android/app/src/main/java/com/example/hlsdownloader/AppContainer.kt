package com.example.hlsdownloader

import android.content.Context
import com.example.hlsdownloader.capture.WebViewDynamicPageInspector
import com.example.hlsdownloader.core.DiagnosticLogStore
import com.example.hlsdownloader.core.HlsDownloadService
import com.example.hlsdownloader.core.HlsHttpClient
import com.example.hlsdownloader.media.FfmpegMediaComposer
import java.io.File

object AppContainer {
    @Volatile
    private var sharedService: HlsDownloadService? = null

    fun service(context: Context): HlsDownloadService = sharedService ?: synchronized(this) {
        sharedService ?: createService(context.applicationContext).also { sharedService = it }
    }

    private fun createService(context: Context): HlsDownloadService {
        val diagnostics = DiagnosticLogStore()
        val client = HlsHttpClient()
        val inspector = WebViewDynamicPageInspector(context, diagnostics.sink)
        val composer = FfmpegMediaComposer(File(context.cacheDir, "hls-compose"))
        return HlsDownloadService(
            mediaComposer = composer,
            client = client,
            dynamicInspector = inspector,
            diagnostics = diagnostics,
        )
    }
}
