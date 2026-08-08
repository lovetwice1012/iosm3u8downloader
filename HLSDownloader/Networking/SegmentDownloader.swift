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
        var data = try await client.fetch(
            segment.url,
            referer: referer,
            byteRange: segment.byteRange
        ).data

        if let encryption = segment.encryption {
            guard let key = keyData[encryption.keyURL.primary] else { throw HLSError.invalidAESKey }
            let iv = encryption.explicitIV ?? AES128CBCDecryptor.initializationVector(for: segment.mediaSequence)
            data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
        }

        let fileExtension = preferredExtension(for: segment)
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

    private func preferredExtension(for segment: MediaSegment) -> String {
        if segment.initializationMap != nil { return "mp4" }
        let pathExtension = segment.url.primary.pathExtension.lowercased()
        let supported = ["ts", "mp4", "m4s", "aac", "ac3", "ec3", "mp3", "mov"]
        return supported.contains(pathExtension) ? pathExtension : "ts"
    }
}
