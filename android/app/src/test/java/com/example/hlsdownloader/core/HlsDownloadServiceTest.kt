package com.example.hlsdownloader.core

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class HlsDownloadServiceTest {
    @Test
    fun resolvesDownloadsInOrderAndDelegatesMp4Composition() = runBlocking {
        val server = MockWebServer()
        val ts = AesAndPayloadTest.transportStreamBytes()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/movie.m3u8" -> MockResponse().setBody(
                    "#EXTM3U\n#EXTINF:1,\ns0.ts\n#EXTINF:1,\ns1.ts\n#EXT-X-ENDLIST",
                )
                "/s0.ts", "/s1.ts" -> MockResponse()
                    .setHeader("Content-Type", "video/mp2t")
                    .setBody(Buffer().write(ts))
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        val outputDirectory = Files.createTempDirectory("hls-service").toFile()
        val composedOrdinals = mutableListOf<Int>()
        val composer = object : MediaComposer {
            override suspend fun compose(
                main: List<DownloadedSegment>,
                externalAudio: List<DownloadedSegment>?,
                outputFile: File,
            ) {
                composedOrdinals += main.map { it.source.ordinal }
                assertEquals(null, externalAudio)
                outputFile.writeBytes(
                    byteArrayOf(0, 0, 0, 16, 'f'.code.toByte(), 't'.code.toByte(), 'y'.code.toByte(), 'p'.code.toByte(), 0, 0, 0, 0),
                )
            }
        }
        try {
            val updates = mutableListOf<DownloadProgress>()
            val result = HlsDownloadService(mediaComposer = composer).download(
                server.url("/movie.m3u8").toString(),
                outputDirectory,
            ) { updates += it }
            assertEquals(listOf(0, 1), composedOrdinals)
            assertEquals(2, result.segmentCount)
            assertTrue(result.outputFile.isFile)
            assertEquals(DownloadPhase.COMPLETED, updates.last().phase)
            assertEquals(
                setOf(1, 2),
                updates.filter {
                    it.phase == DownloadPhase.DOWNLOADING && it.completedItems > 0
                }.map { it.completedItems }.toSet(),
            )
        } finally {
            server.shutdown()
            outputDirectory.deleteRecursively()
        }
    }
}
