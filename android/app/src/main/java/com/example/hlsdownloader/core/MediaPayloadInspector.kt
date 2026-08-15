package com.example.hlsdownloader.core

import java.nio.charset.StandardCharsets
import java.util.Locale

object MediaPayloadInspector {
    private const val MAXIMUM_INSPECTION_BYTES = 262_144

    fun detect(data: ByteArray, mimeType: String? = null): MediaContainer? {
        if (data.isEmpty() || signature(data) in setOf("HTML", "XML", "JSON", "m3u8")) return null
        val bytes = data.copyOfRange(0, minOf(data.size, MAXIMUM_INSPECTION_BYTES))
        if (isTransportStream(bytes)) return MediaContainer.TRANSPORT_STREAM
        if (isIsoBaseMedia(bytes)) return MediaContainer.ISO_BASE_MEDIA
        detectAudio(bytes, 0, mimeType)?.let { return it }
        leadingId3Length(bytes)?.let { offset -> detectAudio(bytes, offset, mimeType)?.let { return it } }
        return null
    }

    fun detectInitialization(data: ByteArray): MediaContainer? {
        if (data.isEmpty() || signature(data) in setOf("HTML", "XML", "JSON", "m3u8")) return null
        val bytes = data.copyOfRange(0, minOf(data.size, MAXIMUM_INSPECTION_BYTES))
        if ("moov" in isoBoxTypes(bytes)) return MediaContainer.ISO_BASE_MEDIA
        val pids = transportPids(bytes)
        if (0 in pids && pids.any { it != 0 && it != 0x1fff }) return MediaContainer.TRANSPORT_STREAM
        return null
    }

    fun isInitializationData(data: ByteArray, container: MediaContainer): Boolean =
        detectInitialization(data) == container

    fun isFragmentWithoutInitialization(data: ByteArray): Boolean {
        val types = isoBoxTypes(data.copyOfRange(0, minOf(data.size, MAXIMUM_INSPECTION_BYTES)))
        return "moof" in types && "moov" !in types
    }

    fun leadingId3Length(bytes: ByteArray): Int? {
        if (
            bytes.size < 10 || bytes[0] != 0x49.toByte() || bytes[1] != 0x44.toByte() ||
            bytes[2] != 0x33.toByte() || (6..9).any { bytes[it].toInt() and 0x80 != 0 }
        ) return null
        val size = ((bytes[6].toInt() and 0x7f) shl 21) or
            ((bytes[7].toInt() and 0x7f) shl 14) or
            ((bytes[8].toInt() and 0x7f) shl 7) or
            (bytes[9].toInt() and 0x7f)
        val hasFooter = bytes[3].toInt() == 4 && bytes[5].toInt() and 0x10 != 0
        val length = 10 + size + if (hasFooter) 10 else 0
        return length.takeIf { it <= bytes.size }
    }

    fun signature(data: ByteArray): String {
        if (data.isEmpty()) return "empty"
        val visible = data.copyOfRange(0, minOf(data.size, 64))
            .toString(StandardCharsets.UTF_8)
            .trim()
            .lowercase(Locale.US)
        return when {
            visible.startsWith("<!doctype") || visible.startsWith("<html") -> "HTML"
            visible.startsWith("<?xml") || visible.startsWith("<error") -> "XML"
            visible.startsWith("#extm3u") -> "m3u8"
            visible.startsWith("{") || visible.startsWith("[") -> "JSON"
            else -> data.take(12).joinToString(" ") { "%02X".format(it.toInt() and 0xff) }
        }
    }

