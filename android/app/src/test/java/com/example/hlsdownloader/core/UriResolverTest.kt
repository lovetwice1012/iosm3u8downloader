package com.example.hlsdownloader.core

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class UriResolverTest {
    @Test
    fun normalizeAndResolveAllSupportedReferenceForms() {
        assertEquals("https://example.com/", UriResolver.normalizeInput("example.com").toString())
        val base = "https://example.com/a/master.m3u8?token=abc".toHttpUrl()
        assertEquals("https://example.com/a/seg.ts", UriResolver.resolveUrl("seg.ts", base).toString())
        assertEquals("https://example.com/root/seg.ts", UriResolver.resolveUrl("/root/seg.ts", base).toString())
        assertEquals("https://cdn.example/seg.ts", UriResolver.resolveUrl("//cdn.example/seg.ts", base).toString())
        assertEquals(
            "https://cdn.example/video.m3u8?x=1",
            UriResolver.resolveUrl("https:\\/\\/cdn.example\\/video.m3u8?x=1", base).toString(),
        )
    }

    @Test
    fun sameOriginQueryFallbackDoesNotCrossOrigins() {
        val base = "https://example.com/a/master.m3u8?token=abc".toHttpUrl()
        val sameOrigin = UriResolver.resolve("segment.ts", base)
        assertEquals("https://example.com/a/segment.ts", sameOrigin.primary.toString())
        assertEquals(
            "https://example.com/a/segment.ts?token=abc",
            sameOrigin.sameOriginQueryFallback.toString(),
        )

        val crossOrigin = UriResolver.resolve("https://cdn.example/segment.ts", base)
        assertNull(crossOrigin.sameOriginQueryFallback)
    }

    @Test
    fun rejectsUnsupportedSchemesAndUserInfo() {
        assertThrows(HlsException.InvalidUrl::class.java) {
            UriResolver.resolveUrl("data:text/plain,x", "https://example.com/".toHttpUrl())
        }
        assertThrows(HlsException.InvalidUrl::class.java) {
            UriResolver.normalizeInput("https://user:password@example.com/video.m3u8")
        }
    }

    @Test
    fun privateNetworkNavigationPolicyMatchesRootScope() {
        val public = "https://example.com/".toHttpUrl()
        val private = "http://127.0.0.1/video.m3u8".toHttpUrl()
        val otherPublic = "https://cdn.example/video.m3u8".toHttpUrl()
        assertFalse(AutomaticNavigationPolicy.isAllowedFrameNavigation(public, private))
        assertTrue(AutomaticNavigationPolicy.isAllowedFrameNavigation(private, private))
        assertFalse(
            AutomaticNavigationPolicy.isAllowedFrameNavigation(
                public,
                "http://[::ffff:7f00:1]/video.m3u8".toHttpUrl(),
            ),
        )
        assertFalse(
            AutomaticNavigationPolicy.isAllowedFrameNavigation(
                public,
                "http://[::c0a8:101]/video.m3u8".toHttpUrl(),
            ),
        )
        assertFalse(AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(public, otherPublic))
        assertTrue(
            AutomaticNavigationPolicy.isAllowedNativeFrameNavigation(
                public,
                "https://example.com/frame".toHttpUrl(),
            ),
        )
    }
}
