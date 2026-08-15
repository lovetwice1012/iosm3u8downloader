package com.example.hlsdownloader.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dispatcher
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class InMemoryCookieJar : CookieJar {
    private val cookies = mutableListOf<Cookie>()

    @Synchronized
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val now = System.currentTimeMillis()
        this.cookies.removeAll { existing ->
            existing.expiresAt <= now || cookies.any { incoming -> incoming.sameIdentity(existing) }
        }
        this.cookies += cookies.filter { it.expiresAt > now }
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val now = System.currentTimeMillis()
        cookies.removeAll { it.expiresAt <= now }
        return cookies.filter { it.matches(url) }
    }

    @Synchronized
    fun import(cookies: List<Cookie>) {
        val now = System.currentTimeMillis()
        this.cookies.removeAll { existing ->
            existing.expiresAt <= now || cookies.any { incoming -> incoming.sameIdentity(existing) }
        }
        this.cookies += cookies.filter { it.expiresAt > now }
    }

    private fun Cookie.sameIdentity(other: Cookie): Boolean =
        name == other.name && domain == other.domain && path == other.path
}

class HlsHttpClient(
    builder: OkHttpClient.Builder = OkHttpClient.Builder(),
    private val cookieJar: InMemoryCookieJar = InMemoryCookieJar(),
) {
    companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                "Chrome/124.0 Mobile Safari/537.36 HLSDownloader/1.0"
        const val DEFAULT_MAXIMUM_BYTES = 256 * 1024 * 1024
    }

    private val client: OkHttpClient = builder
        .dispatcher(
            Dispatcher().apply {
                maxRequests = 64
                maxRequestsPerHost = 6
            },
        )
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .followRedirects(false)
        .followSslRedirects(false)
        .cookieJar(cookieJar)
        .build()

    fun cookiesFor(url: HttpUrl): List<Cookie> = cookieJar.loadForRequest(url)

    fun storeCookies(cookies: List<Cookie>) = cookieJar.import(cookies)

    suspend fun fetch(
        candidates: UrlCandidates,
        referer: HttpUrl? = null,
        byteRange: ByteRange? = null,
        maximumBytes: Int = DEFAULT_MAXIMUM_BYTES,
        redirectPolicy: (HttpUrl, HttpUrl) -> Boolean =
            AutomaticNavigationPolicy::isAllowedFrameNavigation,
    ): HttpPayload {
        var lastError: Throwable = HlsException.Network("取得候補がありません")
        candidates.all.forEach { candidate ->
            try {
                return fetch(candidate, referer, byteRange, maximumBytes, redirectPolicy)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error is HlsException.Cancelled) throw error
                lastError = error
            }
        }
        throw lastError
    }

    suspend fun fetch(
        url: HttpUrl,
        referer: HttpUrl? = null,
        byteRange: ByteRange? = null,
        maximumBytes: Int = DEFAULT_MAXIMUM_BYTES,
        redirectPolicy: (HttpUrl, HttpUrl) -> Boolean =
            AutomaticNavigationPolicy::isAllowedFrameNavigation,
    ): HttpPayload {
        require(maximumBytes > 0) { "maximumBytes must be positive" }
        validateRange(byteRange)
        var lastError: Throwable = HlsException.Network("通信に失敗しました")

        repeat(3) { attempt ->
            try {
                val request = Request.Builder()
                    .url(url)
                    .get()
                    .header("User-Agent", USER_AGENT)
                    .header("Accept-Language", "ja,en-US;q=0.8,en;q=0.6")
                    .header("Accept", "*/*")
                    .apply {
                        safeReferer(referer, url)?.let { header("Referer", it) }
                        byteRange?.let {
                            header("Range", "bytes=${it.offset}-${checkedUpperBound(it)}")
                        }
                    }
                    .build()

                val response = executeFollowingRedirects(request, redirectPolicy)
                response.use {
                    val effectiveUrl = it.request.url
                    if (it.code !in 200..299) {
                        val error = HlsException.HttpStatus(it.code, effectiveUrl.host)
                        if (attempt < 2 && shouldRetry(it.code)) {
                            lastError = error
                            delay(500L * (attempt + 1))
                            return@repeat
                        }
                        throw error
                    }
                    val body = it.body ?: throw HlsException.Network("応答本文がありません")
                    val rawData = withContext(Dispatchers.IO) {
                        readLimited(body.contentLength(), maximumBytes) {
                            body.source().read(it, 8_192)
                        }
                    }
                    val data = when {
                        byteRange == null -> rawData
                        it.code == 206 -> {
                            validatePartialResponse(it, rawData.size, byteRange)
                            rawData
                        }
                        it.code == 200 -> sliceRange(rawData, byteRange)
                        else -> throw HlsException.ByteRangeInvalid()
                    }
                    return HttpPayload(
                        data = data,
                        effectiveUrl = effectiveUrl,
                        statusCode = it.code,
                        mimeType = body.contentType()?.toString()?.substringBefore(';'),
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
                if (attempt < 2 && shouldRetry(error)) {
                    delay(500L * (attempt + 1))
                    return@repeat
                }
                throw error
            }
        }
        throw lastError
    }

    suspend fun fetchLimited(
        url: HttpUrl,
        referer: HttpUrl? = null,
        maximumBytes: Int,
    ): HttpPayload = fetch(url, referer, maximumBytes = maximumBytes)

    private suspend fun executeFollowingRedirects(
        initialRequest: Request,
        redirectPolicy: (HttpUrl, HttpUrl) -> Boolean,
    ): Response {
        var request = initialRequest
        repeat(10) {
            val response = client.newCall(request).await()
            if (response.code !in setOf(301, 302, 303, 307, 308)) return response
            val location = response.header("Location")
            val target = location?.let(request.url::resolve)
            response.close()
            if (target == null) throw HlsException.Network("リダイレクト先が不正です")
            if (target.username.isNotEmpty() || target.password.isNotEmpty()) {
                throw HlsException.Network("userinfo付きのリダイレクトを拒否しました")
            }
            if (!redirectPolicy(request.url, target)) {
                throw HlsException.Network("安全でないリダイレクトを拒否しました")
            }
            val previousReferer = request.header("Referer")?.toHttpUrlOrNull()
            request = request.newBuilder()
                .url(target)
                .removeHeader("Referer")
                .apply {
                    safeReferer(previousReferer, target)?.let { header("Referer", it) }
                }
                .build()
        }
        throw HlsException.Network("リダイレクト回数が多すぎます")
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(
            object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }

                override fun onResponse(call: Call, response: Response) {
                    if (continuation.isActive) {
                        continuation.resume(response)
                    } else {
                        response.close()
                    }
                }
            },
        )
    }

    private inline fun readLimited(
        contentLength: Long,
        maximumBytes: Int,
        readInto: (Buffer) -> Long,
    ): ByteArray {
        if (contentLength > maximumBytes) throw HlsException.Network("応答が大きすぎます")
        val buffer = Buffer()
        while (true) {
            val read = readInto(buffer)
            if (read == -1L) break
            if (buffer.size > maximumBytes.toLong()) throw HlsException.Network("応答が大きすぎます")
        }
        return buffer.readByteArray()
    }

    private fun sliceRange(data: ByteArray, range: ByteRange): ByteArray {
        val end = checkedEndExclusive(range)
        if (range.offset > Int.MAX_VALUE || end > data.size.toLong()) {
            throw HlsException.ByteRangeInvalid()
        }
        return data.copyOfRange(range.offset.toInt(), end.toInt())
    }

    private fun validateRange(range: ByteRange?) {
        if (range == null) return
        checkedUpperBound(range)
    }

    private fun checkedEndExclusive(range: ByteRange): Long {
        if (range.offset < 0 || range.length <= 0 || range.offset > Long.MAX_VALUE - range.length) {
            throw HlsException.ByteRangeInvalid()
        }
        return range.offset + range.length
    }

    private fun checkedUpperBound(range: ByteRange): Long = checkedEndExclusive(range) - 1

    private fun validatePartialResponse(response: Response, dataCount: Int, expected: ByteRange) {
        if (expected.length > Int.MAX_VALUE || dataCount != expected.length.toInt()) {
            throw HlsException.ByteRangeInvalid()
        }
        val header = response.header("Content-Range")?.trim()
            ?: throw HlsException.ByteRangeInvalid()
        val match = Regex("(?i)^bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)$").matchEntire(header)
            ?: throw HlsException.ByteRangeInvalid()
        val start = match.groupValues[1].toLongOrNull()
        val end = match.groupValues[2].toLongOrNull()
        val expectedEnd = checkedUpperBound(expected)
        if (start != expected.offset || end != expectedEnd) throw HlsException.ByteRangeInvalid()
        if (match.groupValues[3] != "*") {
            val total = match.groupValues[3].toLongOrNull()
            if (total == null || total <= expectedEnd) throw HlsException.ByteRangeInvalid()
        }
    }

    private fun shouldRetry(status: Int): Boolean = status == 408 || status == 429 || status in 500..599

    private fun shouldRetry(error: Throwable): Boolean = when (error) {
        is HlsException.HttpStatus -> shouldRetry(error.status)
        is IOException -> true
        else -> false
    }

    private fun safeReferer(referer: HttpUrl?, target: HttpUrl): String? {
        if (referer == null) return null
        if (referer.scheme == "https" && target.scheme == "http") return null
        val builder = referer.newBuilder().username("").password("").fragment(null)
        if (!UriResolver.isSameOrigin(referer, target)) {
            builder.encodedPath("/").query(null)
        }
        return builder.build().toString()
    }
}
