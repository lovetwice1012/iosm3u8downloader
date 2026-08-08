import Foundation

typealias ProgressHandler = @Sendable (DownloadProgress) async -> Void

final class SegmentDownloader: Sendable {
    private let client: HTTPClient
    private let maximumConcurrentDownloads: Int

    init(client: HTTPClient, maximumConcurrentDownloads: Int = 4) {
        self.client = client
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
    }

    func download(
        playlist: MediaPlaylist,
        prefix: String,
        directory: URL,
        completedBefore: Int,
        totalSegments: Int,
        progress: @escaping ProgressHandler
    ) async throws -> [DownloadedSegment] {
        let requestReferer = playlist.requestReferer ?? playlist.effectiveURL
        let keyData = try await fetchKeys(for: playlist)
        let mapData = try await fetchMaps(for: playlist, keyData: keyData)
        let segments = playlist.segments
        guard !segments.isEmpty else { return [] }

        var results: [DownloadedSegment?] = Array(repeating: nil, count: segments.count)
        var nextIndex = 0
        var completedHere = 0
        let limit = min(maximumConcurrentDownloads, segments.count)

        try await withThrowingTaskGroup(of: (Int, DownloadedSegment).self) { group in
            for _ in 0..<limit {
                let index = nextIndex
                let segment = segments[index]
                nextIndex += 1
                group.addTask { [self] in
                    let downloaded = try await downloadSegment(
                        segment,
                        prefix: prefix,
                        directory: directory,
                        keyData: keyData,
                        mapData: mapData,
                        referer: requestReferer
                    )
                    return (index, downloaded)
                }
            }

            while let (index, downloaded) = try await group.next() {
                results[index] = downloaded
                completedHere += 1
                await progress(
                    DownloadProgress(
                        phase: .downloading,
                        completedItems: completedBefore + completedHere,
                        totalItems: totalSegments
                    )
                )

                if nextIndex < segments.count {
                    let newIndex = nextIndex
                    let segment = segments[newIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        let next = try await downloadSegment(
                            segment,
                            prefix: prefix,
                            directory: directory,
                            keyData: keyData,
                            mapData: mapData,
                            referer: requestReferer
                        )
                        return (newIndex, next)
                    }
                }
            }
        }

        return try results.map {
            guard let value = $0 else { throw HLSError.network("断片の保存結果が不足しています") }
            return value
        }
    }

    private func fetchKeys(for playlist: MediaPlaylist) async throws -> [URL: Data] {
        let descriptors = playlist.segments.flatMap { segment -> [EncryptionDescriptor] in
            var values: [EncryptionDescriptor] = []
            if let encryption = segment.encryption { values.append(encryption) }
            if let encryption = segment.initializationMap?.encryption { values.append(encryption) }
            return values
        }

        var result: [URL: Data] = [:]
        for descriptor in descriptors where result[descriptor.keyURL.primary] == nil {
            let payload = try await client.fetch(
                descriptor.keyURL,
                referer: playlist.requestReferer ?? playlist.effectiveURL
            )
            guard payload.data.count == kCCKeySizeAES128 else { throw HLSError.invalidAESKey }
            result[descriptor.keyURL.primary] = payload.data
        }
        return result
    }

    private func fetchMaps(
        for playlist: MediaPlaylist,
        keyData: [URL: Data]
    ) async throws -> [InitializationMap: Data] {
        let maps = Array(Set(playlist.segments.compactMap(\.initializationMap)))
        var result: [InitializationMap: Data] = [:]

        for map in maps {
            var data = try await client.fetch(
                map.url,
                referer: playlist.requestReferer ?? playlist.effectiveURL,
                byteRange: map.byteRange
            ).data
            if let encryption = map.encryption {
                guard let key = keyData[encryption.keyURL.primary],
                      let iv = encryption.explicitIV else {
                    throw HLSError.invalidAESKey
                }
                data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
            }
            result[map] = data
        }
        return result
    }

