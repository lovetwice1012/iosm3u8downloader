package com.example.hlsdownloader.core

import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HlsHttpClientTest {
    private val servers = mutableListOf<MockWebServer>()

    @After
    fun tearDown() {
        servers.forEach { it.shutdown() }
    }

    @Test
    fun retriesTransientStatusAndValidatesPartialContent() = runBlocking {
        val server = server()
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(
            MockResponse()
                .setResponseCode(206)
                .setHeader("Content-Range", "bytes 2-4/10")
                .setBody("234"),
        )
        val payload = HlsHttpClient().fetch(server.url("/media"), byteRange = ByteRange(2, 3))
        assertEquals("234", payload.data.decodeToString())
        assertEquals(2, server.requestCount)
    }

    @Test
    fun crossOriginRedirectShrinksRefererBeforeNextRequest() = runBlocking {
        val source = server()
        val destination = server()
        source.enqueue(
            MockResponse().setResponseCode(302).setHeader("Location", destination.url("/final")),
        )
        destination.enqueue(MockResponse().setBody("ok"))
        val referer = source.url("/private/page?token=SECRET")
        HlsHttpClient().fetch(source.url("/start"), referer = referer)
        source.takeRequest()
        val redirected = destination.takeRequest()
        assertEquals(source.url("/").toString(), redirected.getHeader("Referer"))
        assertTrue(redirected.getHeader("Referer").orEmpty().contains("SECRET").not())
    }

    @Test
    fun perCallRedirectPolicyBlocksBeforeCrossOriginGet() = runBlocking {
        val source = server()
        val destination = server()
        source.enqueue(
            MockResponse().setResponseCode(302).setHeader("Location", destination.url("/never")),
        )
        assertThrows(HlsException.Network::class.java) {
            runBlocking {
                HlsHttpClient().fetch(
                    source.url("/frame"),
                    redirectPolicy = { _, _ -> false },
                )
            }
        }
        assertEquals(0, destination.requestCount)
    }

    @Test
    fun enforcesPayloadLimitWhileStreaming() {
        val server = server()
        server.enqueue(MockResponse().setChunkedBody("12345", 1))
        assertThrows(HlsException.Network::class.java) {
            runBlocking { HlsHttpClient().fetch(server.url("/large"), maximumBytes = 4) }
        }
    }

    private fun server() = MockWebServer().also {
        it.start()
        servers += it
    }
}
