package com.example.hlsdownloader.core

import okhttp3.HttpUrl
import okio.ByteString.Companion.decodeHex
import java.util.Locale

object PlaylistParser {
    @Throws(HlsException::class)
    fun parse(
        text: String,
        effectiveUrl: HttpUrl,
        requestReferer: HttpUrl? = null,
    ): PlaylistKind {
        val normalized = normalize(text)
        if (!normalized.startsWith("#EXTM3U")) {
            throw HlsException.InvalidPlaylist("#EXTM3U がありません")
        }
        if (normalized.lineSequence().any { it == "#EXT-X-I-FRAMES-ONLY" }) {
            throw HlsException.InvalidPlaylist("I-frame専用playlistには対応していません")
        }
        return if ("#EXT-X-STREAM-INF:" in normalized) {
            PlaylistKind.Master(parseMaster(normalized, effectiveUrl))
        } else {
            PlaylistKind.Media(parseMedia(normalized, effectiveUrl, requestReferer))
        }
    }

    fun isPlaylist(text: String): Boolean = normalize(text).startsWith("#EXTM3U")

    private fun parseMaster(text: String, effectiveUrl: HttpUrl): MasterPlaylist {
        val variants = mutableListOf<Variant>()
        val renditions = mutableListOf<MediaRendition>()
        var pendingVariantAttributes: Map<String, String>? = null

        text.lineSequence().forEach { rawLine ->
            val line = rawLine.trim()
            if (line.isEmpty()) return@forEach
            when {
                line.startsWith("#EXT-X-STREAM-INF:") -> {
                    pendingVariantAttributes = AttributeListParser.parse(valueAfterColon(line))
                }
                line.startsWith("#EXT-X-MEDIA:") -> {
                    val attributes = AttributeListParser.parse(valueAfterColon(line))
                    val type = attributes["TYPE"] ?: return@forEach
                    val groupId = attributes["GROUP-ID"] ?: return@forEach
                    renditions += MediaRendition(
                        type = type.uppercase(Locale.US),
                        groupId = groupId,
                        name = attributes["NAME"] ?: groupId,
                        url = attributes["URI"]?.let { UriResolver.resolve(it, effectiveUrl) },
                        isDefault = attributes["DEFAULT"].isYes(),
                        isAutoSelect = attributes["AUTOSELECT"].isYes(),
                    )
                }
                !line.startsWith('#') && pendingVariantAttributes != null -> {
                    val attributes = checkNotNull(pendingVariantAttributes)
                    variants += Variant(
                        url = UriResolver.resolve(line, effectiveUrl),
                        bandwidth = attributes["BANDWIDTH"]?.toIntOrNull() ?: 0,
                        averageBandwidth = attributes["AVERAGE-BANDWIDTH"]?.toIntOrNull(),
                        resolution = attributes["RESOLUTION"],
                        audioGroupId = attributes["AUDIO"],
                    )
                    pendingVariantAttributes = null
                }
            }
        }
        if (variants.isEmpty()) throw HlsException.InvalidPlaylist("画質variantがありません")
        return MasterPlaylist(effectiveUrl, variants, renditions)
    }

