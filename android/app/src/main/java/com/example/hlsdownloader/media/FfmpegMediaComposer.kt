package com.example.hlsdownloader.media

import com.example.hlsdownloader.core.DownloadedSegment
import com.example.hlsdownloader.core.HlsException
import com.example.hlsdownloader.core.MediaComposer
import com.example.hlsdownloader.core.MediaContainer
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.coroutines.resume

class FfmpegMediaComposer(
    private val workingDirectory: File,
) : MediaComposer {
    private data class NativeResult(val returnCode: Long, val diagnostic: String)
    private data class PreparedInput(val file: File, val container: MediaContainer)

    override suspend fun compose(
        main: List<DownloadedSegment>,
        externalAudio: List<DownloadedSegment>?,
        outputFile: File,
    ) {
        if (main.isEmpty()) throw HlsException.NoPlayableTracks()
        if (externalAudio != null && externalAudio.isEmpty()) throw HlsException.NoPlayableTracks()
        if (!workingDirectory.exists() && !workingDirectory.mkdirs()) {
            throw HlsException.RemuxFailed("作業フォルダを作成できません。")
        }
        outputFile.parentFile?.let { parent ->
            if (!parent.exists() && !parent.mkdirs()) {
                throw HlsException.RemuxFailed("出力フォルダを作成できません。")
            }
        }

        val preparedMain = prepare(main, "main")
        var preparedAudio: PreparedInput? = null
        val partFile = File(outputFile.parentFile, ".${outputFile.name}.${UUID.randomUUID()}.part.mp4")
        try {
            preparedAudio = externalAudio?.let { prepare(it, "audio") }
            val arguments = buildArguments(preparedMain, preparedAudio, partFile)
            val result = execute(arguments)
            if (result.returnCode != 0L) {
                val diagnostic = sanitizeDiagnostic(
                    result.diagnostic,
                    listOfNotNull(preparedMain.file, preparedAudio?.file, partFile),
                )
                val detail = if (diagnostic.isBlank()) {
                    "FFmpeg終了コード ${result.returnCode}"
                } else {
                    "FFmpeg終了コード ${result.returnCode}: $diagnostic"
                }
                throw HlsException.RemuxFailed(detail)
            }
            validateMp4(partFile)
            installAtomically(partFile, outputFile)
        } catch (error: HlsException) {
            throw error
        } catch (error: Throwable) {
            throw HlsException.RemuxFailed(error.message ?: error::class.java.simpleName, error)
        } finally {
            preparedMain.file.delete()
            preparedAudio?.file?.delete()
            partFile.delete()
        }
    }

    private fun prepare(segments: List<DownloadedSegment>, label: String): PreparedInput {
        val ordered = segments.sortedBy { it.source.ordinal }
        val container = ordered.first().container
        if (ordered.any { it.container != container }) {
            throw HlsException.RemuxFailed("$label の断片形式が途中で変化しています。")
        }
        val initializationMap = ordered.first().source.initializationMap
        val initializationLength = ordered.first().initializationDataLength
        if (
            ordered.any {
                it.source.initializationMap != initializationMap ||
                    it.initializationDataLength != initializationLength
            }
        ) {
            throw HlsException.RemuxFailed(
                "$label のEXT-X-MAPが途中で変化する動画には対応していません。",
            )
        }
        val destination = File(
            workingDirectory,
            "hls-${label}-${UUID.randomUUID()}.${container.fileExtension}",
        )
        try {
            BufferedOutputStream(FileOutputStream(destination)).use { output ->
                ordered.forEachIndexed { index, segment ->
                    if (!segment.file.isFile || segment.file.length() <= 0L) {
                        throw HlsException.RemuxFailed("$label の断片${segment.source.ordinal + 1}がありません。")
                    }
                    copySegment(
                        segment = segment,
                        stripRepeatedPackedAudioId3 = index > 0 && container.isPackedAudio,
                        stripRepeatedInitialization = index > 0,
                        output = output,
                    )
                }
            }
            if (destination.length() <= 0L) throw HlsException.RemuxFailed("$label の連結結果が空です。")
            return PreparedInput(destination, container)
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    private fun copySegment(
        segment: DownloadedSegment,
        stripRepeatedPackedAudioId3: Boolean,
        stripRepeatedInitialization: Boolean,
        output: BufferedOutputStream,
    ) {
        BufferedInputStream(FileInputStream(segment.file)).use { input ->
            var bytesToSkip = if (stripRepeatedInitialization) {
                segment.initializationDataLength.coerceAtLeast(0).toLong()
            } else {
                0L
            }
            if (stripRepeatedPackedAudioId3 && bytesToSkip == 0L) {
                input.mark(10)
                val header = ByteArray(10)
                val read = input.read(header)
                input.reset()
                if (read == header.size && header[0] == 'I'.code.toByte() &&
                    header[1] == 'D'.code.toByte() && header[2] == '3'.code.toByte()
                ) {
                    val payloadSize = ((header[6].toInt() and 0x7f) shl 21) or
                        ((header[7].toInt() and 0x7f) shl 14) or
                        ((header[8].toInt() and 0x7f) shl 7) or
                        (header[9].toInt() and 0x7f)
                    bytesToSkip = 10L + payloadSize.toLong()
                }
            }
            skipFully(input, bytesToSkip)
            input.copyTo(output, DEFAULT_BUFFER_SIZE)
        }
    }

    private fun skipFully(input: BufferedInputStream, byteCount: Long) {
        var remaining = byteCount
        while (remaining > 0L) {
            val skipped = input.skip(remaining)
            if (skipped > 0L) {
                remaining -= skipped
            } else if (input.read() >= 0) {
                remaining--
            } else {
                throw HlsException.RemuxFailed("初期化データの長さが断片サイズを超えています。")
            }
        }
    }

    private fun buildArguments(
        main: PreparedInput,
        audio: PreparedInput?,
        output: File,
    ): Array<String> {
        if (audio == null) {
            return arrayOf(
                "-hide_banner", "-nostdin", "-loglevel", "warning", "-y",
                "-fflags", "+genpts", "-i", main.file.absolutePath,
                "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn",
                "-c", "copy", "-avoid_negative_ts", "make_zero",
                "-movflags", "+faststart", output.absolutePath,
            )
        }

        val arguments = mutableListOf(
            "-hide_banner", "-nostdin", "-loglevel", "warning", "-y",
            "-copyts", "-start_at_zero", "-fflags", "+genpts",
        )
        if (main.container == MediaContainer.TRANSPORT_STREAM) {
            arguments += listOf("-f", "mpegts")
        }
        arguments += listOf("-i", main.file.absolutePath, "-isync", "0", "-fflags", "+genpts")
        if (audio.container == MediaContainer.TRANSPORT_STREAM) {
            arguments += listOf("-f", "mpegts")
        }
        arguments += listOf(
            "-i", audio.file.absolutePath,
            "-map", "0:v:0", "-map", "1:a:0", "-sn", "-dn",
            "-c", "copy", "-movflags", "+faststart", output.absolutePath,
        )
        return arguments.toTypedArray()
    }

    private suspend fun execute(arguments: Array<String>): NativeResult {
        val sessionId = try {
            FfmpegNative.create(arguments)
        } catch (error: UnsatisfiedLinkError) {
            throw HlsException.RemuxFailed("FFmpegライブラリを読み込めません。", error)
        }
        if (sessionId == 0L) throw HlsException.RemuxFailed("FFmpegセッションを開始できません。")

        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation {
                FfmpegNative.cancel(sessionId)
            }
            executor.execute {
                val result = try {
                    val code = FfmpegNative.execute(sessionId)
                    NativeResult(code, if (code == 0L) "" else FfmpegNative.logs(sessionId))
                } catch (error: Throwable) {
                    NativeResult(-1L, error.message ?: error::class.java.simpleName)
                } finally {
                    FfmpegNative.destroy(sessionId)
                }
                if (continuation.isActive) continuation.resume(result)
            }
        }
    }

    private fun validateMp4(file: File) {
        if (!file.isFile || file.length() < 12L) throw HlsException.RemuxFailed("出力が空です。")
        val prefix = ByteArray(64)
        val read = FileInputStream(file).use { it.read(prefix) }
        val hasIsoBox = read >= 8 && (4..minOf(read - 4, 32)).any { offset ->
            prefix[offset] == 'f'.code.toByte() && prefix[offset + 1] == 't'.code.toByte() &&
                prefix[offset + 2] == 'y'.code.toByte() && prefix[offset + 3] == 'p'.code.toByte()
        }
        if (!hasIsoBox) throw HlsException.RemuxFailed("出力が正しいMP4ではありません。")
    }

    private fun installAtomically(source: File, destination: File) {
        destination.delete()
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: Throwable) {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun sanitizeDiagnostic(value: String, files: List<File>): String {
        var sanitized = value
        files.forEach { sanitized = sanitized.replace(it.absolutePath, "<local-file>") }
        return sanitized.trim().takeLast(2_048)
    }

    private val MediaContainer.isPackedAudio: Boolean
        get() = this == MediaContainer.AAC || this == MediaContainer.MP3 ||
            this == MediaContainer.AC3 || this == MediaContainer.EAC3

    private companion object {
        val executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "hls-ffmpeg").apply { isDaemon = true }
        }
    }
}
