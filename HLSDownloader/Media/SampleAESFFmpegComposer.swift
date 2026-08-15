import Foundation
import HLSFFmpegBridge

struct LocalMediaTrackSet: OptionSet, Sendable {
    let rawValue: Int32

    static let audio = LocalMediaTrackSet(rawValue: 1)
    static let video = LocalMediaTrackSet(rawValue: 2)
}

enum LocalMediaProbeInput: Sendable {
    case mediaFile(decryptionKey: Data? = nil)
    case sampleAESPlaylist(diagnosticKeys: [Data])
}

enum SampleAESComposedFormat: String, Equatable, Sendable {
    case mp4
    case wav
}

struct SampleAESFFmpegExecutionSelection: Equatable, Sendable {
    let format: SampleAESComposedFormat
    let primaryPlaylistURL: URL
    let externalAudioPlaylistURL: URL?
}

private struct LocalFFmpegExecutionResult: Sendable {
    let returnCode: Int64
    let diagnostic: String
}

enum LocalFFmpegOutputValidation {
    static func validateMP4(at url: URL) throws {
        let values = try regularFileValues(at: url)
        guard (values.fileSize ?? 0) > 0 else {
            throw HLSError.remuxFailed("FFmpegのMP4出力が空です")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64 * 1_024) ?? Data()
        guard MediaPayloadInspector.detect(prefix, mimeType: "video/mp4") == .isoBaseMedia else {
            throw HLSError.remuxFailed("FFmpeg出力が正しいMP4ではありません")
        }
    }

    static func validatePCM16WAV(at url: URL) throws {
        guard WidevineMediaOutputValidator.isValid(url, format: .wav) else {
            throw HLSError.remuxFailed("WAVが16-bit PCM音声ではありません")
        }
    }

    private static func regularFileValues(at url: URL) throws -> URLResourceValues {
        guard url.isFileURL else {
            throw HLSError.remuxFailed("ローカル出力パスではありません")
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HLSError.remuxFailed("FFmpeg出力が通常ファイルではありません")
        }
        return values
    }

    private static func ascii(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

}

private enum LocalFFmpegFileSafety {
    static func validateRegularInput(_ url: URL) throws {
        guard url.isFileURL else {
            throw HLSError.remuxFailed("ローカル入力パスではありません")
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw HLSError.remuxFailed("入力が通常のメディアファイルではありません")
        }
    }

    static func validateDirectMediaInput(_ url: URL) throws {
        try validateRegularInput(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4_096) ?? Data()
        guard !["HTML", "XML", "JSON", "m3u8"].contains(
            MediaPayloadInspector.signature(prefix)
        ) else {
            throw HLSError.invalidMediaPayload(
                stream: "local",
                number: 1,
                mimeType: nil,
                byteCount: prefix.count,
                signature: MediaPayloadInspector.signature(prefix)
            )
        }
    }

