package com.example.hlsdownloader.capture

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackCookieBridgeTest {
    @Test
    fun derivesConservativeDirectoryPathFromObservedUrl() {
        assertEquals(
            "/video/",
            "https://example.com/video/master.m3u8".toHttpUrl().conservativeCookiePath(),
        )
        assertEquals(
            "/video/",
            "https://example.com/video/".toHttpUrl().conservativeCookiePath(),
        )
        assertEquals(
            "/",
            "https://example.com/master.m3u8".toHttpUrl().conservativeCookiePath(),
        )
    }
}