    private fun parseMedia(
        text: String,
        effectiveUrl: HttpUrl,
        requestReferer: HttpUrl?,
    ): MediaPlaylist {
        val segments = mutableListOf<MediaSegment>()
        var mediaSequence = 0uL
        var pendingDuration: Double? = null
        var pendingByteRange: ByteRangeSpec? = null
        var previousByteRange: PreviousByteRange? = null
        var currentEncryption: EncryptionDescriptor? = null
        var currentMap: InitializationMap? = null
        var pendingDiscontinuity = false
        var pendingGap = false
        var hasEndList = false

        text.lineSequence().forEach { rawLine ->
            val line = rawLine.trim()
            if (line.isEmpty()) return@forEach
            when {
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> {
                    mediaSequence = valueAfterColon(line).toULongOrNull()
                        ?: throw HlsException.InvalidPlaylist("MEDIA-SEQUENCEが不正です")
                }
                line.startsWith("#EXTINF:") -> {
                    val duration = valueAfterColon(line).substringBefore(',').toDoubleOrNull()
                    if (duration == null || !duration.isFinite() || duration < 0) {
                        throw HlsException.InvalidPlaylist("EXTINFの長さが不正です")
                    }
                    pendingDuration = duration
                }
                line.startsWith("#EXT-X-BYTERANGE:") -> {
                    pendingByteRange = parseByteRangeSpec(valueAfterColon(line))
                }
                line.startsWith("#EXT-X-KEY:") -> {
                    currentEncryption = parseEncryption(line, effectiveUrl)
                }
                line.startsWith("#EXT-X-MAP:") -> {
                    val attributes = AttributeListParser.parse(valueAfterColon(line))
                    val uri = attributes["URI"]
                        ?: throw HlsException.InvalidPlaylist("EXT-X-MAPにURIがありません")
                    val range = attributes["BYTERANGE"]?.let { value ->
                        val parsed = parseByteRangeSpec(value)
                        val offset = parsed.offset ?: throw HlsException.ByteRangeInvalid()
                        makeByteRange(offset, parsed.length)
                    }
                    if (currentEncryption != null && currentEncryption?.explicitIv == null) {
                        throw HlsException.InvalidPlaylist("暗号化されたEXT-X-MAPには明示IVが必要です")
                    }
                    currentMap = InitializationMap(
                        url = UriResolver.resolve(uri, effectiveUrl),
                        byteRange = range,
                        encryption = currentEncryption,
                    )
                }
                line == "#EXT-X-DISCONTINUITY" -> pendingDiscontinuity = true
                line == "#EXT-X-GAP" -> pendingGap = true
                line == "#EXT-X-ENDLIST" -> hasEndList = true
                !line.startsWith('#') -> {
                    if (pendingGap) throw HlsException.GapUnsupported()
                    val duration = pendingDuration
                        ?: throw HlsException.InvalidPlaylist("メディア断片の前にEXTINFがありません")
                    val candidates = UriResolver.resolve(line, effectiveUrl)
                    val range = pendingByteRange?.let { spec ->
                        val offset = spec.offset ?: previousByteRange
                            ?.takeIf { it.url == candidates.primary }
                            ?.endOffset
                            ?: throw HlsException.ByteRangeInvalid()
                        makeByteRange(offset, spec.length).also {
                            previousByteRange = PreviousByteRange(candidates.primary, checkedAdd(it.offset, it.length))
                        }
                    }
                    if (pendingByteRange == null) previousByteRange = null
                    if (mediaSequence > ULong.MAX_VALUE - segments.size.toULong()) {
                        throw HlsException.InvalidPlaylist("MEDIA-SEQUENCEが範囲外です")
                    }
                    segments += MediaSegment(
                        ordinal = segments.size,
                        mediaSequence = mediaSequence + segments.size.toULong(),
                        duration = duration,
                        url = candidates,
                        byteRange = range,
                        encryption = currentEncryption,
                        initializationMap = currentMap,
                        hasDiscontinuity = pendingDiscontinuity,
                    )
                    pendingDuration = null
                    pendingByteRange = null
                    pendingDiscontinuity = false
                    pendingGap = false
                }
            }
        }

        if (segments.isEmpty()) throw HlsException.InvalidPlaylist("メディア断片がありません")
        return MediaPlaylist(effectiveUrl, requestReferer, segments, hasEndList)
    }

    private fun parseEncryption(line: String, effectiveUrl: HttpUrl): EncryptionDescriptor? {
        val attributes = AttributeListParser.parse(valueAfterColon(line))
        val method = attributes["METHOD"]?.uppercase(Locale.US) ?: "NONE"
        if (method == "NONE") return null
        if (method != EncryptionDescriptor.Method.AES_128.wireValue) {
            throw HlsException.DrmUnsupported(method)
        }
        val keyFormat = attributes["KEYFORMAT"] ?: "identity"
        if (!keyFormat.equals("identity", ignoreCase = true)) {
            throw HlsException.DrmUnsupported(keyFormat)
        }
        val uri = attributes["URI"]
            ?: throw HlsException.InvalidPlaylist("EXT-X-KEYにURIがありません")
        return EncryptionDescriptor(
            method = EncryptionDescriptor.Method.AES_128,
            keyUrl = UriResolver.resolve(uri, effectiveUrl),
            explicitIv = attributes["IV"]?.let(::parseIv),
        )
    }

    private fun parseIv(value: String) = value
        .lowercase(Locale.US)
        .removePrefix("0x")
        .let { hex ->
            if (hex.isEmpty() || hex.length > 32 || hex.any { it.digitToIntOrNull(16) == null }) {
                throw HlsException.InvalidPlaylist("AES IVが不正です")
            }
            hex.padStart(32, '0').decodeHex()
        }

    private data class ByteRangeSpec(val length: Long, val offset: Long?)
    private data class PreviousByteRange(val url: HttpUrl, val endOffset: Long)

    private fun parseByteRangeSpec(value: String): ByteRangeSpec {
        val parts = value.trim('"').split('@', limit = 2)
        val length = parts.firstOrNull()?.toLongOrNull()
        if (length == null || length <= 0) throw HlsException.ByteRangeInvalid()
        val offset = if (parts.size == 2) parts[1].toLongOrNull() else null
        if (parts.size == 2 && (offset == null || offset < 0)) throw HlsException.ByteRangeInvalid()
        return ByteRangeSpec(length, offset)
    }

    private fun makeByteRange(offset: Long, length: Long): ByteRange {
        if (offset < 0 || length <= 0) throw HlsException.ByteRangeInvalid()
        checkedAdd(offset, length)
        return ByteRange(offset, length)
    }

    private fun checkedAdd(left: Long, right: Long): Long {
        if (right > 0 && left > Long.MAX_VALUE - right) throw HlsException.ByteRangeInvalid()
        val result = left + right
        if (result <= left) throw HlsException.ByteRangeInvalid()
        return result
    }

    private fun valueAfterColon(line: String): String = line.substringAfter(':', "")

    private fun normalize(text: String): String = text
        .replace("\r\n", "\n")
        .replace('\r', '\n')
        .trim { it.isWhitespace() || it == '\uFEFF' }

    private fun String?.isYes(): Boolean = this?.equals("YES", ignoreCase = true) == true
}
