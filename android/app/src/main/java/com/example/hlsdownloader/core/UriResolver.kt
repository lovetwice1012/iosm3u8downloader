package com.example.hlsdownloader.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.Locale

object UriResolver {
    private val absoluteHttp = Regex("^https?://", RegexOption.IGNORE_CASE)

    @Throws(HlsException::class)
    fun normalizeInput(input: String): HttpUrl {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) throw HlsException.InvalidUrl()
        val value = if (absoluteHttp.containsMatchIn(trimmed)) trimmed else "https://$trimmed"
        val url = value.toHttpUrlOrNull() ?: throw HlsException.InvalidUrl()
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) throw HlsException.InvalidUrl()
        return url
    }

    @Throws(HlsException::class)
    fun resolve(rawValue: String, relativeTo: HttpUrl): UrlCandidates =
        resolve(rawValue, relativeTo, relativeTo)

    @Throws(HlsException::class)
    fun resolve(
        rawValue: String,
        relativeTo: HttpUrl,
        queryFallbackSource: HttpUrl?,
    ): UrlCandidates {
        val primary = resolveUrl(rawValue, relativeTo)
        val fallback = if (
            primary.encodedQuery == null &&
            queryFallbackSource?.encodedQuery != null &&
            isSameOrigin(primary, queryFallbackSource)
        ) {
            primary.newBuilder().encodedQuery(queryFallbackSource.encodedQuery).build()
        } else {
            null
        }
        return UrlCandidates(primary, fallback)
    }

    @Throws(HlsException::class)
    fun resolveUrl(rawValue: String, relativeTo: HttpUrl): HttpUrl {
        val decoded = decodeEscapes(rawValue).trim(' ', '\t', '\r', '\n', '"', '\'')
        val resolved = relativeTo.resolve(decoded) ?: throw HlsException.InvalidUrl()
        if (resolved.scheme != "http" && resolved.scheme != "https") {
            throw HlsException.UnsupportedScheme()
        }
        if (resolved.username.isNotEmpty() || resolved.password.isNotEmpty()) {
            throw HlsException.InvalidUrl()
        }
        return resolved
    }

    fun decodeEscapes(value: String): String {
        var decoded = value
        repeat(2) {
            val next = decodeJavaScriptEscapePass(decoded)
            decoded = next
            if ('\\' !in next) return@repeat
        }
        return decoded
            .replace("&amp;", "&", ignoreCase = true)
            .replace("&#38;", "&", ignoreCase = true)
            .replace("&#x26;", "&", ignoreCase = true)
            .replace("&quot;", "\"", ignoreCase = true)
            .replace("&#34;", "\"", ignoreCase = true)
            .replace("&#x22;", "\"", ignoreCase = true)
    }

    private fun decodeJavaScriptEscapePass(value: String): String {
        val result = StringBuilder(value.length)
        var index = 0
        while (index < value.length) {
            if (value[index] != '\\' || index + 1 >= value.length) {
                result.append(value[index++])
                continue
            }
            val marker = value[index + 1]
            if (marker == 'u' && index + 5 < value.length) {
                val first = value.substring(index + 2, index + 6).toIntOrNull(16)
                if (first != null) {
                    if (
                        first in 0xD800..0xDBFF && index + 11 < value.length &&
                        value[index + 6] == '\\' && value[index + 7] == 'u'
                    ) {
                        val second = value.substring(index + 8, index + 12).toIntOrNull(16)
                        if (second != null && second in 0xDC00..0xDFFF) {
                            val codePoint = 0x10000 + ((first - 0xD800) shl 10) + (second - 0xDC00)
                            result.appendCodePoint(codePoint)
                            index += 12
                            continue
                        }
                    }
                    if (first !in 0xD800..0xDFFF) {
                        result.append(first.toChar())
                        index += 6
                        continue
                    }
                }
            } else if (marker == 'x' && index + 3 < value.length) {
                val byte = value.substring(index + 2, index + 4).toIntOrNull(16)
                if (byte != null) {
                    result.append(byte.toChar())
                    index += 4
                    continue
                }
            } else if (marker == '/' || marker == '\\' || marker == '"' || marker == '\'') {
                result.append(marker)
                index += 2
                continue
            }
            result.append('\\')
            index += 1
        }
        return result.toString()
    }

    fun isSameOrigin(left: HttpUrl, right: HttpUrl): Boolean =
        left.scheme.equals(right.scheme, ignoreCase = true) &&
            left.host.equals(right.host, ignoreCase = true) &&
            left.port == right.port
}

