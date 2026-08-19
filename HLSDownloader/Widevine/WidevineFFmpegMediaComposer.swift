import Foundation
import HLSFFmpegBridge

private struct WidevineFFmpegExecutionResult: Sendable {
    let returnCode: Int64
    let diagnostic: String
}

private final class WidevineFFmpegSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(
        video: WidevineEncryptedTrackInput,
        audio: WidevineEncryptedTrackInput?,
        outputURL: URL,
        maximumOutputBytes: Int64
    ) {
        var videoKey = Self.hexCString(video.keyData)
        defer { Self.zero(&videoKey) }
        let created: UnsafeMutableRawPointer?
        if let audio {
            var audioKey = Self.hexCString(audio.keyData)
            defer { Self.zero(&audioKey) }
            created = videoKey.withUnsafeBufferPointer { videoKeyBuffer in
                audioKey.withUnsafeBufferPointer { audioKeyBuffer in
                    video.encryptedFileURL.path.withCString { videoPath in
                        audio.encryptedFileURL.path.withCString { audioPath in
                            outputURL.path.withCString { outputPath in
                                hls_ffmpeg_cenc_session_create(
                                    videoPath,
                                    videoKeyBuffer.baseAddress,
                                    audioPath,
                                    audioKeyBuffer.baseAddress,
                                    outputPath,
                                    maximumOutputBytes
                                )
                            }
                        }
                    }
                }
            }
        } else {
            created = videoKey.withUnsafeBufferPointer { videoKeyBuffer in
                video.encryptedFileURL.path.withCString { videoPath in
                    outputURL.path.withCString { outputPath in
                        hls_ffmpeg_cenc_session_create(
                            videoPath,
                            videoKeyBuffer.baseAddress,
                            nil,
                            nil,
                            outputPath,
                            maximumOutputBytes
                        )
                    }
                }
            }
        }
        guard let created else { return nil }
        handle = created
    }

    func execute() -> WidevineFFmpegExecutionResult {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let returnCode = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        let bytes = diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return WidevineFFmpegExecutionResult(
            returnCode: returnCode,
            diagnostic: String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func cancel() {
        hls_ffmpeg_remux_session_cancel(handle)
    }

    deinit {
        hls_ffmpeg_remux_session_destroy(handle)
    }

    private static func hexCString(_ data: Data) -> [CChar] {
        let digits = Array("0123456789abcdef".utf8)
        var output = [CChar](repeating: 0, count: data.count * 2 + 1)
        for (index, byte) in data.enumerated() {
            output[index * 2] = CChar(bitPattern: digits[Int(byte >> 4)])
            output[index * 2 + 1] = CChar(bitPattern: digits[Int(byte & 0x0F)])
        }
        return output
    }

    private static func zero(_ buffer: inout [CChar]) {
        for index in buffer.indices {
            buffer[index] = 0
        }
    }
}

private final class WidevineFFmpegDecodeValidationSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(inputURL: URL) {
        let created = inputURL.path.withCString {
            hls_ffmpeg_decode_validation_session_create($0)
        }
        guard let created else { return nil }
        handle = created
    }

    func execute() -> WidevineFFmpegExecutionResult {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let returnCode = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        let bytes = diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return WidevineFFmpegExecutionResult(
            returnCode: returnCode,
            diagnostic: String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func cancel() { hls_ffmpeg_remux_session_cancel(handle) }

    deinit { hls_ffmpeg_remux_session_destroy(handle) }
}

/// Final fail-closed gate for already-clear Widevine output. FFprobe metadata
/// must contain the expected stream type, then FFmpeg decodes every selected
/// video/audio sample to the null muxer with fatal error handling. Diagnostics
/// never leave this boundary, so a decoder failure cannot expose key material.
struct LocalMediaDecodeValidator: Sendable {
    func validate(
        inputURL: URL,
        expectedTracks: LocalMediaTrackSet
    ) async throws {
        let allowedTracks: LocalMediaTrackSet = [.audio, .video]
        guard inputURL.isFileURL,
              expectedTracks.rawValue != 0,
              (expectedTracks.rawValue & ~allowedTracks.rawValue) == 0 else {
            throw WidevineProcessingError.invalidOutput
        }
        let values = try inputURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw WidevineProcessingError.invalidOutput
        }

        let actualTracks: LocalMediaTrackSet
        do {
            actualTracks = try await LocalMediaTrackProbe().probe(
                inputURL: inputURL,
                input: .mediaFile()
            )
        } catch let error as HLSError {
            if case .cancelled = error { throw error }
            throw WidevineProcessingError.invalidOutput
        } catch is CancellationError {
            throw HLSError.cancelled
        } catch {
            throw WidevineProcessingError.invalidOutput
        }
        guard actualTracks.intersection(expectedTracks) == expectedTracks else {
            throw WidevineProcessingError.invalidOutput
        }

        try Task.checkCancellation()
        guard let session = WidevineFFmpegDecodeValidationSessionBox(inputURL: inputURL) else {
            throw WidevineProcessingError.invalidOutput
        }
        let worker = Task.detached(priority: .userInitiated) { session.execute() }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            session.cancel()
            worker.cancel()
        }
        guard !Task.isCancelled else { throw HLSError.cancelled }
        guard result.returnCode == 0 else {
            // The bridge has already redacted registered secrets. Do not
            // surface decoder logs or local paths from this final validator.
            throw WidevineProcessingError.invalidOutput
        }
    }
}

