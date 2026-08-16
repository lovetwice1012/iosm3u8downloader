package com.example.hlsdownloader.core

import okhttp3.Cookie
import okhttp3.HttpUrl
import okio.ByteString
import java.io.File
import java.util.UUID

enum class DownloadPhase(val title: String) {
    IDLE("待機中"),
    RESOLVING("リンクを解析中"),
    DOWNLOADING("断片をダウンロード中"),
    COMPOSING("MP4に結合中"),
    COMPLETED("完了"),
}

data class DownloadProgress(
    val phase: DownloadPhase,
    val completedItems: Int,
    val totalItems: Int,
) {
    val fraction: Double?
        get() = if (totalItems > 0) {
            (completedItems.toDouble() / totalItems.toDouble()).coerceIn(0.0, 1.0)
        } else {
            null
        }
}

typealias ProgressHandler = suspend (DownloadProgress) -> Unit

data class DownloadResult(
    val outputFile: File,
    val sourceUrl: HttpUrl,
    val segmentCount: Int,
)

data class PlaylistDocument(
    val text: String,
    val effectiveUrl: HttpUrl,
    val referer: HttpUrl?,
)

enum class HlsCandidateOrigin(val title: String) {
    DIRECT("m3u8直接リンク"),
    VIDEO("videoタグ"),
    SOURCE("sourceタグ"),
    INLINE_SCRIPT("ページ内データ"),
    IFRAME("iframeリンク"),
    RUNTIME("プレイヤー通信"),
}

data class UrlCandidates(
    val primary: HttpUrl,
    val sameOriginQueryFallback: HttpUrl? = null,
) {
    val all: List<HttpUrl>
        get() = if (sameOriginQueryFallback != null && sameOriginQueryFallback != primary) {
            listOf(primary, sameOriginQueryFallback)
        } else {
            listOf(primary)
        }
}

data class HlsCandidate(
    val id: String = UUID.randomUUID().toString(),
    val request: UrlCandidates,
    val requestReferer: HttpUrl?,
    val document: PlaylistDocument?,
    val pageUrl: HttpUrl,
    val title: String?,
    val thumbnailUrl: HttpUrl?,
    val iframeDepth: Int,
    val origin: HlsCandidateOrigin,
) {
    val playlistUrl: HttpUrl
        get() = document?.effectiveUrl ?: request.primary
}

data class HlsDiscoveryResult(
    val candidates: List<HlsCandidate>,
    val isDirectPlaylist: Boolean,
)

data class DynamicMediaReference(
    val url: HttpUrl,
    val pageUrl: HttpUrl,
    val requestReferer: HttpUrl? = null,
    val title: String? = null,
    val thumbnailUrl: HttpUrl? = null,
    val iframeDepth: Int = 0,
    val origin: HlsCandidateOrigin = HlsCandidateOrigin.RUNTIME,
)

/**
 * A short-lived cookie copied from WebView for one download attempt. WebView
 * does not expose the original Domain, Path, SameSite or expiry attributes, so
 * the URL at which the cookie header was observed is retained and requests
 * must match its exact scheme, host and port.
 */
data class OriginBoundCookie(
    val origin: HttpUrl,
    val cookie: Cookie,
) {
    fun hasOrigin(url: HttpUrl): Boolean =
        origin.scheme == url.scheme && origin.host == url.host && origin.port == url.port

    fun matches(url: HttpUrl): Boolean = hasOrigin(url) && cookie.matches(url)

    override fun toString(): String =
        "OriginBoundCookie(origin=${origin.scheme}://${origin.host}:${origin.port}, name=${cookie.name})"
}

data class DynamicPageInspection(
    val media: List<DynamicMediaReference>,
    val cookies: List<OriginBoundCookie>,
) {
    companion object {
        val EMPTY = DynamicPageInspection(emptyList(), emptyList())
    }
}

fun interface DynamicPageInspector {
    suspend fun inspect(url: HttpUrl, seedCookies: List<Cookie>): DynamicPageInspection
}

data class ByteRange(
    val offset: Long,
    val length: Long,
)

data class EncryptionDescriptor(
    val method: Method,
    val keyUrl: UrlCandidates,
    val explicitIv: ByteString?,
) {
    enum class Method(val wireValue: String) {
        AES_128("AES-128"),
    }
}

data class InitializationMap(
    val url: UrlCandidates,
    val byteRange: ByteRange?,
    val encryption: EncryptionDescriptor?,
)

data class MediaSegment(
    val ordinal: Int,
    val mediaSequence: ULong,
    val duration: Double,
    val url: UrlCandidates,
    val byteRange: ByteRange?,
    val encryption: EncryptionDescriptor?,
    val initializationMap: InitializationMap?,
    val hasDiscontinuity: Boolean,
)

data class MediaPlaylist(
    val effectiveUrl: HttpUrl,
    val requestReferer: HttpUrl?,
    val segments: List<MediaSegment>,
    val hasEndList: Boolean,
)

data class Variant(
    val url: UrlCandidates,
    val bandwidth: Int,
    val averageBandwidth: Int?,
    val resolution: String?,
    val audioGroupId: String?,
)

data class MediaRendition(
    val type: String,
    val groupId: String,
    val name: String,
    val url: UrlCandidates?,
    val isDefault: Boolean,
    val isAutoSelect: Boolean,
)

data class MasterPlaylist(
    val effectiveUrl: HttpUrl,
    val variants: List<Variant>,
    val renditions: List<MediaRendition>,
)

sealed interface PlaylistKind {
    data class Master(val playlist: MasterPlaylist) : PlaylistKind
    data class Media(val playlist: MediaPlaylist) : PlaylistKind
}

data class DownloadPlan(
    val sourceUrl: HttpUrl,
    val main: MediaPlaylist,
    val audio: MediaPlaylist?,
) {
    val segmentCount: Int
        get() = main.segments.size + (audio?.segments?.size ?: 0)
}

enum class MediaContainer(val displayName: String, val fileExtension: String) {
    TRANSPORT_STREAM("MPEG-TS", "ts"),
    ISO_BASE_MEDIA("fMP4", "mp4"),
    AAC("AAC", "aac"),
    MP3("MP3", "mp3"),
    AC3("AC-3", "ac3"),
    EAC3("E-AC-3", "ec3"),
}

data class DownloadedSegment(
    val source: MediaSegment,
    val file: File,
    val container: MediaContainer,
    val byteCount: Int,
    val initializationDataLength: Int,
)

interface MediaComposer {
    /**
     * Produces a playable MP4 at [outputFile]. Implementations must preserve
     * segment order and relative A/V timing and must be cancellation-aware.
     */
    suspend fun compose(
        main: List<DownloadedSegment>,
        externalAudio: List<DownloadedSegment>?,
        outputFile: File,
    )
}

data class HttpPayload(
    val data: ByteArray,
    val effectiveUrl: HttpUrl,
    val statusCode: Int,
    val mimeType: String?,
)
