import Foundation
import HLSFFmpegBridge

private struct RemuxExecutionResult: Sendable {
    let returnCode: Int64
    let diagnostic: String
}

private final class RemuxSessionBox: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?(inputURL: URL, outputURL: URL, preserveTimestamps: Bool) {
        let created = inputURL.path.withCString { inputPath in
            outputURL.path.withCString { outputPath in
                hls_ffmpeg_remux_session_create(
                    inputPath,
                    outputPath,
                    preserveTimestamps ? 1 : 0
                )
            }
        }
        guard let created else { return nil }
        handle = created
    }

    func execute() -> RemuxExecutionResult {
        var diagnostic = [CChar](repeating: 0, count: 4_096)
        let returnCode = diagnostic.withUnsafeMutableBufferPointer { buffer in
            hls_ffmpeg_remux_session_execute(handle, buffer.baseAddress, buffer.count)
        }
        let bytes = diagnostic.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return RemuxExecutionResult(
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
}

final class TransportStreamRemuxer: @unchecked Sendable {
    func remux(
        inputURL: URL,
        outputURL: URL,
        preserveTimestamps: Bool = false
    ) async throws {
        guard inputURL.isFileURL, outputURL.isFileURL else {
            throw HLSError.remuxFailed("ローカルファイルのパスが不正です")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw HLSError.remuxFailed("MPEG-TS入力ファイルがありません")
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let session = RemuxSessionBox(
            inputURL: inputURL,
            outputURL: outputURL,
            preserveTimestamps: preserveTimestamps
        ) else {
            throw HLSError.remuxFailed("変換処理を開始できません")
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

        if Task.isCancelled {
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
            let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) > 0 else {
                throw HLSError.remuxFailed("出力が空です")
            }
            let handle = try FileHandle(forReadingFrom: outputURL)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 4_096) ?? Data()
            guard MediaPayloadInspector.detect(prefix, mimeType: "video/mp4") == .isoBaseMedia else {
                throw HLSError.remuxFailed("出力が正しいMP4ではありません")
            }
        } catch let error as HLSError {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw HLSError.remuxFailed(error.localizedDescription)
        }
    }
}
