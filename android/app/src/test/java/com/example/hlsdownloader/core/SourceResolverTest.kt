package com.example.hlsdownloader.core

import kotlinx.coroutines.runBlocking
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SourceResolverTest {
    @Test
    fun dynamicImportKeepsRefererAndBlocksPrivateTargetFromPublicRoot() = runBlocking {
        val root = "https://example.com/page".toHttpUrl()
        val referer = "https://example.com/player".toHttpUrl()
        val cookie = Cookie.Builder().name("session").value("secret").hostOnlyDomain("example.com").build()
        val client = HlsHttpClient()
        val resolver = SourceResolver(client)
        val inspection = DynamicPageInspection(
            media = listOf(
                DynamicMediaReference(
                    url = "http://127.0.0.1/private.m3u8".toHttpUrl(),
                    pageUrl = root,
                ),
                DynamicMediaReference(
                    url = "https://cdn.example/public.m3u8".toHttpUrl(),
                    pageUrl = root,
                    requestReferer = referer,
                ),
            ),
            cookies = listOf(OriginBoundCookie(root, cookie)),
        )
        val candidates = resolver.importDynamicInspection(inspection, root)
        assertEquals(1, candidates.size)
        assertEquals(referer, candidates.single().requestReferer)
        assertTrue(client.cookiesFor(root).isEmpty())

        resolver.activateCapturedCookieScope(candidates.single())
        assertTrue(client.cookiesFor(root).any { it.name == "session" })
        assertTrue(client.cookiesFor("http://example.com/page".toHttpUrl()).isEmpty())
        assertTrue(client.cookiesFor("https://cdn.example/public.m3u8".toHttpUrl()).isEmpty())

        resolver.clearCapturedCookieScope()
        assertTrue(client.cookiesFor(root).isEmpty())

        // The WebView grant is consumed by one download attempt.
        resolver.activateCapturedCookieScope(candidates.single())
        assertTrue(client.cookiesFor(root).isEmpty())

        resolver.importDynamicInspection(inspection, root)
        resolver.clearCapturedCookieGrants()
        resolver.activateCapturedCookieScope(candidates.single())
        assertTrue(client.cookiesFor(root).isEmpty())
    }
}