object AutomaticNavigationPolicy {
    fun isAllowedFrameNavigation(from: HttpUrl, to: HttpUrl): Boolean =
        !isPrivateOrLocal(to) || isPrivateOrLocal(from)

    fun isAllowedNativeFrameNavigation(from: HttpUrl, to: HttpUrl): Boolean =
        isAllowedFrameNavigation(from, to) &&
            (isPrivateOrLocal(from) || UriResolver.isSameOrigin(from, to))

    fun isPrivateOrLocal(url: HttpUrl): Boolean {
        val host = url.host.lowercase(Locale.US).trim('[', ']').trim('.')
        if (host.isEmpty()) return true
        val localSuffixes = listOf(
            "localhost", ".localhost", ".local", ".lan", ".internal",
            ".home", ".home.arpa", ".localdomain",
        )
        if (localSuffixes.any { host == it || host.endsWith(it) }) return true

        if (':' in host) {
            if (
                host == "::" || host == "::1" || host.startsWith("fe8") ||
                host.startsWith("fe9") || host.startsWith("fea") || host.startsWith("feb") ||
                host.startsWith("fc") || host.startsWith("fd") || host.startsWith("ff")
            ) return true
            embeddedIpv4(host)?.let { return isPrivateIpv4(it) }
            return false
        }

        if (host.startsWith("0x")) {
            host.drop(2).toLongOrNull(16)?.let { if (it in 0..0xffffffffL) return isPrivateIpv4(it) }
        }
        if (host.all(Char::isDigit)) {
            host.toLongOrNull()?.let { if (it in 0..0xffffffffL) return isPrivateIpv4(it) }
        }
        if (host.all { it.isDigit() || it == '.' }) return isPrivateIpv4(host)
        if ('.' !in host) return true
        return false
    }

    private fun isPrivateIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (
            parts.size != 4 || parts.any {
                it.isEmpty() || (it.length > 1 && it.startsWith('0')) || it.toIntOrNull() !in 0..255
            }
        ) return true
        return isPrivateIpv4(parts[0].toInt(), parts[1].toInt())
    }

    private fun isPrivateIpv4(value: Long): Boolean =
        isPrivateIpv4(((value shr 24) and 0xff).toInt(), ((value shr 16) and 0xff).toInt())

    private fun embeddedIpv4(host: String): Long? {
        val value = when {
            host.startsWith("::ffff:") -> host.removePrefix("::ffff:")
            host.startsWith("::") -> host.removePrefix("::")
            else -> return null
        }
        if ('.' in value) {
            val parts = value.split('.')
            if (parts.size != 4) return null
            val octets = parts.map { it.toLongOrNull() ?: return null }
            if (octets.any { it !in 0..255 }) return null
            return octets.fold(0L) { result, octet -> (result shl 8) or octet }
        }
        val groups = value.split(':')
        if (groups.size != 2) return null
        val high = groups[0].toLongOrNull(16) ?: return null
        val low = groups[1].toLongOrNull(16) ?: return null
        if (high !in 0..0xffff || low !in 0..0xffff) return null
        return (high shl 16) or low
    }

    private fun isPrivateIpv4(first: Int, second: Int): Boolean = when {
        first == 0 || first == 10 || first == 127 || (first == 169 && second == 254) -> true
        first == 192 && second == 168 -> true
        first == 100 && second in 64..127 -> true
        first == 172 && second in 16..31 -> true
        first == 198 && second in 18..19 -> true
        first == 192 && second in setOf(0, 2) -> true
        first == 198 && second == 51 -> true
        first == 203 && second == 0 -> true
        first >= 224 -> true
        else -> false
    }
}
