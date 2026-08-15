package com.example.hlsdownloader.core

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaylistParserTest {
    private val base = "https://media.example/path/master.m3u8?token=abc".toHttpUrl()

    @Test
    fun parsesMasterVariantsAndAlternateAudio() {
        val text = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="日本語",DEFAULT=YES,AUTOSELECT=YES,URI="ja.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,AVERAGE-BANDWIDTH=900000,RESOLUTION=1280x720,AUDIO="audio"
            video.m3u8
        """.trimIndent()
        val master = (PlaylistParser.parse(text, base) as PlaylistKind.Master).playlist
        assertEquals(1, master.variants.size)
        assertEquals(900000, master.variants.single().averageBandwidth)
        assertEquals("audio", master.variants.single().audioGroupId)
        assertEquals("https://media.example/path/video.m3u8", master.variants.single().url.primary.toString())
        assertEquals("https://media.example/path/video.m3u8?token=abc", master.variants.single().url.sameOriginQueryFallback.toString())
        assertTrue(master.renditions.single().isDefault)
    }

    @Test
    fun parsesImplicitByteRangesEncryptionMapAndSequence() {
        val text = """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:42
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="32@4"
            #EXTINF:1.5,
            #EXT-X-BYTERANGE:4@0
            media.bin
            #EXTINF:2,
            #EXT-X-BYTERANGE:4
            media.bin
            #EXT-X-ENDLIST
        """.trimIndent()
        val media = (PlaylistParser.parse(text, base) as PlaylistKind.Media).playlist
        assertTrue(media.hasEndList)
        assertEquals(42uL, media.segments[0].mediaSequence)
        assertEquals(43uL, media.segments[1].mediaSequence)
        assertEquals(ByteRange(0, 4), media.segments[0].byteRange)
        assertEquals(ByteRange(4, 4), media.segments[1].byteRange)
        assertEquals(ByteRange(4, 32), media.segments[0].initializationMap?.byteRange)
        assertEquals(16, media.segments[0].encryption?.explicitIv?.size)
    }

    @Test
    fun rejectsGapUnsupportedDrmAndEncryptedMapWithoutIv() {
        assertThrows(HlsException.GapUnsupported::class.java) {
            PlaylistParser.parse(
                "#EXTM3U\n#EXTINF:1,\n#EXT-X-GAP\na.ts\n#EXT-X-ENDLIST",
                base,
            )
        }
        assertThrows(HlsException.DrmUnsupported::class.java) {
            PlaylistParser.parse(
                "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST",
                base,
            )
        }
        assertThrows(HlsException.InvalidPlaylist::class.java) {
            PlaylistParser.parse(
                "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXT-X-MAP:URI=\"i\"\n#EXTINF:1,\na.m4s\n#EXT-X-ENDLIST",
                base,
            )
        }
    }

    @Test
    fun retainsVodAndDiscontinuitySignalsForPlanValidation() {
        val media = (PlaylistParser.parse(
            "#EXTM3U\n#EXT-X-DISCONTINUITY\n#EXTINF:1,\na.ts",
            base,
        ) as PlaylistKind.Media).playlist
        assertFalse(media.hasEndList)
        assertTrue(media.segments.single().hasDiscontinuity)
        assertNotNull(media.segments.single().url.sameOriginQueryFallback)
    }
}
