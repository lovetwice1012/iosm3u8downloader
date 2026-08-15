package com.example.hlsdownloader.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HtmlMediaExtractorTest {
    @Test
    fun extractsVideoSourceMetadataInlineUrlsAndFrames() {
        val html = """
            <html><head>
              <base href="/assets/">
              <title> Sample   Video </title>
              <meta property="og:image" content="poster.jpg">
            </head><body>
              <video poster="v.jpg" title="Movie"><source src="stream.m3u8" type="application/vnd.apple.mpegurl"></video>
              <script>const backup = "https:\/\/cdn.example\/fallback.m3u8?token=x";</script>
              <iframe data-src="player/index.html" title="Player"></iframe>
            </body></html>
        """.trimIndent()
        val extraction = HtmlMediaExtractor.extract(html)
        assertEquals("/assets/", extraction.baseHref)
        assertEquals("Sample Video", extraction.title)
        assertEquals("poster.jpg", extraction.rawThumbnailUrl)
        assertTrue(extraction.media.any { it.rawUrl == "stream.m3u8" && it.rawPosterUrl == "v.jpg" })
        assertTrue(extraction.media.any { "fallback.m3u8" in it.rawUrl })
        assertEquals("player/index.html", extraction.frames.single().rawUrl)
    }

    @Test
    fun srcdocIsOnlyParsedAtChildDepthAndIgnoredSrcDoesNotLeak() {
        val html = """
            <iframe srcdoc="&lt;video src='child.m3u8'&gt;&lt;/video&gt;" src="ignored.m3u8"></iframe>
        """.trimIndent()
        val extraction = HtmlMediaExtractor.extract(html)
        assertTrue(extraction.media.isEmpty())
        assertEquals(1, extraction.frames.size)
        assertTrue(extraction.frames.single().sourceDocument.orEmpty().contains("child.m3u8"))
        assertFalse(extraction.frames.single().sourceDocument.orEmpty().contains("ignored.m3u8"))
    }
}
