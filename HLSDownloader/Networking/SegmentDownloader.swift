import Foundation

typealias ProgressHandler = @Sendable (DownloadProgress) async -> Void

/// A local-only HLS playlist whose media remains SAMPLE-AES encrypted.
///
/// FFmpeg must read the playlist (rather than concatenated media files) so it
/// can apply per-segment METHOD/URI/IV changes. Key bytes are returned only so
/// the bridge can redact them from diagnostics; they are never placed in argv.
struct DownloadedSampleAESPlaylist: Sendable {
    let playlistURL: URL
    let diagnosticKeys: [Data]
    let containsISOBaseMedia: Bool
}

private actor DownloadPermitPool {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor SegmentMediaMemoryBudget {
    struct Claim: Sendable {
        fileprivate let identifier: UUID
        fileprivate let byteCount: Int64
    }

    private struct Waiter {
        let byteCount: Int64
        let continuation: CheckedContinuation<Claim, Never>
    }

    static let maximumInFlightBytes: Int64 = 128 * 1_024 * 1_024
    private(set) var availableBytes: Int64 = maximumInFlightBytes
    private var activeClaims: [UUID: Int64] = [:]
    private var waiters: [Waiter] = []

    func tryClaim(byteCount: Int64) throws -> Claim? {
        try validate(byteCount: byteCount)
        guard byteCount <= availableBytes else { return nil }
        return makeClaim(byteCount: byteCount)
    }

    func acquire(byteCount: Int64) async throws -> Claim {
        try validate(byteCount: byteCount)
        if byteCount <= availableBytes {
            return makeClaim(byteCount: byteCount)
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(byteCount: byteCount, continuation: continuation))
        }
    }

    func release(_ claim: Claim) {
        guard let releasedBytes = activeClaims.removeValue(forKey: claim.identifier),
              releasedBytes == claim.byteCount,
              availableBytes <= Self.maximumInFlightBytes - releasedBytes else {
            return
        }
        availableBytes += releasedBytes

        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard waiter.byteCount <= availableBytes else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            waiter.continuation.resume(returning: makeClaim(byteCount: waiter.byteCount))
        }
    }

    private func validate(byteCount: Int64) throws {
        guard byteCount > 0, byteCount <= Self.maximumInFlightBytes else {
            throw HLSError.network("invalid segment memory reservation")
        }
    }

    private func makeClaim(byteCount: Int64) -> Claim {
        let claim = Claim(identifier: UUID(), byteCount: byteCount)
        availableBytes -= byteCount
        activeClaims[claim.identifier] = byteCount
        return claim
    }
}

private actor SegmentStorageBudget {
    struct Claim: Sendable {
        let directoryPath: String
        let byteCount: Int64
    }

    private var remainingByDirectory: [String: Int64] = [:]

    func claim(byteCount: Int, in directory: URL) throws -> Claim {
        guard byteCount > 0, directory.isFileURL else {
            throw HLSError.network("invalid segment storage request")
        }
        let normalized = directory.standardizedFileURL
        let key = normalized.path
        if remainingByDirectory[key] == nil {
            if remainingByDirectory.count >= 64 {
                remainingByDirectory = remainingByDirectory.filter {
                    FileManager.default.fileExists(atPath: $0.key)
                }
            }
            let probe = normalized.appendingPathComponent(".segment-storage-budget")
            remainingByDirectory[key] = try LocalFFmpegOutputLimit.maximumBytes(for: probe)
        }
        guard let remaining = remainingByDirectory[key] else {
            throw HLSError.network("segment storage budget is unavailable")
        }
        let requested = Int64(byteCount)
        guard requested < remaining else {
            throw HLSError.network("downloaded media exceeds the job storage budget")
        }
        remainingByDirectory[key] = remaining - requested
        return Claim(directoryPath: key, byteCount: requested)
    }

    func release(_ claim: Claim) {
        guard let remaining = remainingByDirectory[claim.directoryPath],
              claim.byteCount > 0,
              remaining <= Int64.max - claim.byteCount else { return }
        remainingByDirectory[claim.directoryPath] = remaining + claim.byteCount
    }
}

struct InitializationMapMemoryBudget {
    static let maximumMapCount = 64
    static let maximumSingleMapBytes: Int64 = 8 * 1_024 * 1_024
    static let maximumAggregateBytes: Int64 = 64 * 1_024 * 1_024

    private(set) var committedMapCount = 0
    private(set) var committedBytes: Int64 = 0

    func maximumBytesForNextMap() throws -> Int64 {
        guard committedMapCount < Self.maximumMapCount,
              committedBytes < Self.maximumAggregateBytes else {
            throw HLSError.invalidPlaylist("initialization map budget exceeded")
        }
        return min(
            Self.maximumSingleMapBytes,
            Self.maximumAggregateBytes - committedBytes
        )
    }

    mutating func commit(byteCount: Int, reservedMaximumBytes: Int64) throws {
        let actual = Int64(byteCount)
        guard actual > 0,
              actual <= reservedMaximumBytes,
              committedMapCount < Self.maximumMapCount,
              committedBytes <= Self.maximumAggregateBytes - actual else {
            throw HLSError.invalidPlaylist("initialization map budget exceeded")
        }
        committedBytes += actual
        committedMapCount += 1
    }
}

final class SegmentDownloader: Sendable {
    private static let maximumMediaResponseBytes: Int64 = 32 * 1_024 * 1_024
    // The encrypted path can briefly retain both the HTTP body and decrypted
    // bytes. fMP4 initialization data is written separately and is never
    // concatenated into another in-memory Data value.
    private static let mediaTaskMemoryReservationBytes: Int64 = 64 * 1_024 * 1_024

