package com.example.hlsdownloader.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.atomic.AtomicLong

class SegmentDownloader(
    private val client: HlsHttpClient,
    maximumConcurrentDownloads: Int = 6,
) {
    private val permitPool = Semaphore(maximumConcurrentDownloads.coerceAtLeast(1))
    private val memoryBudget = WeightedMemoryBudget(totalMiB = 128)

    suspend fun download(
        playlist: MediaPlaylist,
        prefix: String,
        directory: File,
        completedBefore: Int = 0,
        totalSegments: Int = playlist.segments.size,
        progress: ProgressHandler = {},
    ): List<DownloadedSegment> {
        directory.mkdirs()
        val referer = playlist.requestReferer ?: playlist.effectiveUrl
        val initializationMaps = playlist.segments.mapNotNull { it.initializationMap }.distinct()
        if (initializationMaps.size > 1) {
            throw HlsException.InvalidPlaylist(
                "途中でEXT-X-MAPが変わる動画には対応していません",
            )
        }
        val keyData = fetchKeys(playlist)
        val mapData = fetchMaps(playlist, initializationMaps, keyData)
        var completedHere = 0
        val progressMutex = Mutex()
        val observedSegmentBytes = AtomicLong(0)
        suspend fun downloadAndReport(segment: MediaSegment, budgetMiB: Int): DownloadedSegment {
            val result = permitPool.withPermit {
                memoryBudget.withBudget(budgetMiB) {
                    downloadSegment(segment, prefix, directory, keyData, mapData, referer)
                }
            }
            observedSegmentBytes.updateAndGet { previous -> maxOf(previous, result.byteCount.toLong()) }
            progressMutex.lock()
            try {
                completedHere += 1
                progress(
                    DownloadProgress(
                        DownloadPhase.DOWNLOADING,
                        completedBefore + completedHere,
                        totalSegments,
                    ),
                )
            } finally {
                progressMutex.unlock()
            }
            return result
        }

        val firstSegment = playlist.segments.firstOrNull() ?: return emptyList()
        val first = downloadAndReport(firstSegment, budgetMiB = 96)
        val remaining = coroutineScope {
            playlist.segments.drop(1).map { segment ->
                async {
                    downloadAndReport(
                        segment,
                        estimatedMemoryMiB(segment, observedSegmentBytes.get()),
                    )
                }
            }.awaitAll()
        }
        return listOf(first) + remaining
    }

    private fun estimatedMemoryMiB(
        segment: MediaSegment,
        observedBytes: Long,
    ): Int {
        if (observedBytes <= 0L) return 64
        val copyFactor = when {
            segment.encryption != null && segment.initializationMap != null -> 3
            segment.encryption != null || segment.initializationMap != null -> 3
            else -> 2
        }
        val estimated = observedBytes.coerceAtMost(Long.MAX_VALUE / copyFactor) * copyFactor
        return ((estimated + MEBIBYTE - 1) / MEBIBYTE).coerceIn(1, 128).toInt()
    }

    private suspend fun fetchKeys(playlist: MediaPlaylist): Map<HttpUrl, ByteArray> {
        val descriptors = playlist.segments.flatMap { segment ->
            listOfNotNull(segment.encryption, segment.initializationMap?.encryption)
        }.distinctBy { it.keyUrl.primary }
        return buildMap {
            descriptors.forEach { descriptor ->
                put(
                    descriptor.keyUrl.primary,
                    fetchKey(descriptor, playlist.requestReferer ?: playlist.effectiveUrl),
                )
            }
        }
    }

    private suspend fun fetchKey(descriptor: EncryptionDescriptor, referer: HttpUrl): ByteArray {
        var lastError: Throwable = HlsException.InvalidAesKey()
        descriptor.keyUrl.all.forEach { candidate ->
            try {
                val data = client.fetch(candidate, referer, maximumBytes = 64 * 1024).data
                if (data.size != 16 || MediaPayloadInspector.signature(data) in setOf("HTML", "XML", "JSON", "m3u8")) {
                    throw HlsException.InvalidAesKey()
                }
                return data
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError
    }

    private suspend fun fetchMaps(
        playlist: MediaPlaylist,
        maps: List<InitializationMap>,
        keyData: Map<HttpUrl, ByteArray>,
    ): Map<InitializationMap, ByteArray> = buildMap {
        maps.forEach { map ->
            put(map, fetchMap(map, keyData, playlist.requestReferer ?: playlist.effectiveUrl))
        }
    }

    private suspend fun fetchMap(
        map: InitializationMap,
        keyData: Map<HttpUrl, ByteArray>,
        referer: HttpUrl,
    ): ByteArray {
        var lastError: Throwable = HlsException.InvalidPlaylist("初期化データを取得できません")
        map.url.all.forEach { candidate ->
            try {
                val response = client.fetch(
                    candidate,
                    referer,
                    map.byteRange,
                    maximumBytes = MAXIMUM_MAP_BYTES,
                )
                val data = map.encryption?.let { encryption ->
                    val key = keyData[encryption.keyUrl.primary] ?: throw HlsException.InvalidAesKey()
                    val iv = encryption.explicitIv?.toByteArray() ?: throw HlsException.InvalidAesKey()
                    Aes128Cbc.decrypt(response.data, key, iv)
                } ?: response.data
                if (MediaPayloadInspector.detectInitialization(data) == null) {
                    throw invalidPayloadError("初期化用", 1, response, data)
                }
                return data
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError
    }

    private suspend fun downloadSegment(
        segment: MediaSegment,
        prefix: String,
        directory: File,
        keyData: Map<HttpUrl, ByteArray>,
        mapData: Map<InitializationMap, ByteArray>,
        referer: HttpUrl,
    ): DownloadedSegment {
        val stream = if (prefix == "audio") "音声" else "映像"
        val media = fetchMedia(segment, keyData, referer, stream)
        val initializationData = segment.initializationMap?.let(mapData::get)
        val finalData = if (initializationData != null) initializationData + media.data else media.data
        val finalContainer = MediaPayloadInspector.detect(finalData, media.response.mimeType)
        if (finalContainer == null || finalContainer != media.container) {
            throw invalidPayloadError(stream, segment.ordinal + 1, media.response, finalData)
        }
        val destination = File(
            directory,
            "%s-%06d.%s".format(prefix, segment.ordinal, finalContainer.fileExtension),
        )
        val temporary = File(directory, destination.name + ".partial")
        withContext(Dispatchers.IO) {
            temporary.writeBytes(finalData)
            try {
                Files.move(
                    temporary.toPath(),
                    destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(
                    temporary.toPath(),
                    destination.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        }
        return DownloadedSegment(
            source = segment,
            file = destination,
            container = finalContainer,
            byteCount = finalData.size,
            initializationDataLength = initializationData?.size ?: 0,
        )
    }

    private data class FetchedMedia(
        val data: ByteArray,
        val response: HttpPayload,
        val container: MediaContainer,
    )

    private suspend fun fetchMedia(
        segment: MediaSegment,
        keyData: Map<HttpUrl, ByteArray>,
        referer: HttpUrl,
        stream: String,
    ): FetchedMedia {
        var lastError: Throwable = HlsException.InvalidPlaylist("断片を取得できません")
        segment.url.all.forEach { candidate ->
            try {
                val response = client.fetch(
                    candidate,
                    referer,
                    segment.byteRange,
                    maximumBytes = MAXIMUM_SEGMENT_BYTES,
                )
                val data = segment.encryption?.let { encryption ->
                    val key = keyData[encryption.keyUrl.primary] ?: throw HlsException.InvalidAesKey()
                    val explicitIv = encryption.explicitIv
                    val iv = if (explicitIv != null) {
                        explicitIv.toByteArray()
                    } else {
                        Aes128Cbc.initializationVector(segment.mediaSequence)
                    }
                    Aes128Cbc.decrypt(response.data, key, iv)
                } ?: response.data
                val container = MediaPayloadInspector.detect(data, response.mimeType)
                    ?: throw invalidPayloadError(stream, segment.ordinal + 1, response, data)
                if (
                    container == MediaContainer.ISO_BASE_MEDIA && segment.initializationMap == null &&
                    !MediaPayloadInspector.isInitializationData(data, container)
                ) {
                    throw HlsException.InvalidPlaylist("fMP4断片に必要なEXT-X-MAPがありません")
                }
                return FetchedMedia(data, response, container)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError
    }

    private fun invalidPayloadError(
        stream: String,
        number: Int,
        response: HttpPayload,
        data: ByteArray,
    ): HlsException.InvalidMediaPayload = HlsException.InvalidMediaPayload(
        stream = stream,
        number = number,
        mimeType = response.mimeType,
        byteCount = data.size,
        signature = MediaPayloadInspector.signature(data),
    )

    private class WeightedMemoryBudget(totalMiB: Int) {
        private val permits = Semaphore(totalMiB.coerceAtLeast(1))
        private val acquisitionMutex = Mutex()

        suspend fun <T> withBudget(requestedMiB: Int, operation: suspend () -> T): T {
            val count = requestedMiB.coerceIn(1, 128)
            var acquired = 0
            try {
                acquisitionMutex.lock()
                try {
                    repeat(count) {
                        permits.acquire()
                        acquired += 1
                    }
                } finally {
                    acquisitionMutex.unlock()
                }
                return operation()
            } finally {
                repeat(acquired) { permits.release() }
            }
        }
    }

    private companion object {
        const val MEBIBYTE = 1024L * 1024L
        const val MAXIMUM_MAP_BYTES = 16 * 1024 * 1024
        const val MAXIMUM_SEGMENT_BYTES = 48 * 1024 * 1024
    }
}
