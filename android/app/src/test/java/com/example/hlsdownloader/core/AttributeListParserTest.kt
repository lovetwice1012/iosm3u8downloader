package com.example.hlsdownloader.core

import org.junit.Assert.assertEquals
import org.junit.Test

class AttributeListParserTest {
    @Test
    fun keepsCommasInsideQuotedValues() {
        val values = AttributeListParser.parse(
            "BANDWIDTH=1200000,CODECS=\"avc1.4d401f,mp4a.40.2\",NAME=\"日本語\"",
        )
        assertEquals("1200000", values["BANDWIDTH"])
        assertEquals("avc1.4d401f,mp4a.40.2", values["CODECS"])
        assertEquals("日本語", values["NAME"])
    }
}
