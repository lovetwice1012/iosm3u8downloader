package com.example.hlsdownloader.media

import com.example.hlsdownloader.core.DownloadedSegment
import com.example.hlsdownloader.core.HlsException
import com.example.hlsdownloader.core.InitializationMap
import com.example.hlsdownloader.core.MediaContainer
import com.example.hlsdownloader.core.MediaSegment
import com.example.hlsdownloader.core.UrlCandidates
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class FfmpegMediaComposerTest {
    @Test
    fun rejectsChangingInitializationMapBeforeNativeRemux() = runBlocking {
        val directory = Files.createTempDirectory("ffmpeg-map-change").toFile()
        try {
            val segments = listOf("init-a.mp4", "init-b.mp4").mapIndexed { index, mapName ->
                val file = directory.resolve("segment-$index.mp4").apply {
                    writeBytes(ByteArray(24) { 1 })
                }
                val map = InitializationMap(
                    url = UrlCandidates("https://media.example/$mapName".toHttpUrl()),
                    byteRange = null,
                    encryption = null,
                )
                DownloadedSegment(
                    source = MediaSegment(
                        ordinal = index,
                        mediaSequence = index.toULong(),
                        duration = 1.0,
                        url = UrlCandidates("https://media.example/s$index.m4s".toHttpUrl()),
                        byteRange = null,
                        encryption = null,
                        initializationMap = map,
                        hasDiscontinuity = false,
                    ),
                    file = file,
                    container = MediaContainer.ISO_BASE_MEDIA,
                    byteCount = file.length().toInt(),
                    initializationDataLength = 8,
                )
            }

            val error = runCatching {
                FfmpegMediaComposer(directory.resolve("working")).compose(
                    main = segments,
                    externalAudio = null,
                    outputFile = directory.resolve("output.mp4"),
                )
            }.exceptionOrNull()

            assertTrue(error is HlsException.RemuxFailed)
            assertTrue(error?.message?.contains("EXT-X-MAP") == true)
        } finally {
            directory.deleteRecursively()
        }
    }
}