    static func validateSampleAESPlaylist(_ url: URL) throws -> [Data] {
        try validateRegularInput(url)
        guard url.pathExtension.lowercased() == "m3u8" else {
            throw HLSError.remuxFailed("ローカルSAMPLE-AES入力がm3u8ではありません")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 1_048_576 else {
            throw HLSError.remuxFailed("ローカルSAMPLE-AES playlistが大きすぎます")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else {
            throw HLSError.remuxFailed("ローカルSAMPLE-AES playlistが不正です")
        }

        let directory = url.deletingLastPathComponent().standardizedFileURL
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw HLSError.remuxFailed("playlistディレクトリが不正です")
        }

        var keys: [Data] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = AttributeListParser.parse(valueAfterColon(line))
                let method = attributes["METHOD"]?.uppercased() ?? "NONE"
                if method == "NONE" { continue }
                guard method == "SAMPLE-AES",
                      (attributes["KEYFORMAT"] ?? "identity").lowercased() == "identity",
                      let keyName = attributes["URI"] else {
                    throw HLSError.drmUnsupported(method)
                }
                let keyURL = try validateLeafResource(
                    keyName,
                    in: directory,
                    expectedByteCount: 16
                )
                let key = try Data(contentsOf: keyURL, options: .mappedIfSafe)
                guard key.count == 16 else { throw HLSError.invalidAESKey }
                keys.append(key)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = AttributeListParser.parse(valueAfterColon(line))
                guard let name = attributes["URI"] else {
                    throw HLSError.invalidPlaylist("ローカルEXT-X-MAPにURIがありません")
                }
                _ = try validateLeafResource(name, in: directory, expectedByteCount: nil)
            } else if line.hasPrefix("#EXT-X-STREAM-INF:")
                        || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                        || line.hasPrefix("#EXT-X-MEDIA:")
                        || (line.hasPrefix("#") && line.range(
                            of: "URI=",
                            options: [.caseInsensitive]
                        ) != nil) {
                throw HLSError.remuxFailed("ローカルmedia playlistに外部参照があります")
            } else if !line.hasPrefix("#") {
                let resource = try validateLeafResource(
                    line,
                    in: directory,
                    expectedByteCount: nil
                )
                guard resource.pathExtension.lowercased() != "m3u8" else {
                    throw HLSError.remuxFailed("ローカルmaster playlistは使用できません")
                }
            }
        }
        // A selected companion rendition may be clear while the other local
        // playlist is SAMPLE-AES. The composer requires at least one key over
        // the aggregate pair before it starts FFmpeg.
        return Array(Set(keys))
    }

    static func prepareProtectedOutput(_ outputURL: URL) throws {
        guard outputURL.isFileURL else {
            throw HLSError.remuxFailed("ローカル出力パスではありません")
        }
        let fileManager = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw HLSError.remuxFailed("出力ディレクトリが不正です")
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            let values = try outputURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw HLSError.remuxFailed("出力先が通常ファイルではありません")
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
        } else {
            guard fileManager.createFile(
                atPath: outputURL.path,
                contents: Data(),
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            ) else {
                throw HLSError.remuxFailed("保護された出力ファイルを作成できません")
            }
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: outputURL.path
        )
    }

    static func protectCompletedOutput(_ outputURL: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: outputURL.path
        )
    }

    private static func validateLeafResource(
        _ name: String,
        in directory: URL,
        expectedByteCount: Int?
    ) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\") else {
            throw HLSError.remuxFailed("playlist内のローカル参照が不正です")
        }
        let resource = directory.appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
        guard resource.deletingLastPathComponent() == directory else {
            throw HLSError.remuxFailed("playlist参照が作業ディレクトリ外です")
        }
        let values = try resource.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let hasExpectedSize = expectedByteCount.map { values.fileSize == $0 } ?? true
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              hasExpectedSize else {
            throw HLSError.remuxFailed("playlist参照先が不正です")
        }
        if expectedByteCount == 16,
           let protection = try FileManager.default.attributesOfItem(
                atPath: resource.path
           )[.protectionKey] as? FileProtectionType,
           protection != .complete,
           protection != .completeUnlessOpen {
            throw HLSError.remuxFailed("SAMPLE-AES鍵ファイルが保護されていません")
        }
        return resource
    }

    private static func valueAfterColon(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
    }
}

