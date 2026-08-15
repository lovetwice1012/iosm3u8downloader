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
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

class SegmentDownloaderTest {
    @Test
    fun rejectsChangingInitializationMapsBeforeAnyNetworkRequest() = runBlocking {
        val server = MockWebServer()
        server.start()
        val directory = Files.createTempDirectory("hls-changing-map").toFile()
        try {
            val mapA = InitializationMap(UrlCandidates(server.url("/init-a.mp4")), null, null)
            val mapB = InitializationMap(UrlCandidates(server.url("/init-b.mp4")), null, null)
            val playlist = MediaPlaylist(
                effectiveUrl = server.url("/playlist.m3u8"),
                requestReferer = server.url("/page"),
                segments = listOf(
                    mediaSegment(0, server, mapA),
                    mediaSegment(1, server, mapB),
                ),
                hasEndList = true,
            )

            val error = runCatching {
                SegmentDownloader(HlsHttpClient(), 6).download(playlist, "main", directory)
            }.exceptionOrNull()

            assertTrue(error is HlsException.InvalidPlaylist)
            assertTrue(error?.message?.contains("EXT-X-MAP") == true)
            assertEquals(0, server.requestCount)
        } finally {
            server.shutdown()
            directory.deleteRecursively()
        }
    }

    @Test
    fun downloadsAtMostSixInParallelAndReturnsPlaylistOrder() = runBlocking {
        val server = MockWebServer()
        val active = AtomicInteger(0)
        val maximumActive = AtomicInteger(0)
        val ts = AesAndPayloadTest.transportStreamBytes()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val current = active.incrementAndGet()
                maximumActive.updateAndGet { maxOf(it, current) }
                Thread.sleep(80)
                active.decrementAndGet()
                return MockResponse().setBody(Buffer().write(ts))
            }
        }
        server.start()
        val directory = Files.createTempDirectory("hls-segments").toFile()
        try {
            val playlist = MediaPlaylist(
                effectiveUrl = server.url("/playlist.m3u8"),
                requestReferer = server.url("/page"),
                segments = (0 until 10).map { ordinal ->
                    MediaSegment(
                        ordinal = ordinal,
                        mediaSequence = ordinal.toULong(),
                        duration = 1.0,
                        url = UrlCandidates(server.url("/s$ordinal.ts")),
                        byteRange = null,
                        encryption = null,
                        initializationMap = null,
                        hasDiscontinuity = false,
                    )
                },
                hasEndList = true,
            )
            val progress = mutableListOf<Int>()
            val result = SegmentDownloader(HlsHttpClient(), 6).download(
                playlist,
                "main",
                directory,
                totalSegments = 10,
            ) { synchronized(progress) { progress += it.completedItems } }
            assertEquals((0 until 10).toList(), result.map { it.source.ordinal })
            assertTrue("parallelism=${maximumActive.get()}", maximumActive.get() > 1)
            assertTrue("parallelism=${maximumActive.get()}", maximumActive.get() <= 6)
            assertEquals((1..10).toSet(), progress.toSet())
        } finally {
            server.shutdown()
            directory.deleteRecursively()
        }
    }

    private fun mediaSegment(
        ordinal: Int,
        server: MockWebServer,
        initializationMap: InitializationMap,
    ): MediaSegment = MediaSegment(
        ordinal = ordinal,
        mediaSequence = ordinal.toULong(),
        duration = 1.0,
        url = UrlCandidates(server.url("/s$ordinal.m4s")),
        byteRange = null,
        encryption = null,
        initializationMap = initializationMap,
        hasDiscontinuity = false,
    )
}
