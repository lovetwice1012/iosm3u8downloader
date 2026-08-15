package com.example.hlsdownloader.core

import okhttp3.HttpUrl
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale

data class DiagnosticEvent(val category: String, val message: String)
typealias DiagnosticSink = (DiagnosticEvent) -> Unit

class DiagnosticLogStore(
    capacity: Int = 600,
    maximumUtf8Bytes: Int = 256 * 1024,
) {
    private data class Entry(
        val sequence: Int,
        val elapsedNanos: Long,
        val event: DiagnosticEvent,
        val estimatedBytes: Int,
    )

    private val capacity = capacity.coerceAtLeast(50)
    private val maximumUtf8Bytes = maximumUtf8Bytes.coerceAtLeast(16 * 1024)
    private var startedAt = System.nanoTime()
    private var nextSequence = 1
    private val entries = ArrayDeque<Entry>()
    private var storedUtf8Bytes = 0
    private var droppedEntries = 0

    val sink: DiagnosticSink = { record(it) }

    @Synchronized
    fun reset() {
        startedAt = System.nanoTime()
        nextSequence = 1
        entries.clear()
        storedUtf8Bytes = 0
        droppedEntries = 0
    }

    fun record(category: String, message: String) = record(DiagnosticEvent(category, message))

    @Synchronized
    fun record(event: DiagnosticEvent) {
        val category = event.category.take(40).replace('\n', ' ').replace('\r', ' ')
        val message = event.message.take(1200).replace('\n', ' ').replace('\r', ' ')
        val bytes = category.toByteArray().size + message.toByteArray().size + 64
        entries.addLast(
            Entry(
                sequence = nextSequence++,
                elapsedNanos = (System.nanoTime() - startedAt).coerceAtLeast(0),
                event = DiagnosticEvent(category, message),
                estimatedBytes = bytes,
            ),
        )
        storedUtf8Bytes += bytes
        while (entries.size > capacity || storedUtf8Bytes > maximumUtf8Bytes) {
            storedUtf8Bytes -= entries.removeFirst().estimatedBytes
            droppedEntries += 1
        }
    }

    @Synchronized
    fun renderedText(): String = buildString {
        appendLine("HLSDownloader diagnostic log")
        appendLine("Privacy: URLs are fingerprinted; query values, cookies, Referer, HTML and titles are omitted.")
        appendLine("Entries: ${entries.size}, dropped: $droppedEntries")
        entries.forEach { entry ->
            val elapsed = entry.elapsedNanos / 1_000_000_000.0
            appendLine(
                String.format(
                    Locale.US,
                    "%04d +%07.3fs [%s] %s",
                    entry.sequence,
                    elapsed,
                    entry.event.category,
                    entry.event.message,
                ),
            )
        }
    }.trimEnd()
}

object DiagnosticPrivacy {
    private val processSalt = ByteArray(32).also(SecureRandom()::nextBytes)

    fun urlSummary(url: HttpUrl): String {
        val schemeClass = when (url.scheme.lowercase(Locale.US)) {
            "https" -> "https"
            "http" -> "http"
            else -> "other"
        }
        val pathDepth = url.pathSegments.count { it.isNotEmpty() }
        val queryItems = url.querySize
        val extension = url.pathSegments.lastOrNull()?.substringAfterLast('.', "")?.lowercase(Locale.US)
        val extensionClass = when (extension) {
            "m3u8" -> "m3u8"
            "", null -> "none"
            else -> "other"
        }
        val scope = if (AutomaticNavigationPolicy.isPrivateOrLocal(url)) "local" else "public"
        val withoutSecrets = url.newBuilder().username("").password("").query(null).fragment(null).build()
        val digest = MessageDigest.getInstance("SHA-256").run {
            update(processSalt)
            digest(withoutSecrets.toString().toByteArray())
        }
            .take(6)
            .joinToString("") { "%02x".format(it) }
        return "id=$digest scheme=$schemeClass scope=$scope pathDepth=$pathDepth ext=$extensionClass queryItems=$queryItems"
    }

    fun mimeClass(mimeType: String?): String {
        val type = mimeType?.lowercase(Locale.US) ?: return "unknown"
        return when {
            "mpegurl" in type -> "hls"
            "html" in type -> "html"
            type.startsWith("image/") -> "image"
            "json" in type -> "json"
            type.startsWith("video/") || type.startsWith("audio/") -> "media"
            else -> "other"
        }
    }

    fun errorCode(error: Throwable): String = when (error) {
        is HlsException.HttpStatus -> "httpStatus(${error.status})"
        is HlsException -> error.code.name.lowercase(Locale.US)
        is kotlinx.coroutines.CancellationException -> "cancelled"
        else -> error::class.simpleName ?: "error"
    }

    fun errorSummary(error: Throwable): String = when (error) {
        is HlsException.InvalidMediaPayload ->
            "invalidMediaPayload stream=${streamClass(error.stream)} segment=${error.number} " +
                "mime=${mimeClass(error.mimeType)} bytes=${error.byteCount}"
        else -> errorCode(error)
    }

    private fun streamClass(stream: String): String = when (stream.lowercase(Locale.US)) {
        "main", "映像" -> "main"
        "audio", "音声" -> "audio"
        else -> "other"
    }
}
