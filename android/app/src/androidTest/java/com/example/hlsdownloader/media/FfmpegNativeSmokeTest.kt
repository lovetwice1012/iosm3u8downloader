package com.example.hlsdownloader.media

import android.media.MediaExtractor
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.hlsdownloader.core.DownloadedSegment
import com.example.hlsdownloader.core.MediaContainer
import com.example.hlsdownloader.core.MediaSegment
import com.example.hlsdownloader.core.UrlCandidates
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class FfmpegNativeSmokeTest {
    @Test
    fun remuxesH264AacTransportStreamOnDevice() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val directory = File(targetContext.cacheDir, "ffmpeg-smoke-${System.nanoTime()}")
        assertTrue(directory.mkdirs())
        try {
            val encoded = instrumentation.context.assets.open("h264-aac-smoke.ts.b64")
                .bufferedReader()
                .use { it.readText() }
            val transportStream = File(directory, "input.ts").apply {
                writeBytes(Base64.decode(encoded.trim(), Base64.DEFAULT))
            }
            val output = File(directory, "output.mp4")
            val source = MediaSegment(
                ordinal = 0,
                mediaSequence = 0u,
                duration = 0.3,
                url = UrlCandidates("https://example.com/input.ts".toHttpUrl()),
                byteRange = null,
                encryption = null,
                initializationMap = null,
                hasDiscontinuity = false,
            )

            FfmpegMediaComposer(File(directory, "work")).compose(
                main = listOf(
                    DownloadedSegment(
                        source = source,
                        file = transportStream,
                        container = MediaContainer.TRANSPORT_STREAM,
                        byteCount = transportStream.length().toInt(),
                        initializationDataLength = 0,
                    ),
                ),
                externalAudio = null,
                outputFile = output,
            )

            assertTrue(output.isFile && output.length() > 0L)
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(output.absolutePath)
                val mimeTypes = (0 until extractor.trackCount)
                    .mapNotNull { extractor.getTrackFormat(it).getString("mime") }
                assertTrue("tracks=$mimeTypes", mimeTypes.any { it.startsWith("video/") })
                assertTrue("tracks=$mimeTypes", mimeTypes.any { it.startsWith("audio/") })
            } finally {
                extractor.release()
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