private enum LocalFFmpegSecret {
    static func cString(for data: Data, uppercase: Bool = false) -> [CChar] {
        let digits = Array((uppercase ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
        var output = [CChar](repeating: 0, count: data.count * 2 + 1)
        for (index, byte) in data.enumerated() {
            output[index * 2] = CChar(bitPattern: digits[Int(byte >> 4)])
            output[index * 2 + 1] = CChar(bitPattern: digits[Int(byte & 0x0F)])
        }
        return output
    }

    static func zero(_ buffer: inout [CChar]) {
        for index in buffer.indices { buffer[index] = 0 }
    }

    static func register(_ keys: [Data], on handle: UnsafeMutableRawPointer) -> Bool {
        let unique = Array(Set(keys))
        guard unique.count <= 64, unique.allSatisfy({ $0.count == 16 }) else { return false }
        for key in unique {
            for uppercase in [false, true] {
                var value = cString(for: key, uppercase: uppercase)
                let accepted = value.withUnsafeBufferPointer { buffer in
                    hls_ffmpeg_remux_session_add_diagnostic_secret(handle, buffer.baseAddress)
                }
                zero(&value)
                guard accepted == 1 else { return false }
            }
        }
        return true
    }
}

private final class LocalMediaProbeSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(inputURL: URL, input: LocalMediaProbeInput) {
        let created: UnsafeMutableRawPointer?
        let diagnosticKeys: [Data]
        switch input {
        case .sampleAESPlaylist(let keys):
            diagnosticKeys = keys
            created = inputURL.path.withCString { inputPath in
                hls_ffmpeg_media_probe_session_create(inputPath, nil, 1)
            }
        case .mediaFile(let key):
            diagnosticKeys = key.map { [$0] } ?? []
            if let key {
                var keyValue = LocalFFmpegSecret.cString(for: key)
                defer { LocalFFmpegSecret.zero(&keyValue) }
                created = keyValue.withUnsafeBufferPointer { keyBuffer in
                    inputURL.path.withCString { inputPath in
                        hls_ffmpeg_media_probe_session_create(
                            inputPath,
                            keyBuffer.baseAddress,
                            0
                        )
                    }
                }
            } else {
                created = inputURL.path.withCString { inputPath in
                    hls_ffmpeg_media_probe_session_create(inputPath, nil, 0)
                }
            }
        }
        guard let created else { return nil }
        guard LocalFFmpegSecret.register(diagnosticKeys, on: created) else {
            hls_ffmpeg_remux_session_destroy(created)
            return nil
        }
        handle = created
    }

    func execute() -> (tracks: Int32, diagnostic: String) {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let tracks = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_media_probe_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        return (tracks, Self.string(from: diagnostic))
    }

    func cancel() { hls_ffmpeg_remux_session_cancel(handle) }

    deinit { hls_ffmpeg_remux_session_destroy(handle) }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LocalMediaTrackProbe: Sendable {
    func probe(inputURL: URL, input: LocalMediaProbeInput) async throws -> LocalMediaTrackSet {
        try LocalFFmpegFileSafety.validateRegularInput(inputURL)
        switch input {
        case .mediaFile(let key):
            try LocalFFmpegFileSafety.validateDirectMediaInput(inputURL)
            guard (key?.count ?? 16) == 16 else { throw HLSError.invalidAESKey }
        case .sampleAESPlaylist(let keys):
            guard !keys.isEmpty, keys.allSatisfy({ $0.count == 16 }) else {
                throw HLSError.invalidAESKey
            }
        }
        try Task.checkCancellation()
        guard let session = LocalMediaProbeSessionBox(inputURL: inputURL, input: input) else {
            throw HLSError.remuxFailed("FFprobe処理を開始できません")
        }
        let worker = Task.detached(priority: .userInitiated) { session.execute() }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            session.cancel()
            worker.cancel()
        }
        guard !Task.isCancelled else { throw HLSError.cancelled }
        guard result.tracks > 0 else {
            let detail = result.diagnostic.isEmpty ? "音声・映像trackがありません" : result.diagnostic
            throw HLSError.remuxFailed(detail)
        }
        return LocalMediaTrackSet(rawValue: result.tracks)
    }
}

private final class SampleAESFFmpegSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(
        primaryPlaylistURL: URL,
        externalAudioPlaylistURL: URL?,
        outputURL: URL,
        format: SampleAESComposedFormat,
        diagnosticKeys: [Data]
    ) {
        let mode: Int32 = format == .mp4 ? 0 : 1
        let created: UnsafeMutableRawPointer?
        if let externalAudioPlaylistURL {
            created = primaryPlaylistURL.path.withCString { primaryPath in
                externalAudioPlaylistURL.path.withCString { audioPath in
                    outputURL.path.withCString { outputPath in
                        hls_ffmpeg_sample_aes_session_create(
                            primaryPath,
                            audioPath,
                            outputPath,
                            mode
                        )
                    }
                }
            }
        } else {
            created = primaryPlaylistURL.path.withCString { primaryPath in
                outputURL.path.withCString { outputPath in
                    hls_ffmpeg_sample_aes_session_create(
                        primaryPath,
                        nil,
                        outputPath,
                        mode
                    )
                }
            }
        }
        guard let created else { return nil }
        guard LocalFFmpegSecret.register(diagnosticKeys, on: created) else {
            hls_ffmpeg_remux_session_destroy(created)
            return nil
        }
        handle = created
    }