    private fun detectAudio(bytes: ByteArray, offset: Int, mimeType: String?): MediaContainer? {
        if (offset < 0 || offset + 1 >= bytes.size) return null
        if (
            offset + 6 < bytes.size && (bytes[offset].toInt() and 0xff) == 0xff &&
            (bytes[offset + 1].toInt() and 0xf6) == 0xf0
        ) {
            val frameLength = ((bytes[offset + 3].toInt() and 0x03) shl 11) or
                ((bytes[offset + 4].toInt() and 0xff) shl 3) or
                ((bytes[offset + 5].toInt() and 0xff) shr 5)
            if (frameLength >= 7 && offset + frameLength <= bytes.size) return MediaContainer.AAC
        }
        if (
            offset + 5 < bytes.size && (bytes[offset].toInt() and 0xff) == 0x0b &&
            (bytes[offset + 1].toInt() and 0xff) == 0x77
        ) {
            val type = mimeType?.lowercase(Locale.US).orEmpty()
            if ("eac3" in type || "ec3" in type || (bytes[offset + 5].toInt() and 0xff) shr 3 > 10) {
                return MediaContainer.EAC3
            }
            return MediaContainer.AC3
        }
        if (
            offset + 3 < bytes.size && (bytes[offset].toInt() and 0xff) == 0xff &&
            (bytes[offset + 1].toInt() and 0xe0) == 0xe0
        ) {
            val version = (bytes[offset + 1].toInt() shr 3) and 0x03
            val layer = (bytes[offset + 1].toInt() shr 1) and 0x03
            val bitrateIndex = (bytes[offset + 2].toInt() shr 4) and 0x0f
            val sampleRateIndex = (bytes[offset + 2].toInt() shr 2) and 0x03
            if (version != 1 && layer != 0 && bitrateIndex != 0 && bitrateIndex != 0x0f && sampleRateIndex != 3) {
                return MediaContainer.MP3
            }
        }
        return null
    }

    private fun isTransportStream(bytes: ByteArray): Boolean {
        for (packetSize in listOf(188, 192, 204)) {
            if (bytes.isEmpty()) continue
            for (offset in 0..minOf(packetSize - 1, bytes.lastIndex)) {
                if (!isValidTransportHeader(bytes, offset)) continue
                var checked = 1
                var position = offset + packetSize
                while (position < bytes.size && checked < 3 && isValidTransportHeader(bytes, position)) {
                    checked += 1
                    position += packetSize
                }
                if (checked >= 3) return true
            }
        }
        return false
    }

    private fun isValidTransportHeader(bytes: ByteArray, offset: Int): Boolean =
        offset >= 0 && offset + 3 < bytes.size &&
            (bytes[offset].toInt() and 0xff) == 0x47 &&
            bytes[offset + 1].toInt() and 0x80 == 0 &&
            ((bytes[offset + 3].toInt() shr 4) and 0x03) != 0

    private fun transportPids(bytes: ByteArray): Set<Int> {
        var best = emptySet<Int>()
        for (packetSize in listOf(188, 192, 204)) {
            if (bytes.isEmpty()) continue
            for (offset in 0..minOf(packetSize - 1, bytes.lastIndex)) {
                if (!isValidTransportHeader(bytes, offset)) continue
                val pids = mutableSetOf<Int>()
                var position = offset
                while (position + 3 < bytes.size && pids.size < 16 && isValidTransportHeader(bytes, position)) {
                    pids += ((bytes[position + 1].toInt() and 0x1f) shl 8) or
                        (bytes[position + 2].toInt() and 0xff)
                    position += packetSize
                }
                if (0 in pids && pids.any { it != 0 && it != 0x1fff }) return pids
                if (pids.size > best.size) best = pids
            }
        }
        return best
    }

    private fun isIsoBaseMedia(bytes: ByteArray): Boolean =
        isoBoxTypes(bytes).any { it in setOf("ftyp", "styp", "moov", "moof", "sidx") }

    private fun isoBoxTypes(bytes: ByteArray): Set<String> {
        val types = mutableSetOf<String>()
        var offset = 0
        var visited = 0
        while (offset + 8 <= bytes.size && visited < 32) {
            val size32 = readUnsignedInt(bytes, offset)
            val type = bytes.copyOfRange(offset + 4, offset + 8).toString(StandardCharsets.US_ASCII)
            val headerSize: Int
            val boxSize: Long
            when (size32) {
                1L -> {
                    if (offset + 16 > bytes.size) break
                    boxSize = readUnsignedLongAsLong(bytes, offset + 8) ?: break
                    headerSize = 16
                }
                0L -> break
                else -> {
                    boxSize = size32
                    headerSize = 8
                }
            }
            if (boxSize < headerSize || boxSize > Int.MAX_VALUE) break
            val next = offset + boxSize.toInt()
            if (next <= offset || next > bytes.size) break
            val minimum = when (type) {
                "ftyp", "styp" -> 16
                "sidx" -> 12
                else -> headerSize
            }
            if (boxSize >= minimum && type.length == 4) types += type
            offset = next
            visited += 1
        }
        return types
    }

    private fun readUnsignedInt(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)

    private fun readUnsignedLongAsLong(bytes: ByteArray, offset: Int): Long? {
        if (bytes[offset].toInt() and 0x80 != 0) return null
        var value = 0L
        repeat(8) { value = (value shl 8) or (bytes[offset + it].toLong() and 0xff) }
        return value
    }
}