    private let client: HTTPClient
    private let maximumConcurrentDownloads: Int
    private let permitPool: DownloadPermitPool
    private let mediaMemoryBudget = SegmentMediaMemoryBudget()
    private let storageBudget = SegmentStorageBudget()

    init(client: HTTPClient, maximumConcurrentDownloads: Int = 6) {
        self.client = client
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        permitPool = DownloadPermitPool(limit: max(1, maximumConcurrentDownloads))
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
                    let downloaded = try await downloadSegmentWithPermit(
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
                if nextIndex < segments.count {
                    let newIndex = nextIndex
                    let segment = segments[newIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        let next = try await downloadSegmentWithPermit(
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
                await progress(
                    DownloadProgress(
                        phase: .downloading,
                        completedItems: completedBefore + completedHere,
                        totalItems: totalSegments
                    )
                )
            }
        }

        return try results.map {
            guard let value = $0 else { throw HLSError.network("断片の保存結果が不足しています") }
            return value
        }
    }

    /// Downloads an identity SAMPLE-AES media playlist without decrypting its
    /// samples and rewrites it as a protected, local-only playlist for FFmpeg.
    /// Clear intervals introduced by METHOD=NONE and TS key rotation are
    /// retained. fMP4 key rotation is rejected after container validation.
    func downloadSampleAESPlaylist(
        playlist: MediaPlaylist,
        requestedPlaylistURL: URL,
        prefix: String,
        directory: URL,
        completedBefore: Int,
        totalSegments: Int,
        progress: @escaping ProgressHandler
    ) async throws -> DownloadedSampleAESPlaylist {
        try validateSampleAESPlaylistPermit(
            requestedURL: requestedPlaylistURL,
            effectiveURL: playlist.effectiveURL
        )
        let descriptors = try sampleAESDescriptors(in: playlist)

        let requestReferer = playlist.requestReferer ?? playlist.effectiveURL
        let keyMaterials = try await fetchSampleAESKeys(
            descriptors,
            referer: requestReferer,
            directory: directory,
            prefix: prefix
        )
        let maps = try await fetchSampleAESMaps(
            for: playlist,
            referer: requestReferer,
            directory: directory,
            prefix: prefix
        )

        let segments = playlist.segments
        guard !segments.isEmpty else {
            throw HLSError.invalidPlaylist("SAMPLE-AES playlist has no media segments")
        }
        var results: [SampleAESLocalSegment?] = Array(repeating: nil, count: segments.count)
        var nextIndex = 0
        var completedHere = 0
        let limit = min(maximumConcurrentDownloads, segments.count)

        try await withThrowingTaskGroup(of: (Int, SampleAESLocalSegment).self) { group in
            for _ in 0..<limit {
                let index = nextIndex
                let segment = segments[index]
                nextIndex += 1
                group.addTask { [self] in
                    let downloaded = try await downloadSampleAESMediaWithPermit(
                        segment,
                        prefix: prefix,
                        directory: directory,
                        referer: requestReferer,
                        playlistURL: playlist.effectiveURL
                    )
                    return (index, downloaded)
                }
            }

            while let (index, downloaded) = try await group.next() {
                results[index] = downloaded
                completedHere += 1
                if nextIndex < segments.count {
                    let newIndex = nextIndex
                    let segment = segments[newIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        let next = try await downloadSampleAESMediaWithPermit(
                            segment,
                            prefix: prefix,
                            directory: directory,
                            referer: requestReferer,
                            playlistURL: playlist.effectiveURL
                        )
                        return (newIndex, next)
                    }
                }
                await progress(
                    DownloadProgress(
                        phase: .downloading,
                        completedItems: completedBefore + completedHere,
                        totalItems: totalSegments
                    )
                )
            }
        }

        let downloadedSegments = try results.map { value -> SampleAESLocalSegment in
            guard let value else {
                throw HLSError.network("SAMPLE-AES segment result is missing")
            }
            return value
        }
        let containsISOBaseMedia = downloadedSegments.contains {
            $0.container == .isoBaseMedia
        } || maps.values.contains {
            $0.container == .isoBaseMedia
        }
        if containsISOBaseMedia, !descriptors.isEmpty {
            let encryptedKeyURLs = Set(descriptors.map(\.keyURL))
            let hasClearIntervals = playlist.segments.contains { $0.encryption == nil }
            guard encryptedKeyURLs.count == 1, !hasClearIntervals else {
                throw HLSError.drmUnsupported("SAMPLE-AES fMP4 key rotation")
            }
        }

        // Recheck after all redirects and before handing protected local paths
        // to the decrypting composer.
        try validateSampleAESPlaylistPermit(
            requestedURL: requestedPlaylistURL,
            effectiveURL: playlist.effectiveURL
        )
        let playlistURL = directory.appendingPathComponent(
            "\(prefix)-sample-aes.m3u8",
            isDirectory: false
        )
        let localText = try makeSampleAESLocalPlaylist(
            playlist: playlist,
            keyMaterials: keyMaterials,
            maps: maps,
            segments: downloadedSegments
        )
        try await writeProtected(Data(localText.utf8), to: playlistURL)
        return DownloadedSampleAESPlaylist(
            playlistURL: playlistURL,
            diagnosticKeys: keyMaterials.values
                .sorted { $0.fileName < $1.fileName }
                .map(\.data),
            containsISOBaseMedia: containsISOBaseMedia
        )
    }

    private struct SampleAESKeyMaterial: Sendable {
        let data: Data
        let fileName: String
    }

    private struct SampleAESLocalMap: Sendable {
        let fileName: String
        let container: MediaContainer
    }

    private struct SampleAESLocalSegment: Sendable {
        let fileName: String
        let container: MediaContainer
    }

    private func sampleAESDescriptors(
        in playlist: MediaPlaylist
    ) throws -> Set<EncryptionDescriptor> {
        var result = Set<EncryptionDescriptor>()
        for segment in playlist.segments {
            if let encryption = segment.encryption {
                guard encryption.method == .sampleAES else {
                    throw HLSError.drmUnsupported("mixed AES-128 and SAMPLE-AES")
                }
                result.insert(encryption)
            }
            if let encryption = segment.initializationMap?.encryption {
                guard encryption.method == .sampleAES else {
                    throw HLSError.drmUnsupported("mixed AES-128 and SAMPLE-AES map")
                }
                result.insert(encryption)
            }
        }
        return result
    }

    private func fetchSampleAESKeys(
        _ descriptors: Set<EncryptionDescriptor>,
        referer: URL,
        directory: URL,
        prefix: String
    ) async throws -> [URLCandidates: SampleAESKeyMaterial] {
        let uniqueURLs = Set(descriptors.map(\.keyURL)).sorted {
            $0.primary.absoluteString < $1.primary.absoluteString
        }
        var result: [URLCandidates: SampleAESKeyMaterial] = [:]
        for (index, keyURL) in uniqueURLs.enumerated() {
            guard keyURL.all.allSatisfy({ isSafeSampleAESResourceURL($0, from: referer) }) else {
                throw HLSError.drmUnsupported("SAMPLE-AES key URL must be secure")
            }
            var lastError: Error = HLSError.invalidAESKey
            var accepted: Data?
            for candidate in keyURL.all {
                do {
                    let payload = try await client.fetch(candidate, referer: referer)
                    guard isSafeSampleAESResourceURL(payload.effectiveURL, from: candidate),
                          payload.data.count == kCCKeySizeAES128,
                          !["HTML", "XML", "JSON", "m3u8"].contains(
                              MediaPayloadInspector.signature(payload.data)
                          ) else {
                        throw HLSError.invalidAESKey
                    }
                    accepted = payload.data
                    break
                } catch is CancellationError {
                    throw HLSError.cancelled
                } catch let error as HLSError {
                    if case .cancelled = error { throw error }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
            guard let data = accepted else { throw lastError }
            let fileName = String(format: "%@-key-%03d.key", prefix, index)
            try await writeProtected(
                data,
                to: directory.appendingPathComponent(fileName, isDirectory: false)
            )
            result[keyURL] = SampleAESKeyMaterial(data: data, fileName: fileName)
        }
        return result
    }

    private func fetchSampleAESMaps(
        for playlist: MediaPlaylist,
        referer: URL,
        directory: URL,
        prefix: String
    ) async throws -> [InitializationMap: SampleAESLocalMap] {
        let uniqueMaps = Array(Set(playlist.segments.compactMap(\.initializationMap)))
            .sorted { $0.url.primary.absoluteString < $1.url.primary.absoluteString }
        guard uniqueMaps.count <= InitializationMapMemoryBudget.maximumMapCount else {
            throw HLSError.invalidPlaylist("too many SAMPLE-AES initialization maps")
        }
        var result: [InitializationMap: SampleAESLocalMap] = [:]
        for (index, map) in uniqueMaps.enumerated() {
            guard map.url.all.allSatisfy({ isSafeSampleAESResourceURL($0, from: playlist.effectiveURL) }) else {
                throw HLSError.invalidPlaylist("SAMPLE-AES initialization URL must be secure")
            }
            var lastError: Error = HLSError.invalidPlaylist(
                "SAMPLE-AES initialization data could not be downloaded"
            )
            var accepted: (Data, MediaContainer)?
            for candidate in map.url.all {
                do {
                    let response = try await client.fetch(
                        candidate,
                        referer: referer,
                        byteRange: map.byteRange,
                        maximumBytes: InitializationMapMemoryBudget.maximumSingleMapBytes
                    )
                    guard isSafeSampleAESResourceURL(response.effectiveURL, from: candidate),
                          let container = MediaPayloadInspector.detectInitialization(response.data) else {
                        throw HLSError.invalidPlaylist("invalid SAMPLE-AES initialization data")
                    }
                    accepted = (response.data, container)
                    break
                } catch is CancellationError {
                    throw HLSError.cancelled
                } catch let error as HLSError {
                    if case .cancelled = error { throw error }
                    lastError = error
                } catch {
                    lastError = error
                }
            }
            guard let (data, container) = accepted else { throw lastError }
            let fileName = String(
                format: "%@-map-%03d.%@",
                prefix,
                index,
                container.fileExtension
            )
            try await writeProtected(
                data,
                to: directory.appendingPathComponent(fileName, isDirectory: false)
            )
            result[map] = SampleAESLocalMap(fileName: fileName, container: container)
        }
        return result
    }

    private func downloadSampleAESMediaWithPermit(
        _ segment: MediaSegment,
        prefix: String,
        directory: URL,
        referer: URL,
        playlistURL: URL
    ) async throws -> SampleAESLocalSegment {
        let memoryClaim = try await mediaMemoryBudget.acquire(
            byteCount: Self.mediaTaskMemoryReservationBytes
        )
        await permitPool.acquire()
        do {
            let result = try await downloadSampleAESMedia(
                segment,
                prefix: prefix,
                directory: directory,
                referer: referer,
                playlistURL: playlistURL
            )
            await permitPool.release()
            await mediaMemoryBudget.release(memoryClaim)
            return result
        } catch {
            await permitPool.release()
            await mediaMemoryBudget.release(memoryClaim)
            throw error
        }
    }

    private func downloadSampleAESMedia(
        _ segment: MediaSegment,
        prefix: String,
        directory: URL,
        referer: URL,
        playlistURL: URL
    ) async throws -> SampleAESLocalSegment {
        guard segment.url.all.allSatisfy({ isSafeSampleAESResourceURL($0, from: playlistURL) }) else {
            throw HLSError.invalidPlaylist("SAMPLE-AES segment URL must be secure")
        }
        var lastError: Error = HLSError.invalidPlaylist("SAMPLE-AES segment could not be downloaded")
        for candidate in segment.url.all {
            do {
                let response = try await client.fetch(
                    candidate,
                    referer: referer,
                    byteRange: segment.byteRange,
                    maximumBytes: Self.maximumMediaResponseBytes
                )
                guard isSafeSampleAESResourceURL(response.effectiveURL, from: candidate),
                      let container = MediaPayloadInspector.detect(
                          response.data,
                          mimeType: response.mimeType
                      ) else {
                    throw invalidPayloadError(
                        stream: prefix == "audio" ? "audio" : "main",
                        number: segment.ordinal + 1,
                        response: response,
                        data: response.data
                    )
                }
                let fileName = String(
                    format: "%@-encrypted-%06d.%@",
                    prefix,
                    segment.ordinal,
                    container.fileExtension
                )
                try await writeProtected(
                    response.data,
                    to: directory.appendingPathComponent(fileName, isDirectory: false)
                )
                return SampleAESLocalSegment(fileName: fileName, container: container)
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func makeSampleAESLocalPlaylist(
        playlist: MediaPlaylist,
        keyMaterials: [URLCandidates: SampleAESKeyMaterial],
        maps: [InitializationMap: SampleAESLocalMap],
        segments: [SampleAESLocalSegment]
    ) throws -> String {
        guard playlist.segments.count == segments.count else {
            throw HLSError.invalidPlaylist("SAMPLE-AES local segment count mismatch")
        }
        let maximumDuration = playlist.segments.map(\.duration).max() ?? 1
        let targetDuration = max(1, Int(ceil(maximumDuration)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(playlist.segments.first?.mediaSequence ?? 0)"
        ]
        var activeEncryption: EncryptionDescriptor?
        var activeMap: InitializationMap?

        func appendEncryption(_ encryption: EncryptionDescriptor?) throws {
            guard activeEncryption != encryption else { return }
            if let encryption {
                guard encryption.method == .sampleAES,
                      let material = keyMaterials[encryption.keyURL] else {
                    throw HLSError.invalidAESKey
                }
                var tag = "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"\(material.fileName)\",KEYFORMAT=\"identity\""
                if let iv = encryption.explicitIV {
                    tag += ",IV=0x" + iv.map { String(format: "%02X", $0) }.joined()
                }
                lines.append(tag)
            } else if activeEncryption != nil {
                lines.append("#EXT-X-KEY:METHOD=NONE")
            }
            activeEncryption = encryption
        }

        for (index, source) in playlist.segments.enumerated() {
            if source.initializationMap != activeMap {
                guard !(source.initializationMap == nil && activeMap != nil) else {
                    throw HLSError.invalidPlaylist("SAMPLE-AES EXT-X-MAP cannot be removed mid-playlist")
                }
                if let map = source.initializationMap {
                    try appendEncryption(map.encryption ?? source.encryption)
                    guard let localMap = maps[map] else {
                        throw HLSError.invalidPlaylist("SAMPLE-AES local initialization data is missing")
                    }
                    lines.append("#EXT-X-MAP:URI=\"\(localMap.fileName)\"")
                }
                activeMap = source.initializationMap
            }
            try appendEncryption(source.encryption)
            let duration = String(
                format: "%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                source.duration
            )
            lines.append("#EXTINF:\(duration),")
            lines.append(segments[index].fileName)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private func validateSampleAESPlaylistPermit(
        requestedURL: URL,
        effectiveURL: URL
    ) throws {
        guard isDownloadableWidevineDomain(requestedURL),
              isDownloadableWidevineDomain(effectiveURL) else {
            throw HLSError.drmUnsupported("SAMPLE-AES download domain not allowed")
        }
    }

    private func isSafeSampleAESResourceURL(_ url: URL, from sourceURL: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return AutomaticNavigationPolicy.isAllowedFrameNavigation(from: sourceURL, to: url)
    }

    private func writeProtected(
        _ data: Data,
        initializationData: Data? = nil,
        to destination: URL
    ) async throws {
        guard destination.isFileURL else { throw HLSError.network("invalid local output URL") }
        let parts = initializationData.map { [$0, data] } ?? [data]
        var totalByteCount = 0
        for part in parts {
            guard !part.isEmpty, part.count <= Int.max - totalByteCount else {
                throw HLSError.network("invalid protected output size")
            }
            totalByteCount += part.count
        }
        guard totalByteCount > 0 else { throw HLSError.network("protected output is empty") }
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              !fileManager.fileExists(atPath: destination.path) else {
            throw HLSError.network("protected local output path is invalid")
        }
        let claim = try await storageBudget.claim(byteCount: totalByteCount, in: parent)
        guard fileManager.createFile(
            atPath: destination.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            await storageBudget.release(claim)
            throw HLSError.network("protected local file could not be created")
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            for part in parts {
                try handle.write(contentsOf: part)
            }
            try handle.synchronize()
            let actualOffset = try handle.offset()
            guard actualOffset == UInt64(totalByteCount) else {
                throw HLSError.network("protected output size mismatch")
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            await storageBudget.release(claim)
            throw error
        }
    }

    private func downloadSegmentWithPermit(
        _ segment: MediaSegment,
        prefix: String,
        directory: URL,
        keyData: [URL: Data],
        mapData: [InitializationMap: Data],
        referer: URL
    ) async throws -> DownloadedSegment {
        let memoryClaim = try await mediaMemoryBudget.acquire(
            byteCount: Self.mediaTaskMemoryReservationBytes
        )
        await permitPool.acquire()
        do {
            let result = try await downloadSegment(
                segment,
                prefix: prefix,
                directory: directory,
                keyData: keyData,
                mapData: mapData,
                referer: referer
            )
            await permitPool.release()
            await mediaMemoryBudget.release(memoryClaim)
            return result
        } catch {
            await permitPool.release()
            await mediaMemoryBudget.release(memoryClaim)
            throw error
        }
    }

    private func fetchKeys(for playlist: MediaPlaylist) async throws -> [URL: Data] {
        let descriptors = playlist.segments.flatMap { segment -> [EncryptionDescriptor] in
            var values: [EncryptionDescriptor] = []
            if let encryption = segment.encryption { values.append(encryption) }
            if let encryption = segment.initializationMap?.encryption { values.append(encryption) }
            return values
        }
        guard descriptors.allSatisfy({ $0.method == .aes128 }) else {
            throw HLSError.drmUnsupported("SAMPLE-AES requires the protected HLS pipeline")
        }

        var result: [URL: Data] = [:]
        for descriptor in descriptors where result[descriptor.keyURL.primary] == nil {
            result[descriptor.keyURL.primary] = try await fetchKey(
                descriptor,
                referer: playlist.requestReferer ?? playlist.effectiveURL
            )
        }
        return result
    }

    private func fetchKey(_ descriptor: EncryptionDescriptor, referer: URL) async throws -> Data {
        var lastError: Error = HLSError.invalidAESKey
        for candidate in descriptor.keyURL.all {
            do {
                let payload = try await client.fetch(candidate, referer: referer)
                let signature = MediaPayloadInspector.signature(payload.data)
                guard payload.data.count == kCCKeySizeAES128,
                      !["HTML", "XML", "JSON", "m3u8"].contains(signature) else {
                    throw HLSError.invalidAESKey
                }
                return payload.data
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetchMaps(
        for playlist: MediaPlaylist,
        keyData: [URL: Data]
    ) async throws -> [InitializationMap: Data] {
        let maps = Array(Set(playlist.segments.compactMap(\.initializationMap)))
        guard maps.count <= InitializationMapMemoryBudget.maximumMapCount else {
            throw HLSError.invalidPlaylist("too many initialization maps")
        }
        var result: [InitializationMap: Data] = [:]
        var memoryBudget = InitializationMapMemoryBudget()

        for map in maps {
            let reservedMaximum = try memoryBudget.maximumBytesForNextMap()
            let data = try await fetchMap(
                map,
                keyData: keyData,
                referer: playlist.requestReferer ?? playlist.effectiveURL,
                maximumBytes: reservedMaximum
            )
            try memoryBudget.commit(
                byteCount: data.count,
                reservedMaximumBytes: reservedMaximum
            )
            result[map] = data
        }
        return result
    }

    private func fetchMap(
        _ map: InitializationMap,
        keyData: [URL: Data],
        referer: URL,
        maximumBytes: Int64
    ) async throws -> Data {
        var lastError: Error = HLSError.invalidPlaylist("初期化データを取得できません")
        for candidate in map.url.all {
            do {
                let response = try await client.fetch(
                    candidate,
                    referer: referer,
                    byteRange: map.byteRange,
                    maximumBytes: maximumBytes
                )
                var data = response.data
                if let encryption = map.encryption {
                    switch encryption.method {
                    case .aes128:
                        guard let key = keyData[encryption.keyURL.primary],
                              let iv = encryption.explicitIV else {
                            throw HLSError.invalidAESKey
                        }
                        data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
                    case .sampleAES:
                        throw HLSError.drmUnsupported("SAMPLE-AES requires the protected HLS pipeline")
                    }
                }
                guard MediaPayloadInspector.detectInitialization(data) != nil else {
                    throw invalidPayloadError(
                        stream: "初期化用",
                        number: 1,
                        response: response,
                        data: data
                    )
                }
                return data
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
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
        let (mediaData, mediaContainer) = try await fetchMedia(
            segment,
            keyData: keyData,
            referer: referer,
            stream: prefix == "audio" ? "音声" : "映像"
        )
        let initializationData = segment.initializationMap.flatMap { mapData[$0] }
        if let initializationData,
           MediaPayloadInspector.detectInitialization(initializationData) != mediaContainer {
            throw HLSError.invalidPlaylist("initialization map container does not match its media segment")
        }

        let name = String(format: "%@-%06d.%@", prefix, segment.ordinal, mediaContainer.fileExtension)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try await writeProtected(
            mediaData,
            initializationData: initializationData,
            to: destination
        )
        let initializationByteCount = initializationData?.count ?? 0
        guard mediaData.count <= Int.max - initializationByteCount else {
            throw HLSError.network("segment output size overflow")
        }
        let outputByteCount = initializationByteCount + mediaData.count
        return DownloadedSegment(
            source: segment,
            fileURL: destination,
            container: mediaContainer,
            byteCount: outputByteCount,
            initializationDataLength: initializationByteCount
        )
    }

    private func fetchMedia(
        _ segment: MediaSegment,
        keyData: [URL: Data],
        referer: URL,
        stream: String
    ) async throws -> (Data, MediaContainer) {
        var lastError: Error = HLSError.invalidPlaylist("断片を取得できません")
        for candidate in segment.url.all {
            do {
                let response = try await client.fetch(
                    candidate,
                    referer: referer,
                    byteRange: segment.byteRange,
                    maximumBytes: Self.maximumMediaResponseBytes
                )
                var data = response.data
                if let encryption = segment.encryption {
                    switch encryption.method {
                    case .aes128:
                        guard let key = keyData[encryption.keyURL.primary] else {
                            throw HLSError.invalidAESKey
                        }
                        let iv = encryption.explicitIV
                            ?? AES128CBCDecryptor.initializationVector(for: segment.mediaSequence)
                        data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
                    case .sampleAES:
                        throw HLSError.drmUnsupported("SAMPLE-AES requires the protected HLS pipeline")
                    }
                }
                guard let container = MediaPayloadInspector.detect(data, mimeType: response.mimeType) else {
                    throw invalidPayloadError(
                        stream: stream,
                        number: segment.ordinal + 1,
                        response: response,
                        data: data
                    )
                }
                if container == .isoBaseMedia,
                   segment.initializationMap == nil,
                   !MediaPayloadInspector.isInitializationData(data, container: container) {
                    throw HLSError.invalidPlaylist("fMP4断片に必要なEXT-X-MAPがありません")
                }
                return (data, container)
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func invalidPayloadError(
        stream: String,
        number: Int,
        response: HTTPPayload,
        data: Data
    ) -> HLSError {
        HLSError.invalidMediaPayload(
            stream: stream,
            number: number,
            mimeType: response.mimeType,
            byteCount: data.count,
            signature: MediaPayloadInspector.signature(data)
        )
    }
}

enum MediaPayloadInspector {
    static func detect(_ data: Data, mimeType: String?) -> MediaContainer? {
        guard !data.isEmpty else { return nil }
        if ["HTML", "XML", "JSON", "m3u8"].contains(signature(data)) { return nil }
        let bytes = [UInt8](data.prefix(262_144))

        if isTransportStream(bytes) { return .transportStream }
        if isISOBaseMedia(bytes) { return .isoBaseMedia }
        if isWebM(bytes) { return .webM }
        if isOgg(bytes) { return .ogg }
        if isWave(bytes) { return .wave }
        if isFLAC(bytes) { return .flac }

        if let audio = detectAudio(bytes, at: 0, mimeType: mimeType) { return audio }
        if let offset = leadingID3Length(bytes),
           let audio = detectAudio(bytes, at: offset, mimeType: mimeType) {
            return audio
        }
        return nil
    }

    static func detectInitialization(_ data: Data) -> MediaContainer? {
        guard !data.isEmpty else { return nil }
        if ["HTML", "XML", "JSON", "m3u8"].contains(signature(data)) { return nil }
        let bytes = [UInt8](data.prefix(262_144))
        if isoBoxTypes(bytes).contains("moov") { return .isoBaseMedia }
        let pids = transportPIDs(bytes)
        if pids.contains(0), pids.contains(where: { $0 != 0 && $0 != 0x1fff }) {
            return .transportStream
        }
        return nil
    }

    static func leadingID3Length(_ bytes: [UInt8]) -> Int? {
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
        let length = 10 + tagSize + (hasFooter ? 10 : 0)
        return length <= bytes.count ? length : nil
    }

    static func signature(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        let prefix = [UInt8](data.prefix(64))
        let visible = String(bytes: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if visible.hasPrefix("<!doctype") || visible.hasPrefix("<html") { return "HTML" }
        if visible.hasPrefix("<?xml") || visible.hasPrefix("<error") { return "XML" }
        if visible.hasPrefix("#extm3u") { return "m3u8" }
        if visible.hasPrefix("{") || visible.hasPrefix("[") { return "JSON" }
        return data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func isFragmentWithoutInitialization(_ data: Data) -> Bool {
        let types = isoBoxTypes([UInt8](data.prefix(262_144)))
        return types.contains("moof") && !types.contains("moov")
    }

    static func isInitializationData(_ data: Data, container: MediaContainer) -> Bool {
        detectInitialization(data) == container
    }

    private static func detectAudio(_ bytes: [UInt8], at offset: Int, mimeType: String?) -> MediaContainer? {
        guard offset >= 0, offset + 1 < bytes.count else { return nil }
        if offset + 6 < bytes.count,
           bytes[offset] == 0xff,
           bytes[offset + 1] & 0xf6 == 0xf0 {
            let frameLength = (Int(bytes[offset + 3] & 0x03) << 11)
                | (Int(bytes[offset + 4]) << 3)
                | (Int(bytes[offset + 5]) >> 5)
            if frameLength >= 7, offset + frameLength <= bytes.count { return .aac }
        }
        if offset + 5 < bytes.count, bytes[offset] == 0x0b, bytes[offset + 1] == 0x77 {
            if mimeType?.lowercased().contains("eac3") == true
                || mimeType?.lowercased().contains("ec3") == true {
                return .eac3
            }
            if offset + 5 < bytes.count, bytes[offset + 5] >> 3 > 10 { return .eac3 }
            return .ac3
        }
        if offset + 3 < bytes.count,
           bytes[offset] == 0xff,
           bytes[offset + 1] & 0xe0 == 0xe0 {
            let version = (bytes[offset + 1] >> 3) & 0x03
            let layer = (bytes[offset + 1] >> 1) & 0x03
            let bitrateIndex = (bytes[offset + 2] >> 4) & 0x0f
            let sampleRateIndex = (bytes[offset + 2] >> 2) & 0x03
            if version != 1, layer != 0, bitrateIndex != 0, bitrateIndex != 0x0f,
               sampleRateIndex != 0x03 {
                return .mp3
            }
        }
        return nil
    }

    private static func isWebM(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4
            && bytes[0] == 0x1a
            && bytes[1] == 0x45
            && bytes[2] == 0xdf
            && bytes[3] == 0xa3
    }

    private static func isOgg(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4
            && bytes[0] == 0x4f
            && bytes[1] == 0x67
            && bytes[2] == 0x67
            && bytes[3] == 0x53
    }

    private static func isWave(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12
            && bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46])
            && bytes[8...11].elementsEqual([0x57, 0x41, 0x56, 0x45])
    }

    private static func isFLAC(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4
            && bytes[0...3].elementsEqual([0x66, 0x4c, 0x61, 0x43])
    }

    private static func isTransportStream(_ bytes: [UInt8]) -> Bool {
        for packetSize in [188, 192, 204] {
            guard !bytes.isEmpty else { continue }
            let maximumOffset = min(packetSize - 1, bytes.count - 1)
            for offset in 0...maximumOffset where isValidTransportHeader(bytes, at: offset) {
                var checked = 1
                var position = offset + packetSize
                while position < bytes.count, checked < 3 {
                    guard isValidTransportHeader(bytes, at: position) else { break }
                    checked += 1
                    position += packetSize
                }
                if checked >= 3 { return true }
            }
        }
        return false
    }

    private static func isValidTransportHeader(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + 3 < bytes.count,
              bytes[offset] == 0x47,
              bytes[offset + 1] & 0x80 == 0 else {
            return false
        }
        let adaptationFieldControl = (bytes[offset + 3] >> 4) & 0x03
        return adaptationFieldControl != 0
    }

    private static func transportPID(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 < bytes.count else { return nil }
        return (Int(bytes[offset + 1] & 0x1f) << 8) | Int(bytes[offset + 2])
    }

    private static func transportPIDs(_ bytes: [UInt8]) -> Set<Int> {
        var best = Set<Int>()
        for packetSize in [188, 192, 204] {
            guard !bytes.isEmpty else { continue }
            let maximumOffset = min(packetSize - 1, bytes.count - 1)
            for offset in 0...maximumOffset where isValidTransportHeader(bytes, at: offset) {
                var pids = Set<Int>()
                var position = offset
                while position + 3 < bytes.count, pids.count < 16,
                      isValidTransportHeader(bytes, at: position) {
                    if let pid = transportPID(bytes, at: position) { pids.insert(pid) }
                    position += packetSize
                }
                if pids.contains(0), pids.contains(where: { $0 != 0 && $0 != 0x1fff }) {
                    return pids
                }
                if pids.count > best.count { best = pids }
            }
        }
        return best
    }

    private static func isISOBaseMedia(_ bytes: [UInt8]) -> Bool {
        let accepted = Set(["ftyp", "styp", "moov", "moof", "sidx"])
        return !isoBoxTypes(bytes).isDisjoint(with: accepted)
    }

    private static func isoBoxTypes(_ bytes: [UInt8]) -> Set<String> {
        var types = Set<String>()
        var offset = 0
        var visited = 0
        while offset + 8 <= bytes.count, visited < 32 {
            let size32 = UInt64(bytes[offset]) << 24
                | UInt64(bytes[offset + 1]) << 16
                | UInt64(bytes[offset + 2]) << 8
                | UInt64(bytes[offset + 3])
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""

            let headerSize: Int
            let boxSize: UInt64
            if size32 == 1 {
                guard offset + 16 <= bytes.count else { break }
                boxSize = bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size32 == 0 {
                break
            } else {
                boxSize = size32
                headerSize = 8
            }
            guard boxSize >= UInt64(headerSize), boxSize <= UInt64(Int.max) else { break }
            let next = offset + Int(boxSize)
            guard next > offset, next <= bytes.count else { break }
            let minimumSize: UInt64
            switch type {
            case "ftyp", "styp": minimumSize = 16
            case "sidx": minimumSize = 12
            default: minimumSize = UInt64(headerSize)
            }
            if boxSize >= minimumSize, type.count == 4 { types.insert(type) }
            offset = next
            visited += 1
        }
        return types
    }
}

/// Treats URL extensions and Content-Type as discovery hints only. A candidate
/// is not accepted until its bounded response prefix has a supported media
/// signature; the complete file is probed again with FFprobe before export.
enum ProgressiveMediaDetector {
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m4a", "mp3", "aac", "ac3", "eac3", "ec3",
        "ogg", "oga", "opus", "wav", "flac", "ts", "m2t", "m2ts", "mts", "webm"
    ]

    static func hasHint(url: URL, mimeType: String?) -> Bool {
        if supportedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let mime = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return true }
        return mime == "application/ogg"
            || mime == "application/mp4"
            || mime == "application/octet-stream"
    }

    static func detect(prefix: Data, url: URL, mimeType: String?) -> MediaContainer? {
        guard !prefix.isEmpty,
              let detected = MediaPayloadInspector.detect(prefix, mimeType: mimeType) else {
            return nil
        }

        // Strong bounded magic is authoritative. Hints decide which requests
        // are worth probing, but a missing/incorrect suffix never overrides the
        // bytes returned by the server.
        guard hasHint(url: url, mimeType: mimeType)
                || isStrongContainerSignature(detected) else {
            return nil
        }
        return detected
    }

    /// Standalone TS/AAC/AC-3 have no manifest key metadata. SAMPLE-AES can
    /// leave enough framing and metadata clear for FFprobe while media samples
    /// remain encrypted, so accepting them from magic + FFprobe is fail-open.
    /// Manifest-backed HLS continues through the existing SAMPLE-AES pipeline;
    /// only raw progressive forms are excluded here.
    static func supportsStandaloneDownload(_ container: MediaContainer) -> Bool {
        switch container {
        case .transportStream, .aac, .ac3, .eac3:
            return false
        case .isoBaseMedia, .mp3, .ogg, .wave, .flac, .webM:
            return true
        }
    }

    private static func isStrongContainerSignature(_ container: MediaContainer) -> Bool {
        switch container {
        case .transportStream, .isoBaseMedia, .aac, .mp3, .ac3, .eac3,
             .ogg, .wave, .flac, .webM:
            return true
        }
    }
}

enum ProgressiveMediaFingerprint {
    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBytes in
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256(
                    bytes.baseAddress,
                    CC_LONG(data.count),
                    digestBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return Data(digest)
    }
}

/// Extracts display dimensions only from a structurally bounded `tkhd` box in
/// the already-downloaded MP4 prefix. A missing/late `moov` box simply leaves
/// the resolution unknown; URL names and page titles are never treated as
/// quality evidence.
enum ProgressiveMediaResolutionProbe {
    static func detect(prefix: Data, container: MediaContainer) -> MediaResolution? {
        guard container == .isoBaseMedia, prefix.count >= 8 else { return nil }
        var scanner = Scanner(data: prefix)
        scanner.scan(from: 0, to: prefix.count, depth: 0)
        if let best = scanner.best { return best }

        // A suffix Range can begin before a fast-searchable `moov` box rather
        // than at a top-level box boundary. Locate a fully contained normal-size
        // movie box, then run the same bounded structural scanner on that slice.
        var inspectedMarkers = 0
        for typeOffset in 4..<(prefix.count - 4) {
            guard inspectedMarkers < 128,
                  prefix[typeOffset] == 0x6D,
                  prefix[typeOffset + 1] == 0x6F,
                  prefix[typeOffset + 2] == 0x6F,
                  prefix[typeOffset + 3] == 0x76 else {
                continue
            }
            inspectedMarkers += 1
            let start = typeOffset - 4
            let size = Int(prefix[start]) << 24
                | Int(prefix[start + 1]) << 16
                | Int(prefix[start + 2]) << 8
                | Int(prefix[start + 3])
            guard size >= 8, start <= prefix.count - size else { continue }
            var embedded = Scanner(data: Data(prefix[start..<(start + size)]))
            embedded.scan(from: 0, to: size, depth: 0)
            if let best = embedded.best { return best }
        }
        return nil
    }

    private struct Scanner {
        private static let containerTypes: Set<String> = [
            "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex"
        ]
        private static let maximumBoxes = 4_096
        private static let maximumDepth = 10

        let data: Data
        var boxCount = 0
        var best: MediaResolution?

        mutating func scan(from start: Int, to parentEnd: Int, depth: Int) {
            guard depth <= Self.maximumDepth,
                  start >= 0,
                  parentEnd <= data.count,
                  start <= parentEnd else {
                return
            }
            var cursor = start
            while cursor + 8 <= parentEnd, boxCount < Self.maximumBoxes {
                guard let box = nextBox(at: cursor, parentEnd: parentEnd) else { return }
                boxCount += 1
                if box.type == "tkhd", let resolution = trackResolution(box) {
                    if let current = best {
                        if resolution.pixelCount > current.pixelCount { best = resolution }
                    } else {
                        best = resolution
                    }
                } else if Self.containerTypes.contains(box.type) {
                    scan(from: box.payloadStart, to: box.availableEnd, depth: depth + 1)
                }
                guard box.declaredEnd > cursor else { return }
                if box.declaredEnd > parentEnd { return }
                cursor = box.declaredEnd
            }
        }

        private struct Box {
            let type: String
            let payloadStart: Int
            let declaredEnd: Int
            let availableEnd: Int
        }

        private func nextBox(at offset: Int, parentEnd: Int) -> Box? {
            guard offset >= 0,
                  offset + 8 <= parentEnd,
                  let size32 = uint32(at: offset),
                  let type = ascii(at: offset + 4, count: 4) else {
                return nil
            }
            var headerSize = 8
            let declaredSize: UInt64
            if size32 == 1 {
                guard offset + 16 <= parentEnd,
                      let size64 = uint64(at: offset + 8),
                      size64 >= 16 else {
                    return nil
                }
                headerSize = 16
                declaredSize = size64
            } else if size32 == 0 {
                declaredSize = UInt64(parentEnd - offset)
            } else {
                guard size32 >= 8 else { return nil }
                declaredSize = UInt64(size32)
            }
            guard declaredSize <= UInt64(Int.max) else { return nil }
            let (declaredEnd, overflow) = offset.addingReportingOverflow(Int(declaredSize))
            guard !overflow,
                  declaredEnd >= offset + headerSize else {
                return nil
            }
            return Box(
                type: type,
                payloadStart: offset + headerSize,
                declaredEnd: declaredEnd,
                availableEnd: min(declaredEnd, parentEnd)
            )
        }

        private func trackResolution(_ box: Box) -> MediaResolution? {
            guard box.payloadStart < box.availableEnd else { return nil }
            let version = data[box.payloadStart]
            let widthOffset: Int
            switch version {
            case 0: widthOffset = box.payloadStart + 76
            case 1: widthOffset = box.payloadStart + 88
            default: return nil
            }
            guard widthOffset + 8 <= box.availableEnd,
                  let rawWidth = uint32(at: widthOffset),
                  let rawHeight = uint32(at: widthOffset + 4) else {
                return nil
            }
            return MediaResolution(
                width: Int(rawWidth >> 16),
                height: Int(rawHeight >> 16)
            )
        }

        private func ascii(at offset: Int, count: Int) -> String? {
            guard offset >= 0, count > 0, offset + count <= data.count else { return nil }
            return String(bytes: data[offset..<(offset + count)], encoding: .ascii)
        }

        private func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
        }

        private func uint64(at offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            var value: UInt64 = 0
            for byte in data[offset..<(offset + 8)] {
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
    }
}
