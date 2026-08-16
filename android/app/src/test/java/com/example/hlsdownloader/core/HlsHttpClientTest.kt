package com.example.hlsdownloader.core

import kotlinx.coroutines.runBlocking
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun explicitClearRemovesImportedCookies() {
        val client = HlsHttpClient()
        val url = "https://example.com/media/master.m3u8".toHttpUrl()
        val cookie = Cookie.Builder()
            .name("session")
            .value("test-secret-value")
            .hostOnlyDomain("example.com")
            .expiresAt(System.currentTimeMillis() + 60_000)
            .build()

        client.storeCookies(listOf(cookie))
        assertEquals(listOf(cookie), client.cookiesFor(url))

        client.clearCookies()

        assertTrue(client.cookiesFor(url).isEmpty())
    }

    @Test
    fun scopedWebViewCookiesRequireExactSchemeHostAndPort() {
        val cookieJar = InMemoryCookieJar()
        val client = HlsHttpClient(cookieJar = cookieJar)
        val origin = "http://example.com:8080/".toHttpUrl()
        val scopeExpiry = System.currentTimeMillis() + 60_000
        val cookie = Cookie.Builder()
            .name("session")
            .value("test-secret-value")
            .hostOnlyDomain("example.com")
            .path("/video/")
            .expiresAt(scopeExpiry)
            .build()

        client.replaceScopedCookies(listOf(OriginBoundCookie(origin, cookie)))

        assertFalse(OriginBoundCookie(origin, cookie).toString().contains("test-secret-value"))

        assertEquals(listOf(cookie), client.cookiesFor("http://example.com:8080/video/media".toHttpUrl()))
        assertTrue(client.cookiesFor("https://example.com:8080/video/media".toHttpUrl()).isEmpty())
        assertTrue(client.cookiesFor("http://example.com/video/media".toHttpUrl()).isEmpty())
        assertTrue(client.cookiesFor("http://cdn.example.com:8080/video/media".toHttpUrl()).isEmpty())
        assertTrue(client.cookiesFor("http://example.com:8080/other/media".toHttpUrl()).isEmpty())

        val refreshed = Cookie.Builder()
            .name("session")
            .value("refreshed-secret-value")
            .domain("example.com")
            .expiresAt(System.currentTimeMillis() + 3_600_000)
            .build()
        cookieJar.saveFromResponse(origin, listOf(refreshed))
        val scopedResponseCookie = client.cookiesFor(origin).single()
        assertEquals("refreshed-secret-value", scopedResponseCookie.value)
        assertTrue(scopedResponseCookie.hostOnly)
        assertTrue(scopedResponseCookie.expiresAt <= scopeExpiry)

        client.clearScopedCookies()
        assertTrue(client.cookiesFor("http://example.com:8080/video/media".toHttpUrl()).isEmpty())
    }

    private fun server() = MockWebServer().also {
        it.start()
        servers += it
    }
}