    func execute() -> LocalFFmpegExecutionResult {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let returnCode = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        let bytes = diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return LocalFFmpegExecutionResult(
            returnCode: returnCode,
            diagnostic: String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func cancel() { hls_ffmpeg_remux_session_cancel(handle) }

    deinit { hls_ffmpeg_remux_session_destroy(handle) }
}

struct SampleAESFFmpegComposer: Sendable {
    private let probe = LocalMediaTrackProbe()

    static func executionSelection(
        primaryPlaylistURL: URL,
        externalAudioPlaylistURL: URL?,
        primaryTracks: LocalMediaTrackSet,
        externalAudioTracks: LocalMediaTrackSet?
    ) throws -> SampleAESFFmpegExecutionSelection {
        if primaryTracks.contains(.video) {
            if externalAudioPlaylistURL != nil,
               externalAudioTracks?.contains(.audio) != true {
                throw HLSError.noPlayableTracks
            }
            return SampleAESFFmpegExecutionSelection(
                format: .mp4,
                primaryPlaylistURL: primaryPlaylistURL,
                externalAudioPlaylistURL: externalAudioPlaylistURL
            )
        }

        if let externalAudioPlaylistURL,
           let externalAudioTracks,
           externalAudioTracks.contains(.audio),
           !externalAudioTracks.contains(.video) {
            return SampleAESFFmpegExecutionSelection(
                format: .wav,
                primaryPlaylistURL: externalAudioPlaylistURL,
                externalAudioPlaylistURL: nil
            )
        }
        guard primaryTracks.contains(.audio) else {
            throw HLSError.noPlayableTracks
        }
        return SampleAESFFmpegExecutionSelection(
            format: .wav,
            primaryPlaylistURL: primaryPlaylistURL,
            externalAudioPlaylistURL: nil
        )
    }

    func compose(
        primaryPlaylistURL: URL,
        externalAudioPlaylistURL: URL? = nil,
        diagnosticKeys: [Data],
        outputURL: URL
    ) async throws -> SampleAESComposedFormat {
        let primaryKeys = try LocalFFmpegFileSafety.validateSampleAESPlaylist(primaryPlaylistURL)
        let audioKeys = try externalAudioPlaylistURL.map {
            try LocalFFmpegFileSafety.validateSampleAESPlaylist($0)
        } ?? []
        let actualKeys = Array(Set(primaryKeys + audioKeys))
        let suppliedKeys = Set(diagnosticKeys)
        guard !actualKeys.isEmpty,
              actualKeys.allSatisfy({ suppliedKeys.contains($0) }) else {
            throw HLSError.invalidAESKey
        }

        let primaryTracks = try await probe.probe(
            inputURL: primaryPlaylistURL,
            input: .sampleAESPlaylist(diagnosticKeys: actualKeys)
        )
        let externalAudioTracks: LocalMediaTrackSet?
        if let externalAudioPlaylistURL {
            externalAudioTracks = try await probe.probe(
                inputURL: externalAudioPlaylistURL,
                input: .sampleAESPlaylist(diagnosticKeys: actualKeys)
            )
        } else {
            externalAudioTracks = nil
        }
        let selection = try Self.executionSelection(
            primaryPlaylistURL: primaryPlaylistURL,
            externalAudioPlaylistURL: externalAudioPlaylistURL,
            primaryTracks: primaryTracks,
            externalAudioTracks: externalAudioTracks
        )

        try Task.checkCancellation()
        try LocalFFmpegFileSafety.prepareProtectedOutput(outputURL)
        guard let session = SampleAESFFmpegSessionBox(
            primaryPlaylistURL: selection.primaryPlaylistURL,
            externalAudioPlaylistURL: selection.externalAudioPlaylistURL,
            outputURL: outputURL,
            format: selection.format,
            diagnosticKeys: actualKeys
        ) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw HLSError.remuxFailed("SAMPLE-AES FFmpeg処理を開始できません")
        }
        let worker = Task.detached(priority: .userInitiated) { session.execute() }
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
            if selection.format == .mp4 {
                try LocalFFmpegOutputValidation.validateMP4(at: outputURL)
            } else {
                try LocalFFmpegOutputValidation.validatePCM16WAV(at: outputURL)
            }
            try LocalFFmpegFileSafety.protectCompletedOutput(outputURL)
            return selection.format
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

private final class AudioWAVFFmpegSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(inputURL: URL, decryptionKey: Data?, outputURL: URL) {
        let created: UnsafeMutableRawPointer?
        if let decryptionKey {
            var key = LocalFFmpegSecret.cString(for: decryptionKey)
            defer { LocalFFmpegSecret.zero(&key) }
            created = key.withUnsafeBufferPointer { keyBuffer in
                inputURL.path.withCString { inputPath in
                    outputURL.path.withCString { outputPath in
                        hls_ffmpeg_audio_wav_session_create(
                            inputPath,
                            keyBuffer.baseAddress,
                            outputPath
                        )
                    }
                }
            }
        } else {
            created = inputURL.path.withCString { inputPath in
                outputURL.path.withCString { outputPath in
                    hls_ffmpeg_audio_wav_session_create(inputPath, nil, outputPath)
                }
            }
        }
        guard let created else { return nil }
        guard LocalFFmpegSecret.register(decryptionKey.map { [$0] } ?? [], on: created) else {
            hls_ffmpeg_remux_session_destroy(created)
            return nil
        }
        handle = created
    }

    func execute() -> LocalFFmpegExecutionResult {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let returnCode = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        let bytes = diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return LocalFFmpegExecutionResult(
            returnCode: returnCode,
            diagnostic: String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func cancel() { hls_ffmpeg_remux_session_cancel(handle) }

    deinit { hls_ffmpeg_remux_session_destroy(handle) }
}

struct FFmpegAudioWAVComposer: Sendable {
    private let probe = LocalMediaTrackProbe()

    func compose(
        inputURL: URL,
        decryptionKey: Data? = nil,
        outputURL: URL
    ) async throws {
        try LocalFFmpegFileSafety.validateDirectMediaInput(inputURL)
        guard (decryptionKey?.count ?? 16) == 16 else { throw HLSError.invalidAESKey }
        let tracks = try await probe.probe(
            inputURL: inputURL,
            input: .mediaFile(decryptionKey: decryptionKey)
        )
        guard tracks.contains(.audio), !tracks.contains(.video) else {
            throw HLSError.noPlayableTracks
        }
        try LocalFFmpegFileSafety.prepareProtectedOutput(outputURL)
        guard let session = AudioWAVFFmpegSessionBox(
            inputURL: inputURL,
            decryptionKey: decryptionKey,
            outputURL: outputURL
        ) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw HLSError.remuxFailed("音声WAV変換を開始できません")
        }
        let worker = Task.detached(priority: .userInitiated) { session.execute() }
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
            try LocalFFmpegOutputValidation.validatePCM16WAV(at: outputURL)
            try LocalFFmpegFileSafety.protectCompletedOutput(outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