typealias WidevineMediaDecodeValidator = LocalMediaDecodeValidator

/// Uses the bundled FFmpeg 8 demuxer to decrypt one CENC/CBCS key per track
/// and mux the selected video/audio streams into a normal MP4 file.
///
/// Key rotation inside one representation is rejected by the DASH planner;
/// video and audio may still use different 16-byte content keys.
struct FFmpegWidevineMediaComposer: WidevineMediaComposing, Sendable {
    let isConfigured = true

    func decryptAndMux(
        video: WidevineEncryptedTrackInput?,
        audio: WidevineEncryptedTrackInput?,
        outputURL: URL
    ) async throws {
        let audioIsValid = try audio.map { try Self.isValidInput($0) } ?? true
        guard outputURL.isFileURL, audioIsValid else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        if video == nil, let audio {
            try await FFmpegAudioWAVComposer().compose(
                inputURL: audio.encryptedFileURL,
                decryptionKey: audio.keyData,
                outputURL: outputURL
            )
            return
        }
        guard let video, try Self.isValidInput(video) else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }

        try Task.checkCancellation()
        let maximumOutputBytes = try LocalFFmpegOutputLimit.maximumBytes(for: outputURL)
        try LocalFFmpegOutputLimit.validateInputFiles(
            [video.encryptedFileURL] + (audio.map { [$0.encryptedFileURL] } ?? []),
            maximumBytes: maximumOutputBytes
        )
        try Self.prepareProtectedOutput(outputURL)
        guard let session = WidevineFFmpegSessionBox(
            video: video,
            audio: audio,
            outputURL: outputURL,
            maximumOutputBytes: maximumOutputBytes
        ) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw WidevineDASHProviderError.invalidMediaOutput
        }

        let worker = Task.detached(priority: .userInitiated) {
            session.execute()
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            session.cancel()
            worker.cancel()
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: outputURL)
            throw HLSError.cancelled
        }
        guard result.returnCode == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            let detail = result.diagnostic.isEmpty
                ? "FFmpeg終了コード \(result.returnCode)"
                : "FFmpeg終了コード \(result.returnCode): \(result.diagnostic)"
            throw HLSError.remuxFailed(detail)
        }

        do {
            try LocalFFmpegOutputLimit.validateCompletedOutput(
                at: outputURL,
                maximumBytes: maximumOutputBytes
            )
            let values = try outputURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            let handle = try FileHandle(forReadingFrom: outputURL)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 4_096) ?? Data()
            guard MediaPayloadInspector.detect(prefix, mimeType: "video/mp4")
                    == .isoBaseMedia else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: outputURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func isValidInput(_ input: WidevineEncryptedTrackInput) throws -> Bool {
        guard input.encryptedFileURL.isFileURL,
              input.keyData.count == 16 else {
            return false
        }
        let values = try input.encryptedFileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private static func prepareProtectedOutput(_ outputURL: URL) throws {
        guard outputURL.isFileURL else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        let fileManager = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            let values = try outputURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
        } else {
            let created = fileManager.createFile(
                atPath: outputURL.path,
                contents: Data(),
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            guard created else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: outputURL.path
        )
    }
}