    private func downloadSegment(
        _ segment: MediaSegment,
        prefix: String,
        directory: URL,
        keyData: [URL: Data],
        mapData: [InitializationMap: Data],
        referer: URL
    ) async throws -> DownloadedSegment {
        try Task.checkCancellation()
        let response = try await client.fetch(
            segment.url,
            referer: referer,
            byteRange: segment.byteRange
        )
        var data = response.data

        if let encryption = segment.encryption {
            guard let key = keyData[encryption.keyURL.primary] else { throw HLSError.invalidAESKey }
            let iv = encryption.explicitIV ?? AES128CBCDecryptor.initializationVector(for: segment.mediaSequence)
            data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
        }

        let fileExtension = preferredExtension(for: segment, mimeType: response.mimeType, data: data)
        let name = String(format: "%@-%06d.%@", prefix, segment.ordinal, fileExtension)
        let destination = directory.appendingPathComponent(name, isDirectory: false)

        if let map = segment.initializationMap, let initializationData = mapData[map] {
            var combined = Data(capacity: initializationData.count + data.count)
            combined.append(initializationData)
            combined.append(data)
            try combined.write(to: destination, options: .atomic)
        } else {
            try data.write(to: destination, options: .atomic)
        }
        return DownloadedSegment(source: segment, fileURL: destination)
    }

    private func preferredExtension(for segment: MediaSegment, mimeType: String?, data: Data) -> String {
        if segment.initializationMap != nil { return "mp4" }
        let pathExtension = segment.url.primary.pathExtension.lowercased()
        let supported = ["ts", "mp4", "m4s", "aac", "ac3", "ec3", "mp3", "mov"]
        if supported.contains(pathExtension) { return pathExtension }

        switch mimeType?.lowercased() ?? "" {
        case "video/mp2t": return "ts"
        case "video/mp4", "audio/mp4", "video/iso.segment": return "mp4"
        case "audio/aac": return "aac"
        case "audio/mpeg": return "mp3"
        case "audio/ac3": return "ac3"
        case "audio/eac3": return "ec3"
        default: break
        }

        let bytes = [UInt8](data.prefix(4_096))
        if bytes.count >= 189, bytes[0] == 0x47, bytes[188] == 0x47 { return "ts" }
        if bytes.count >= 8 {
            let box = String(bytes: bytes[4..<8], encoding: .ascii)
            if box == "ftyp" || box == "styp" || box == "moof" { return "mp4" }
        }
        if let audioExtension = detectedAudioExtension(in: bytes, at: 0) {
            return audioExtension
        }
        if let id3AudioExtension = detectedAudioExtensionAfterID3(in: bytes) {
            return id3AudioExtension
        }
        return "bin"
    }

    private func detectedAudioExtension(in bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        if bytes[offset] == 0xff, bytes[offset + 1] & 0xf6 == 0xf0 { return "aac" }
        if bytes[offset] == 0x0b, bytes[offset + 1] == 0x77 { return "ac3" }
        if bytes[offset] == 0xff, bytes[offset + 1] & 0xe0 == 0xe0 { return "mp3" }
        return nil
    }

    private func detectedAudioExtensionAfterID3(in bytes: [UInt8]) -> String? {
        guard bytes.count >= 10,
              bytes[0] == 0x49,
              bytes[1] == 0x44,
              bytes[2] == 0x33,
              bytes[6...9].allSatisfy({ $0 & 0x80 == 0 }) else {
            return nil
        }

        let tagSize = (Int(bytes[6]) << 21)
            | (Int(bytes[7]) << 14)
            | (Int(bytes[8]) << 7)
            | Int(bytes[9])
        let hasFooter = bytes[3] == 4 && bytes[5] & 0x10 != 0
        let frameOffset = 10 + tagSize + (hasFooter ? 10 : 0)
        return detectedAudioExtension(in: bytes, at: frameOffset)
    }
}
