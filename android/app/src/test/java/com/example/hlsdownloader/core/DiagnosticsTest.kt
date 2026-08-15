package com.example.hlsdownloader.core

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsTest {
    @Test
    fun urlSummaryAndRenderedLogDoNotContainSecrets() {
        val url = "https://secret.example/private/path/video.m3u8?token=TOP-SECRET".toHttpUrl()
        val store = DiagnosticLogStore()
        store.record("network", DiagnosticPrivacy.urlSummary(url))
        store.record("cookie", "cookies=2")
        val rendered = store.renderedText()
        assertFalse(rendered.contains("secret.example"))
        assertFalse(rendered.contains("private/path"))
        assertFalse(rendered.contains("TOP-SECRET"))
        assertTrue(rendered.contains("ext=m3u8"))
    }

    @Test
    fun boundsEntryCountAndLineLengths() {
        val store = DiagnosticLogStore(capacity = 50, maximumUtf8Bytes = 16 * 1024)
        repeat(80) { store.record("x".repeat(100), "m".repeat(2_000)) }
        val rendered = store.renderedText()
        assertTrue(rendered.contains("dropped:"))
        assertFalse(rendered.contains("x".repeat(41)))
    }
}
