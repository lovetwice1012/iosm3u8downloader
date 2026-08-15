package com.example.hlsdownloader.capture

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationSafetyTest {
    private val publicRoot = "https://example.com/watch".toHttpUrl()

    @Test
    fun publicRootCannotNavigateToPrivateOrLocalTargets() {
        listOf(
            "http://localhost/video.m3u8",
            "http://127.0.0.1/video.m3u8",
            "http://10.0.0.5/video.m3u8",
            "http://172.16.0.5/video.m3u8",
            "http://192.168.1.5/video.m3u8",
            "http://169.254.1.1/video.m3u8",
            "http://[::1]/video.m3u8",
            "http://[::ffff:7f00:1]/video.m3u8",
            "http://[::c0a8:101]/video.m3u8",
            "http://device.local/video.m3u8",
        ).forEach { rawTarget ->
            assertFalse(rawTarget, NavigationSafety.isAllowed(publicRoot, rawTarget.toHttpUrl()))
        }
    }

    @Test
    fun publicRootCanNavigateToPublicTarget() {
        assertTrue(
            NavigationSafety.isAllowed(
                publicRoot,
                "https://cdn.example.net/master.m3u8?token=secret".toHttpUrl(),
            ),
        )
    }

    @Test
    fun localRootCanNavigateToLocalTarget() {
        assertTrue(
            NavigationSafety.isAllowed(
                "http://localhost/index.html".toHttpUrl(),
                "http://127.0.0.1/master.m3u8".toHttpUrl(),
            ),
        )
    }
}
