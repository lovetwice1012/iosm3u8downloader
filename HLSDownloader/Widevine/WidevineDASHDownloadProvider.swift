import Foundation

extension WidevineContentKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "WidevineContentKey(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["contents": "<redacted>"], displayStyle: .struct)
    }
}

protocol WidevineKeyAcquiring: Sendable {
    var isConfigured: Bool { get }

    func acquireKeys(
        initData: [Data],
        expectedKeyIDs: Set<String>,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> [WidevineContentKey]
}

struct UnconfiguredWidevineKeyAcquirer: WidevineKeyAcquiring, Sendable {
    let isConfigured = false

    func acquireKeys(
        initData: [Data],
        expectedKeyIDs: Set<String>,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> [WidevineContentKey] {
        throw WidevineProcessingError.unconfigured
    }
}

struct WidevineEncryptedTrackInput: Sendable {
    let encryptedFileURL: URL
    let keyData: Data
    let scheme: DASHCommonEncryptionScheme?
}

protocol WidevineMediaComposing: Sendable {
    var isConfigured: Bool { get }

    func decryptAndMux(
        video: WidevineEncryptedTrackInput?,
        audio: WidevineEncryptedTrackInput?,
        outputURL: URL
    ) async throws
}

struct UnconfiguredWidevineMediaComposer: WidevineMediaComposing, Sendable {
    let isConfigured = false

    func decryptAndMux(
        video: WidevineEncryptedTrackInput?,
        audio: WidevineEncryptedTrackInput?,
        outputURL: URL
    ) async throws {
        throw WidevineProcessingError.unconfigured
    }
}

protocol DASHSegmentFetching: Sendable {
    /// Streams one segment to `destinationURL` and aborts before writing more
    /// than `maximumBytes`. Implementations must remove incomplete output on
    /// failure and return the final file size.
    func fetch(
        to destinationURL: URL,
        url: URL,
        referer: URL?,
        byteRange: ByteRange?,
        maximumBytes: Int
    ) async throws -> Int64
}

struct HTTPDASHSegmentFetcher: DASHSegmentFetching, Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    func fetch(
        to destinationURL: URL,
        url: URL,
        referer: URL?,
        byteRange: ByteRange?,
        maximumBytes: Int
    ) async throws -> Int64 {
        try await client.downloadLimited(
            url,
            to: destinationURL,
            referer: referer,
            byteRange: byteRange,
            maximumBytes: maximumBytes
        )
    }
}

actor DASHDownloadPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        availablePermits = max(limit, 1)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        if Task.isCancelled {
            // A release may have resumed this waiter immediately before its
            // cancellation handler ran. Return that permit to the pool rather
            // than leaking it to an already-cancelled caller.
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private actor DASHStorageBudget {
    struct Reservation: Sendable {
        let id: UUID
        let maximumBytes: Int64
    }

    private let maximumBytes: Int64
    private var remainingBytes: Int64
    private var reservations: [UUID: Int64] = [:]

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
        remainingBytes = maximumBytes
    }

    func reserve(maximumBytes requested: Int64) throws -> Reservation {
        guard requested > 0, requested < remainingBytes else {
            throw WidevineDASHProviderError.totalDownloadTooLarge
        }
        let reservation = Reservation(id: UUID(), maximumBytes: requested)
        reservations[reservation.id] = requested
        remainingBytes -= requested
        return reservation
    }

    func commit(_ reservation: Reservation, actualBytes: Int64) throws {
        guard let reserved = reservations.removeValue(forKey: reservation.id) else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        guard actualBytes > 0, actualBytes <= reserved else {
            remainingBytes += reserved
            throw WidevineDASHProviderError.segmentTooLarge
        }
        remainingBytes += reserved - actualBytes
    }

    func rollback(_ reservation: Reservation) {
        guard let reserved = reservations.removeValue(forKey: reservation.id),
              remainingBytes <= maximumBytes - reserved else { return }
        remainingBytes += reserved
    }

    func releaseStoredBytes(_ byteCount: Int64) {
        guard byteCount > 0 else { return }
        remainingBytes = min(maximumBytes, remainingBytes + byteCount)
    }
}

enum WidevineDASHProviderError: LocalizedError, Equatable, Sendable {
    case dynamicPresentationUnsupported
    case multiplePeriodsUnsupported
    case noSupportedTracks
    case unsupportedRepresentation
    case segmentAddressingMissing
    case invalidSegmentTemplate
    case invalidSegmentRange
    case segmentLimitExceeded
    case unsafeSegmentURL
    case insecureLicenseURL
    case psshMissing
    case keyIDMissing
    case keyRotationUnsupported
    case contentKeyMissing
    case invalidContentKey
    case invalidEncryptionMetadata
    case segmentTooLarge
    case totalDownloadTooLarge
    case invalidMediaOutput

    var errorDescription: String? {
        switch self {
        case .dynamicPresentationUnsupported:
            return "ライブ／Dynamic MPDの保存には対応していません。"
        case .multiplePeriodsUnsupported:
            return "複数PeriodのWidevine MPDには対応していません。"
        case .noSupportedTracks:
            return "保存できる映像・音声trackがありません。"
        case .unsupportedRepresentation:
            return "選択されたrepresentationはMP4/fMP4ではありません。"
        case .segmentAddressingMissing:
            return "MPDからsegmentの取得先を確定できません。"
        case .invalidSegmentTemplate:
            return "SegmentTemplateまたはSegmentTimelineが不正です。"
        case .invalidSegmentRange:
            return "SegmentListのbyte rangeが不正です。"
        case .segmentLimitExceeded:
            return "MPDのsegment数が安全上限を超えています。"
        case .unsafeSegmentURL:
            return "安全でないsegment URLを拒否しました。"
        case .insecureLicenseURL:
            return "WidevineライセンスURLはHTTPSである必要があります。"
        case .psshMissing:
            return "Widevine PSSHを確認できません。"
        case .keyIDMissing:
            return "暗号化trackのKIDを確認できません。"
        case .keyRotationUnsupported:
            return "1つのrepresentation内でのkey rotationには対応していません。"
        case .contentKeyMissing:
            return "必要なWidevine content keyを取得できませんでした。"
        case .invalidContentKey:
            return "Widevine content keyの形式が不正です。"
        case .invalidEncryptionMetadata:
            return "fMP4の暗号化メタデータが不正です。"
        case .segmentTooLarge:
            return "DASH segmentが安全上限を超えています。"
        case .totalDownloadTooLarge:
            return "DASH動画の合計サイズが安全上限を超えています。"
        case .invalidMediaOutput:
            return "復号・変換後のMP4またはWAVを確認できません。"
        }
    }
}

struct WidevineDASHDownloadProvider: WidevineProcessingProviding, @unchecked Sendable {
    private static let artifactDirectoryName = "HLSDownloader-Widevine"
    private static let jobDirectoryPrefix = "job-"
    private static let maximumSegmentBytes = 48 * 1_024 * 1_024
    private static let maximumParallelDownloadBytes = 144 * 1_024 * 1_024
    // Per selected track. Source segment payload is bounded to 16 GiB across
    // one selected video and one selected audio representation.
    private static let maximumTotalBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    private let segmentFetcher: any DASHSegmentFetching
    private let keyAcquirer: any WidevineKeyAcquiring
    private let mediaComposer: any WidevineMediaComposing
    private let fileManager: FileManager
    private let artifactRoot: URL
    private let maximumParallelDownloads: Int

    // Production creates one provider at app startup.  Remove abandoned clear
    // output from a prior crash before any new Widevine job can start.
    private static let defaultStartupCleanup: Void = {
        try? cleanupArtifacts(
            in: FileManager.default.temporaryDirectory,
            fileManager: .default
        )
    }()

    init(
        segmentFetcher: any DASHSegmentFetching,
        keyAcquirer: any WidevineKeyAcquiring,
        mediaComposer: any WidevineMediaComposing,
        fileManager: FileManager = .default,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        maximumParallelDownloads: Int = 6
    ) {
        self.segmentFetcher = segmentFetcher
        self.keyAcquirer = keyAcquirer
        self.mediaComposer = mediaComposer
        self.fileManager = fileManager
        artifactRoot = temporaryRoot.appendingPathComponent(
            Self.artifactDirectoryName,
            isDirectory: true
        )
        if temporaryRoot.standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL {
            _ = Self.defaultStartupCleanup
        }
        let budgetedParallelism = Int(
            Self.maximumParallelDownloadBytes / Self.maximumSegmentBytes
        )
        self.maximumParallelDownloads = min(
            max(maximumParallelDownloads, 1),
            min(max(budgetedParallelism, 1), 12)
        )
    }

    var isConfigured: Bool {
        keyAcquirer.isConfigured && mediaComposer.isConfigured
    }

    func process(
        manifest document: WidevineManifestDocument,
        licenseConfiguration: WidevineLicenseConfiguration,
        wvdData: Data
    ) async throws -> WidevineProcessingResult {
        guard isDownloadableWidevineDomain(document.sourceURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }
        guard isConfigured else { throw WidevineProcessingError.unconfigured }
        guard Self.isSecureNetworkURL(licenseConfiguration.serverURL),
              isDownloadableWidevineDomain(licenseConfiguration.serverURL) else {
            throw WidevineDASHProviderError.insecureLicenseURL
        }

        let manifest = try DASHManifestParser.parse(
            data: document.data,
            effectiveURL: document.sourceURL
        )
        guard manifest.isWidevine else {
            throw HLSError.invalidPlaylist("Widevine ContentProtectionを確認できません")
        }
        let plan = try WidevineDASHPlanner().makePlan(manifest: manifest)
        let outputFormat = plan.outputFormat
        let keys = try await keyAcquirer.acquireKeys(
            initData: plan.psshData,
            expectedKeyIDs: plan.expectedKeyIDs,
            licenseConfiguration: licenseConfiguration,
            wvdData: wvdData
        )
        let keyMap = try validatedKeyMap(keys, expectedKeyIDs: plan.expectedKeyIDs)

        try Task.checkCancellation()
        guard isDownloadableWidevineDomain(document.sourceURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }

        try Self.prepareProtectedDirectory(artifactRoot, fileManager: fileManager)
        let jobDirectory = artifactRoot.appendingPathComponent(
            "\(Self.jobDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        let workDirectory = jobDirectory.appendingPathComponent(
            "encrypted",
            isDirectory: true
        )
        let outputURL = jobDirectory.appendingPathComponent(
            "output.\(outputFormat.rawValue)",
            isDirectory: false
        )
        try Self.prepareProtectedDirectory(jobDirectory, fileManager: fileManager)
        try Self.prepareProtectedDirectory(workDirectory, fileManager: fileManager)
        let stagedMaximumBytes = try LocalFFmpegOutputLimit.maximumBytes(
            for: workDirectory.appendingPathComponent(".dash-storage-budget"),
            fileManager: fileManager
        )
        let storageBudget = DASHStorageBudget(maximumBytes: stagedMaximumBytes)
        var keepOutput = false
        defer {
            try? fileManager.removeItem(at: workDirectory)
            if !keepOutput { try? fileManager.removeItem(at: jobDirectory) }
        }

        let downloadPool = DASHDownloadPermitPool(limit: maximumParallelDownloads)
        async let videoFile = download(
            track: plan.video,
            in: workDirectory,
            permitPool: downloadPool,
            storageBudget: storageBudget
        )
        async let audioFile = download(
            track: plan.audio,
            in: workDirectory,
            permitPool: downloadPool,
            storageBudget: storageBudget
        )
        let (downloadedVideo, downloadedAudio) = try await (videoFile, audioFile)

        let videoInput = try composerInput(
            track: plan.video,
            downloadedURL: downloadedVideo,
            keyMap: keyMap
        )
        let audioInput = try composerInput(
            track: plan.audio,
            downloadedURL: downloadedAudio,
            keyMap: keyMap
        )
        guard videoInput != nil || audioInput != nil else {
            throw WidevineDASHProviderError.noSupportedTracks
        }

        try await mediaComposer.decryptAndMux(
            video: videoInput,
            audio: audioInput,
            outputURL: outputURL
        )
        guard WidevineMediaOutputValidator.isValid(outputURL, format: outputFormat) else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }

        // Provider boundary re-check. HLSDownloadService performs the same
        // centralized policy check again immediately before the final save.
        guard isDownloadableWidevineDomain(document.sourceURL) else {
            throw WidevineProcessingError.domainNotAllowed
        }
        keepOutput = true
        return WidevineProcessingResult(
            mediaFileURL: outputURL,
            outputFormat: outputFormat
        )
    }

    /// Removes only artifacts created by this provider. This is used once at
    /// process startup and is internal so the crash-recovery boundary can be
    /// verified without importing a real WVD.
    static func cleanupArtifacts(
        in temporaryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = temporaryRoot.appendingPathComponent(
            artifactDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        guard root.deletingLastPathComponent() == temporaryRoot.standardizedFileURL else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        guard fileManager.fileExists(atPath: root.path) else { return }
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let normalized = child.standardizedFileURL
            guard normalized.deletingLastPathComponent() == root,
                  normalized.lastPathComponent.hasPrefix(jobDirectoryPrefix) else {
                continue
            }
            let values = try normalized.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try fileManager.removeItem(at: normalized)
        }
    }

    private static func prepareProtectedDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw WidevineDASHProviderError.invalidMediaOutput
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: directory.path
        )
    }

    private func download(
        track: WidevineDASHTrackPlan?,
        in workDirectory: URL,
        permitPool: DASHDownloadPermitPool,
        storageBudget: DASHStorageBudget
    ) async throws -> URL? {
        guard let track else { return nil }
        let trackDirectory = workDirectory.appendingPathComponent(
            track.mediaType.rawValue,
            isDirectory: true
        )
        try fileManager.createDirectory(at: trackDirectory, withIntermediateDirectories: true)

        let allReferences = [track.initialization] + track.segments
        let parts = try await downloadParts(
            allReferences,
            to: trackDirectory,
            permitPool: permitPool,
            storageBudget: storageBudget
        )
        try WidevineFMP4EncryptionValidator.validate(
            initializationURL: parts[0],
            mediaURLs: Array(parts.dropFirst()),
            expectedKeyID: track.keyID,
            maximumObjectBytes: Self.maximumSegmentBytes
        )
        let combinedURL = workDirectory.appendingPathComponent(
            "encrypted-\(track.mediaType.rawValue).mp4",
            isDirectory: false
        )
        try await concatenate(parts, to: combinedURL, storageBudget: storageBudget)
        return combinedURL
    }

    private func downloadParts(
        _ references: [WidevineDASHSegmentReference],
        to directory: URL,
        permitPool: DASHDownloadPermitPool,
        storageBudget: DASHStorageBudget
    ) async throws -> [URL] {
        guard references.count <= WidevineDASHPlanner.maximumSegmentsPerTrack + 1 else {
            throw WidevineDASHProviderError.segmentLimitExceeded
        }
        var output = Array<URL?>(repeating: nil, count: references.count)
        var totalBytes: Int64 = 0
        let parallelism = min(maximumParallelDownloads, references.count)

        try await withThrowingTaskGroup(of: (Int, URL, Int64).self) { group in
            var nextIndex = 0
            while nextIndex < parallelism {
                let index = nextIndex
                let reference = references[index]
                let destination = directory.appendingPathComponent(
                    String(format: "%06lld.part", Int64(index)),
                    isDirectory: false
                )
                group.addTask { [segmentFetcher, permitPool, storageBudget] in
                    let byteCount = try await Self.fetchSegment(
                        reference,
                        to: destination,
                        segmentFetcher: segmentFetcher,
                        permitPool: permitPool,
                        storageBudget: storageBudget
                    )
                    guard byteCount > 0,
                          byteCount <= Int64(Self.maximumSegmentBytes) else {
                        throw WidevineDASHProviderError.segmentTooLarge
                    }
                    return (index, destination, byteCount)
                }
                nextIndex += 1
            }
            while let (index, url, byteCount) = try await group.next() {
                output[index] = url
                let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
                guard !overflow, updatedTotal <= Self.maximumTotalBytes else {
                    group.cancelAll()
                    throw WidevineDASHProviderError.totalDownloadTooLarge
                }
                totalBytes = updatedTotal
                if nextIndex < references.count {
                    let pendingIndex = nextIndex
                    let reference = references[pendingIndex]
                    let destination = directory.appendingPathComponent(
                        String(format: "%06lld.part", Int64(pendingIndex)),
                        isDirectory: false
                    )
                    group.addTask { [segmentFetcher, permitPool, storageBudget] in
                        let byteCount = try await Self.fetchSegment(
                            reference,
                            to: destination,
                            segmentFetcher: segmentFetcher,
                            permitPool: permitPool,
                            storageBudget: storageBudget
                        )
                        guard byteCount > 0,
                              byteCount <= Int64(Self.maximumSegmentBytes) else {
                            throw WidevineDASHProviderError.segmentTooLarge
                        }
                        return (pendingIndex, destination, byteCount)
                    }
                    nextIndex += 1
                }
            }
        }
        return try output.map { url in
            guard let url else { throw WidevineDASHProviderError.invalidMediaOutput }
            return url
        }
    }

    private static func fetchSegment(
        _ reference: WidevineDASHSegmentReference,
        to destination: URL,
        segmentFetcher: any DASHSegmentFetching,
        permitPool: DASHDownloadPermitPool,
        storageBudget: DASHStorageBudget
    ) async throws -> Int64 {
        let reservation = try await storageBudget.reserve(
            maximumBytes: Int64(maximumSegmentBytes)
        )
        var permitHeld = false
        do {
            try await permitPool.acquire()
            permitHeld = true
            try Task.checkCancellation()
            let byteCount = try await segmentFetcher.fetch(
                to: destination,
                url: reference.url,
                referer: reference.referer,
                byteRange: reference.byteRange,
                maximumBytes: maximumSegmentBytes
            )
            await permitPool.release()
            permitHeld = false
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  Int64(fileSize) == byteCount else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            try await storageBudget.commit(reservation, actualBytes: byteCount)
            return byteCount
        } catch {
            if permitHeld { await permitPool.release() }
            try? FileManager.default.removeItem(at: destination)
            await storageBudget.rollback(reservation)
            throw error
        }
    }

    private func concatenate(
        _ inputs: [URL],
        to outputURL: URL,
        storageBudget: DASHStorageBudget
    ) async throws {
        var inputSizes: [(URL, Int64)] = []
        var totalBytes: Int64 = 0
        for inputURL in inputs {
            let values = try inputURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0 else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            let size = Int64(fileSize)
            let (updated, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, updated <= Self.maximumTotalBytes else {
                throw WidevineDASHProviderError.totalDownloadTooLarge
            }
            totalBytes = updated
            inputSizes.append((inputURL, size))
        }
        let reservation = try await storageBudget.reserve(maximumBytes: totalBytes)
        try? fileManager.removeItem(at: outputURL)
        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            await storageBudget.rollback(reservation)
            throw WidevineDASHProviderError.invalidMediaOutput
        }

        var writtenBytes: Int64 = 0
        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            for (inputURL, _) in inputSizes {
                try Task.checkCancellation()
                let input = try FileHandle(forReadingFrom: inputURL)
                do {
                    while let data = try input.read(upToCount: 1 * 1_024 * 1_024),
                          !data.isEmpty {
                        let chunkBytes = Int64(data.count)
                        guard writtenBytes <= totalBytes,
                              chunkBytes <= totalBytes - writtenBytes else {
                            throw WidevineDASHProviderError.invalidMediaOutput
                        }
                        try output.write(contentsOf: data)
                        writtenBytes += chunkBytes
                    }
                    try input.close()
                } catch {
                    try? input.close()
                    throw error
                }
            }
            guard writtenBytes == totalBytes else {
                throw WidevineDASHProviderError.invalidMediaOutput
            }
            try output.synchronize()
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: outputURL.path
            )
            try await storageBudget.commit(reservation, actualBytes: writtenBytes)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            await storageBudget.rollback(reservation)
            throw error
        }

        for (inputURL, size) in inputSizes {
            do {
                try fileManager.removeItem(at: inputURL)
                await storageBudget.releaseStoredBytes(size)
            } catch {
                // A retained source remains charged to the job budget and is
                // removed by the provider's work-directory cleanup.
            }
        }
    }

    private func validatedKeyMap(
        _ keys: [WidevineContentKey],
        expectedKeyIDs: Set<String>
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for key in keys {
            guard key.type == .content,
                  key.value.count == 16,
                  let normalized = WidevineKeyID.normalize(key.id) else {
                throw WidevineDASHProviderError.invalidContentKey
            }
            guard result[normalized] == nil else {
                throw WidevineDASHProviderError.invalidContentKey
            }
            result[normalized] = key.value
        }
        guard expectedKeyIDs.allSatisfy({ result[$0] != nil }) else {
            throw WidevineDASHProviderError.contentKeyMissing
        }
        return result
    }

    private func composerInput(
        track: WidevineDASHTrackPlan?,
        downloadedURL: URL?,
        keyMap: [String: Data]
    ) throws -> WidevineEncryptedTrackInput? {
        guard let track, let downloadedURL else { return nil }
        guard let keyData = keyMap[track.keyID], keyData.count == 16 else {
            throw WidevineDASHProviderError.contentKeyMissing
        }
        return WidevineEncryptedTrackInput(
            encryptedFileURL: downloadedURL,
            keyData: keyData,
            scheme: track.scheme
        )
    }

    private static func isSecureNetworkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host != nil
            && url.user == nil
            && url.password == nil
    }
}

/// Validates the encryption identity embedded in downloaded fragmented MP4
/// objects before they are passed to the decryptor. The scanner deliberately
/// reads only box headers and small encryption-metadata records; `mdat` payloads
/// are never materialized in memory.
struct WidevineFMP4EncryptionValidator {
    static func validate(
        initializationURL: URL,
        mediaURLs: [URL],
        expectedKeyID: String,
        maximumObjectBytes: Int = 48 * 1_024 * 1_024
    ) throws {
        try validateInitialization(
            at: initializationURL,
            expectedKeyID: expectedKeyID,
            maximumObjectBytes: maximumObjectBytes
        )
        for mediaURL in mediaURLs {
            try validateMediaFragment(
                at: mediaURL,
                expectedKeyID: expectedKeyID,
                maximumObjectBytes: maximumObjectBytes
            )
        }
    }

    static func validateInitialization(
        at url: URL,
        expectedKeyID: String,
        maximumObjectBytes: Int = 48 * 1_024 * 1_024
    ) throws {
        guard let normalizedKeyID = WidevineKeyID.normalize(expectedKeyID) else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var scanner = try BoundedBMFFEncryptionScanner(
            url: url,
            maximumObjectBytes: maximumObjectBytes,
            expectedKeyID: normalizedKeyID
        )
        try scanner.validateInitialization()
    }

    static func validateMediaFragment(
        at url: URL,
        expectedKeyID: String,
        maximumObjectBytes: Int = 48 * 1_024 * 1_024
    ) throws {
        guard let normalizedKeyID = WidevineKeyID.normalize(expectedKeyID) else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var scanner = try BoundedBMFFEncryptionScanner(
            url: url,
            maximumObjectBytes: maximumObjectBytes,
            expectedKeyID: normalizedKeyID
        )
        try scanner.validateMediaFragment()
    }
}

private struct BoundedBMFFBox {
    let type: String
    let payloadStart: UInt64
    let end: UInt64

    var payloadLength: UInt64 { end - payloadStart }
}

private final class BoundedBMFFFile {
    let size: UInt64
    private let handle: FileHandle

    init(url: URL, maximumObjectBytes: Int) throws {
        guard maximumObjectBytes > 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let reportedSize = values.fileSize,
              reportedSize > 0,
              reportedSize <= maximumObjectBytes else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let openedHandle = try FileHandle(forReadingFrom: url)
        let actualSize = try openedHandle.seekToEnd()
        guard actualSize == UInt64(reportedSize),
              actualSize <= UInt64(maximumObjectBytes) else {
            try? openedHandle.close()
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        handle = openedHandle
        size = actualSize
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let byteCount = UInt64(count)
        guard offset <= size, byteCount <= size - offset else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        return data
    }
}

private struct BoundedBMFFEncryptionScanner {
    private enum InitializationContext {
        case hierarchy
        case encryptedSampleEntry
        case protectionScheme
        case schemeInformation
    }

    private static let maximumBoxesPerObject = 100_000
    private static let maximumNestingDepth = 16
    private static let maximumGroupEntries = 100_000

    private let file: BoundedBMFFFile
    private let expectedKeyID: String
    private var boxCount = 0
    private var tencCount = 0
    private var initializationHasSeigDescription = false
    private var initializationRequiresSeigDescription = false

    init(url: URL, maximumObjectBytes: Int, expectedKeyID: String) throws {
        file = try BoundedBMFFFile(url: url, maximumObjectBytes: maximumObjectBytes)
        self.expectedKeyID = expectedKeyID
    }

    mutating func validateInitialization() throws {
        try scanInitializationBoxes(
            from: 0,
            to: file.size,
            depth: 0,
            context: .hierarchy
        )
        guard tencCount > 0,
              !initializationRequiresSeigDescription || initializationHasSeigDescription else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    mutating func validateMediaFragment() throws {
        var cursor: UInt64 = 0
        var moofCount = 0
        while cursor < file.size {
            let box = try nextBox(at: cursor, parentEnd: file.size)
            switch box.type {
            case "moof":
                moofCount += 1
                try scanMovieFragment(box, depth: 1)
            case "moov":
                // Media objects must not replace the initialization metadata
                // that was validated against the MPD KID.
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            case "uuid":
                // PIFF UUID sample-encryption records are intentionally not
                // interpreted by this CENC/CBCS validator.
                throw WidevineDASHProviderError.keyRotationUnsupported
            default:
                break // In particular, never read an mdat payload.
            }
            cursor = box.end
        }
        guard cursor == file.size, moofCount > 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private mutating func scanInitializationBoxes(
        from start: UInt64,
        to end: UInt64,
        depth: Int,
        context: InitializationContext
    ) throws {
        try validateDepth(depth)
        var cursor = start
        while cursor < end {
            let box = try nextBox(at: cursor, parentEnd: end)
            switch (context, box.type) {
            case (.hierarchy, "moov"), (.hierarchy, "trak"),
                 (.hierarchy, "mdia"), (.hierarchy, "minf"),
                 (.hierarchy, "stbl"):
                try scanInitializationBoxes(
                    from: box.payloadStart,
                    to: box.end,
                    depth: depth + 1,
                    context: .hierarchy
                )
            case (.hierarchy, "stsd"):
                try scanSampleDescription(box, depth: depth + 1)
            case (.hierarchy, "sgpd"):
                if try validateSampleGroupDescription(box) {
                    initializationHasSeigDescription = true
                }
            case (.hierarchy, "sbgp"):
                if try sampleToGroupRequiresDescription(box) {
                    initializationRequiresSeigDescription = true
                }
            case (.hierarchy, "moof"), (.hierarchy, "mdat"):
                // A DASH initialization object must not smuggle a fragment or
                // media payload whose encryption metadata bypasses validation.
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            case (.encryptedSampleEntry, "sinf"):
                try scanInitializationBoxes(
                    from: box.payloadStart,
                    to: box.end,
                    depth: depth + 1,
                    context: .protectionScheme
                )
            case (.protectionScheme, "schi"):
                try scanInitializationBoxes(
                    from: box.payloadStart,
                    to: box.end,
                    depth: depth + 1,
                    context: .schemeInformation
                )
            case (.schemeInformation, "tenc"):
                try validateTrackEncryption(box)
                tencCount += 1
            case (_, "tenc"):
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            case (_, "uuid"):
                throw WidevineDASHProviderError.keyRotationUnsupported
            default:
                break
            }
            cursor = box.end
        }
        guard cursor == end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private mutating func scanSampleDescription(
        _ box: BoundedBMFFBox,
        depth: Int
    ) throws {
        try validateDepth(depth)
        guard box.payloadLength >= 8 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let prefix = [UInt8](try file.read(at: box.payloadStart, count: 8))
        guard prefix[0] == 0, prefix[1] == 0, prefix[2] == 0, prefix[3] == 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let entryCount = Int(Self.uint32(prefix[4...7]))
        guard entryCount <= Self.maximumGroupEntries else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var cursor = box.payloadStart + 8
        for _ in 0..<entryCount {
            let entry = try nextBox(at: cursor, parentEnd: box.end)
            switch entry.type {
            case "encv":
                let priorTencCount = tencCount
                try scanEncryptedSampleEntry(entry, headerLength: 78, depth: depth + 1)
                guard tencCount == priorTencCount + 1 else {
                    throw WidevineDASHProviderError.invalidEncryptionMetadata
                }
            case "enca":
                let priorTencCount = tencCount
                try scanEncryptedSampleEntry(entry, headerLength: 28, depth: depth + 1)
                guard tencCount == priorTencCount + 1 else {
                    throw WidevineDASHProviderError.invalidEncryptionMetadata
                }
            case "uuid":
                throw WidevineDASHProviderError.keyRotationUnsupported
            default:
                // Switching to a different sample description could bypass
                // the tenc identity checked for this encrypted representation.
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
            cursor = entry.end
        }
        guard cursor == box.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private mutating func scanEncryptedSampleEntry(
        _ box: BoundedBMFFBox,
        headerLength: UInt64,
        depth: Int
    ) throws {
        guard box.payloadLength >= headerLength else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        try scanInitializationBoxes(
            from: box.payloadStart + headerLength,
            to: box.end,
            depth: depth,
            context: .encryptedSampleEntry
        )
    }

    private func validateTrackEncryption(_ box: BoundedBMFFBox) throws {
        guard box.payloadLength >= 24 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let prefix = [UInt8](try file.read(at: box.payloadStart, count: 24))
        let version = prefix[0]
        guard (version == 0 || version == 1),
              prefix[1] == 0, prefix[2] == 0, prefix[3] == 0,
              prefix[4] == 0,
              (version == 1 || prefix[5] == 0),
              prefix[6] == 1 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let perSampleIVSize = prefix[7]
        guard perSampleIVSize == 0 || perSampleIVSize == 8 || perSampleIVSize == 16 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        try validateEmbeddedKeyID(Data(prefix[8..<24]))
        if perSampleIVSize == 0 {
            guard box.payloadLength >= 25 else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
            let constantIVSize = Int(
                [UInt8](try file.read(at: box.payloadStart + 24, count: 1))[0]
            )
            guard (constantIVSize == 8 || constantIVSize == 16),
                  box.payloadLength == UInt64(25 + constantIVSize) else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
        } else if box.payloadLength != 24 {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private mutating func scanMovieFragment(
        _ moof: BoundedBMFFBox,
        depth: Int
    ) throws {
        try validateDepth(depth)
        var cursor = moof.payloadStart
        while cursor < moof.end {
            let box = try nextBox(at: cursor, parentEnd: moof.end)
            switch box.type {
            case "traf":
                try scanTrackFragment(box, depth: depth + 1)
            case "uuid":
                throw WidevineDASHProviderError.keyRotationUnsupported
            default:
                break
            }
            cursor = box.end
        }
        guard cursor == moof.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private mutating func scanTrackFragment(
        _ traf: BoundedBMFFBox,
        depth: Int
    ) throws {
        try validateDepth(depth)
        var cursor = traf.payloadStart
        var hasSeigDescription = false
        var requiresSeigDescription = false
        while cursor < traf.end {
            let box = try nextBox(at: cursor, parentEnd: traf.end)
            switch box.type {
            case "sgpd":
                if try validateSampleGroupDescription(box) {
                    hasSeigDescription = true
                }
            case "sbgp":
                if try sampleToGroupRequiresDescription(box) {
                    requiresSeigDescription = true
                }
            case "senc":
                try rejectTrackEncryptionOverride(box)
            case "uuid":
                throw WidevineDASHProviderError.keyRotationUnsupported
            default:
                break
            }
            cursor = box.end
        }
        guard cursor == traf.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        guard !requiresSeigDescription || hasSeigDescription else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
    }

    /// Returns true when the box describes CENC sample-encryption groups.
    private func validateSampleGroupDescription(_ box: BoundedBMFFBox) throws -> Bool {
        guard box.payloadLength >= 8 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var cursor = box.payloadStart
        let fullBox = [UInt8](try file.read(at: cursor, count: 4))
        cursor += 4
        let groupingType = try fourCC(at: cursor)
        cursor += 4
        guard groupingType == "seig" else { return false }
        let version = fullBox[0]
        guard (version == 1 || version == 2),
              fullBox[1] == 0, fullBox[2] == 0, fullBox[3] == 0 else {
            // Version zero has no generic description length and is not
            // interpreted here. Unknown future layouts remain fail-closed.
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
        guard box.payloadLength >= (version == 2 ? 20 : 16) else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let defaultLength = UInt64(try uint32(at: cursor))
        cursor += 4
        var defaultGroupDescriptionIndex: UInt32 = 0
        if version == 2 {
            defaultGroupDescriptionIndex = try uint32(at: cursor)
            cursor += 4
        }
        let entryCount = Int(try uint32(at: cursor))
        cursor += 4
        guard cursor <= box.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        guard entryCount <= Self.maximumGroupEntries,
              UInt64(entryCount) <= (box.end - cursor) / 20 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        if defaultGroupDescriptionIndex > UInt32(entryCount) {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
        for _ in 0..<entryCount {
            let descriptionLength: UInt64
            if defaultLength == 0 {
                guard box.end - cursor >= 4 else {
                    throw WidevineDASHProviderError.invalidEncryptionMetadata
                }
                descriptionLength = UInt64(try uint32(at: cursor))
                cursor += 4
            } else {
                descriptionLength = defaultLength
            }
            guard descriptionLength >= 20,
                  descriptionLength <= box.end - cursor else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
            try validateSeigEntry(at: cursor, length: descriptionLength)
            cursor += descriptionLength
        }
        guard cursor == box.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        return entryCount > 0
    }

    private func validateSeigEntry(at offset: UInt64, length: UInt64) throws {
        let prefix = [UInt8](try file.read(at: offset, count: 20))
        guard prefix[0] == 0, prefix[2] == 1 else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
        let perSampleIVSize = prefix[3]
        guard perSampleIVSize == 0 || perSampleIVSize == 8 || perSampleIVSize == 16 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        try validateEmbeddedKeyID(Data(prefix[4..<20]))
        if perSampleIVSize == 0 {
            guard length >= 21 else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
            let constantIVSize = Int(
                [UInt8](try file.read(at: offset + 20, count: 1))[0]
            )
            guard (constantIVSize == 8 || constantIVSize == 16),
                  length == UInt64(21 + constantIVSize) else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
        } else if length != 20 {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    /// Returns true when at least one sample run references a group entry.
    private func sampleToGroupRequiresDescription(_ box: BoundedBMFFBox) throws -> Bool {
        guard box.payloadLength >= 8 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var cursor = box.payloadStart
        let fullBox = [UInt8](try file.read(at: cursor, count: 4))
        cursor += 4
        let groupingType = try fourCC(at: cursor)
        cursor += 4
        guard groupingType == "seig" else { return false }
        let version = fullBox[0]
        guard (version == 0 || version == 1),
              fullBox[1] == 0, fullBox[2] == 0, fullBox[3] == 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        guard box.payloadLength >= (version == 1 ? 16 : 12) else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        if version == 1 { cursor += 4 }
        let entryCount = Int(try uint32(at: cursor))
        cursor += 4
        guard entryCount <= Self.maximumGroupEntries,
              UInt64(entryCount) <= (box.end - cursor) / 8,
              cursor + UInt64(entryCount) * 8 == box.end else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        var requiresDescription = false
        for _ in 0..<entryCount {
            _ = try uint32(at: cursor) // sample_count
            let descriptionIndex = try uint32(at: cursor + 4)
            if descriptionIndex != 0 { requiresDescription = true }
            cursor += 8
        }
        return requiresDescription
    }

    private func rejectTrackEncryptionOverride(_ box: BoundedBMFFBox) throws {
        guard box.payloadLength >= 8 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        let fullBox = [UInt8](try file.read(at: box.payloadStart, count: 4))
        let version = fullBox[0]
        let flags = UInt32(fullBox[1]) << 16 | UInt32(fullBox[2]) << 8 | UInt32(fullBox[3])
        guard version == 0, flags & ~UInt32(0x000003) == 0 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        guard flags & 0x000001 == 0 else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
    }

    private func validateEmbeddedKeyID(_ data: Data) throws {
        guard let embeddedKeyID = WidevineKeyID.normalize(data) else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        guard embeddedKeyID == expectedKeyID else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
    }

    private mutating func nextBox(
        at offset: UInt64,
        parentEnd: UInt64
    ) throws -> BoundedBMFFBox {
        guard boxCount < Self.maximumBoxesPerObject,
              offset <= parentEnd,
              parentEnd - offset >= 8 else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        boxCount += 1
        let header = [UInt8](try file.read(at: offset, count: 8))
        let size32 = Self.uint32(header[0...3])
        let type = String(decoding: header[4...7], as: UTF8.self)
        let headerLength: UInt64
        let boxLength: UInt64
        switch size32 {
        case 0:
            headerLength = 8
            boxLength = parentEnd - offset
        case 1:
            guard parentEnd - offset >= 16 else {
                throw WidevineDASHProviderError.invalidEncryptionMetadata
            }
            headerLength = 16
            boxLength = Self.uint64(
                [UInt8](try file.read(at: offset + 8, count: 8))[0...7]
            )
        default:
            headerLength = 8
            boxLength = UInt64(size32)
        }
        guard boxLength >= headerLength,
              boxLength <= parentEnd - offset else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
        return BoundedBMFFBox(
            type: type,
            payloadStart: offset + headerLength,
            end: offset + boxLength
        )
    }

    private func validateDepth(_ depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw WidevineDASHProviderError.invalidEncryptionMetadata
        }
    }

    private func fourCC(at offset: UInt64) throws -> String {
        String(decoding: try file.read(at: offset, count: 4), as: UTF8.self)
    }

    private func uint32(at offset: UInt64) throws -> UInt32 {
        Self.uint32([UInt8](try file.read(at: offset, count: 4))[0...3])
    }

    private static func uint32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

struct WidevineDASHSegmentReference: Equatable, Sendable {
    let url: URL
    let referer: URL
    let byteRange: ByteRange?
}

struct WidevineDASHTrackPlan: Equatable, Sendable {
    let mediaType: DASHMediaType
    let representationID: String
    let bandwidth: UInt64?
    let keyID: String
    let scheme: DASHCommonEncryptionScheme?
    let psshData: [Data]
    let initialization: WidevineDASHSegmentReference
    let segments: [WidevineDASHSegmentReference]
}

struct WidevineDASHDownloadPlan: Equatable, Sendable {
    let video: WidevineDASHTrackPlan?
    let audio: WidevineDASHTrackPlan?
    let psshData: [Data]
    let expectedKeyIDs: Set<String>

    /// Output is selected from parsed/selected media tracks, never from a URL
    /// extension or representation filename.
    var outputFormat: MediaOutputFormat { video == nil ? .wav : .mp4 }
}

struct WidevineDASHPlanner {
    static let maximumSegmentsPerTrack = 100_000

    func makePlan(manifest: DASHManifest) throws -> WidevineDASHDownloadPlan {
        guard manifest.presentationType != .dynamic else {
            throw WidevineDASHProviderError.dynamicPresentationUnsupported
        }
        let periods = manifest.periods.filter { !$0.adaptationSets.isEmpty }
        guard periods.count <= 1 else {
            throw WidevineDASHProviderError.multiplePeriodsUnsupported
        }
        guard let period = periods.first else {
            throw WidevineDASHProviderError.noSupportedTracks
        }

        let video = try selectedTrack(
            mediaType: .video,
            manifest: manifest,
            period: period
        )
        let audio = try selectedTrack(
            mediaType: .audio,
            manifest: manifest,
            period: period
        )
        guard video != nil || audio != nil else {
            throw WidevineDASHProviderError.noSupportedTracks
        }

        var seenPSSH = Set<Data>()
        // Do not send init data from an unselected Representation to the
        // license server. It may describe unrelated KIDs and can make an
        // otherwise single-key selected track look like key rotation.
        let psshData = [video, audio]
            .compactMap { $0 }
            .flatMap(\.psshData)
            .filter { seenPSSH.insert($0).inserted }
        guard !psshData.isEmpty else { throw WidevineDASHProviderError.psshMissing }

        let expectedKeyIDs = Set([video?.keyID, audio?.keyID].compactMap { $0 })
        return WidevineDASHDownloadPlan(
            video: video,
            audio: audio,
            psshData: psshData,
            expectedKeyIDs: expectedKeyIDs
        )
    }

    private func selectedTrack(
        mediaType: DASHMediaType,
        manifest: DASHManifest,
        period: DASHPeriod
    ) throws -> WidevineDASHTrackPlan? {
        let candidates = period.adaptationSets.flatMap { adaptation in
            adaptation.representations.compactMap { representation -> TrackCandidate? in
                let resolvedType = representation.mediaType == .unknown
                    ? adaptation.mediaType : representation.mediaType
                guard resolvedType == mediaType,
                      isMP4Representation(representation, adaptation: adaptation) else {
                    return nil
                }
                return TrackCandidate(adaptation: adaptation, representation: representation)
            }
        }
        guard !candidates.isEmpty else { return nil }
        let selected = candidates.max { lhs, rhs in
            score(lhs.representation, mediaType: mediaType)
                < score(rhs.representation, mediaType: mediaType)
        }!
        let representationID = normalizedRepresentationID(selected.representation.id)

        let protections = manifest.contentProtections
            + period.contentProtections
            + selected.adaptation.contentProtections
            + selected.representation.contentProtections
        let declaredKeyIDs = Set(
            protections.flatMap(\.defaultKeyIDs).compactMap(WidevineKeyID.normalize)
        )
        let psshKeyIDs = Set(
            protections.flatMap { $0.psshBoxes.flatMap(\.keyIDs) }
                .compactMap(WidevineKeyID.normalize)
        )
        // A global v1 PSSH can list the keys for several AdaptationSets. The
        // nearest cenc:default_KID is therefore authoritative for one selected
        // representation; PSSH KIDs are only a fallback when no default exists.
        let keyIDs = declaredKeyIDs.isEmpty ? psshKeyIDs : declaredKeyIDs
        guard !keyIDs.isEmpty else { throw WidevineDASHProviderError.keyIDMissing }
        guard keyIDs.count == 1, let keyID = keyIDs.first else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
        let schemes = Set(protections.compactMap(\.commonEncryptionScheme))
        guard schemes.count <= 1 else {
            throw WidevineDASHProviderError.keyRotationUnsupported
        }
        var seenPSSH = Set<Data>()
        let psshData = protections
            .flatMap(\.psshBoxes)
            .filter {
                $0.systemID.caseInsensitiveCompare(DASHManifestParser.widevineSystemID)
                    == .orderedSame
            }
            .map(\.rawData)
            .filter { seenPSSH.insert($0).inserted }

        let baseURL = selected.representation.baseURLs.compactMap(\.resolvedURL).first
            ?? selected.adaptation.baseURLs.compactMap(\.resolvedURL).first
            ?? period.baseURLs.compactMap(\.resolvedURL).first
            ?? manifest.baseURLs.compactMap(\.resolvedURL).first
            ?? manifest.effectiveURL
        let template = mergedTemplate(
            manifest.segmentTemplate,
            period.segmentTemplate,
            selected.adaptation.segmentTemplate,
            selected.representation.segmentTemplate
        )
        let list = mergedList(
            manifest.segmentList,
            period.segmentList,
            selected.adaptation.segmentList,
            selected.representation.segmentList
        )
        let references: (WidevineDASHSegmentReference, [WidevineDASHSegmentReference])
        if let template {
            references = try templateReferences(
                template,
                representation: selected.representation,
                baseURL: baseURL,
                referer: manifest.effectiveURL,
                periodDuration: period.duration ?? manifest.mediaPresentationDuration,
                rootURL: manifest.effectiveURL
            )
        } else if let list {
            references = try listReferences(
                list,
                baseURL: baseURL,
                referer: manifest.effectiveURL,
                rootURL: manifest.effectiveURL
            )
        } else {
            throw WidevineDASHProviderError.segmentAddressingMissing
        }

        return WidevineDASHTrackPlan(
            mediaType: mediaType,
            representationID: representationID ?? "",
            bandwidth: selected.representation.bandwidth,
            keyID: keyID,
            scheme: schemes.first,
            psshData: psshData,
            initialization: references.0,
            segments: references.1
        )
    }

    private struct TrackCandidate {
        let adaptation: DASHAdaptationSet
        let representation: DASHRepresentation
    }

    private func score(
        _ representation: DASHRepresentation,
        mediaType: DASHMediaType
    ) -> (UInt64, UInt64) {
        let area: UInt64
        if mediaType == .video,
           let width = representation.width,
           let height = representation.height {
            let (product, overflow) = width.multipliedReportingOverflow(by: height)
            area = overflow ? UInt64.max : product
        } else {
            area = 0
        }
        return (area, representation.bandwidth ?? 0)
    }

    private func isMP4Representation(
        _ representation: DASHRepresentation,
        adaptation: DASHAdaptationSet
    ) -> Bool {
        let mime = (representation.mimeType ?? adaptation.mimeType ?? "").lowercased()
        return mime == "video/mp4" || mime == "audio/mp4" || mime == "application/mp4"
    }

    private func mergedTemplate(_ levels: DASHSegmentTemplate?...) -> DASHSegmentTemplate? {
        var result: DASHSegmentTemplate?
        for value in levels.compactMap({ $0 }) {
            guard let current = result else {
                result = value
                continue
            }
            result = DASHSegmentTemplate(
                initialization: value.initialization ?? current.initialization,
                media: value.media ?? current.media,
                index: value.index ?? current.index,
                timescale: value.timescale ?? current.timescale,
                duration: value.duration ?? current.duration,
                startNumber: value.startNumber ?? current.startNumber,
                presentationTimeOffset: value.presentationTimeOffset ?? current.presentationTimeOffset,
                endNumber: value.endNumber ?? current.endNumber,
                timeline: value.timeline.isEmpty ? current.timeline : value.timeline
            )
        }
        return result
    }

    private func mergedList(_ levels: DASHSegmentList?...) -> DASHSegmentList? {
        var result: DASHSegmentList?
        for value in levels.compactMap({ $0 }) {
            guard let current = result else {
                result = value
                continue
            }
            result = DASHSegmentList(
                timescale: value.timescale ?? current.timescale,
                duration: value.duration ?? current.duration,
                startNumber: value.startNumber ?? current.startNumber,
                presentationTimeOffset: value.presentationTimeOffset ?? current.presentationTimeOffset,
                initializationSourceURL: value.initializationSourceURL ?? current.initializationSourceURL,
                initializationRange: value.initializationRange ?? current.initializationRange,
                segmentURLs: value.segmentURLs.isEmpty ? current.segmentURLs : value.segmentURLs
            )
        }
        return result
    }

    private func templateReferences(
        _ template: DASHSegmentTemplate,
        representation: DASHRepresentation,
        baseURL: URL,
        referer: URL,
        periodDuration: String?,
        rootURL: URL
    ) throws -> (WidevineDASHSegmentReference, [WidevineDASHSegmentReference]) {
        guard let initializationTemplate = template.initialization,
              let mediaTemplate = template.media else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        let startNumber = template.startNumber ?? 1
        let points = try segmentPoints(
            template: template,
            periodDuration: periodDuration,
            startNumber: startNumber
        )
        guard !points.isEmpty, points.count <= Self.maximumSegmentsPerTrack else {
            throw WidevineDASHProviderError.segmentLimitExceeded
        }
        let initializationValue = try expandTemplate(
            initializationTemplate,
            representationID: normalizedRepresentationID(representation.id),
            bandwidth: representation.bandwidth,
            number: startNumber,
            time: points.first?.time ?? 0
        )
        let initialization = WidevineDASHSegmentReference(
            url: try resolvedSegmentURL(initializationValue, baseURL: baseURL, rootURL: rootURL),
            referer: referer,
            byteRange: nil
        )
        let segments = try points.map { point in
            let value = try expandTemplate(
                mediaTemplate,
                representationID: normalizedRepresentationID(representation.id),
                bandwidth: representation.bandwidth,
                number: point.number,
                time: point.time
            )
            return WidevineDASHSegmentReference(
                url: try resolvedSegmentURL(value, baseURL: baseURL, rootURL: rootURL),
                referer: referer,
                byteRange: nil
            )
        }
        return (initialization, segments)
    }

    private func normalizedRepresentationID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct SegmentPoint {
        let number: UInt64
        let time: UInt64
    }

    private func segmentPoints(
        template: DASHSegmentTemplate,
        periodDuration: String?,
        startNumber: UInt64
    ) throws -> [SegmentPoint] {
        if !template.timeline.isEmpty {
            return try timelinePoints(template: template, startNumber: startNumber, periodDuration: periodDuration)
        }
        guard let duration = template.duration, duration > 0 else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        let count: UInt64
        if let endNumber = template.endNumber, endNumber >= startNumber {
            count = try inclusiveCount(from: startNumber, through: endNumber)
        } else if let periodDuration,
                  let seconds = parseISODuration(periodDuration),
                  seconds > 0 {
            let timescale = Double(template.timescale ?? 1)
            let calculatedCount = ceil(seconds * timescale / Double(duration))
            guard calculatedCount.isFinite,
                  calculatedCount > 0,
                  calculatedCount <= Double(Self.maximumSegmentsPerTrack) else {
                throw WidevineDASHProviderError.segmentLimitExceeded
            }
            count = UInt64(calculatedCount)
        } else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        guard count > 0, count <= UInt64(Self.maximumSegmentsPerTrack) else {
            throw WidevineDASHProviderError.segmentLimitExceeded
        }
        var result: [SegmentPoint] = []
        result.reserveCapacity(Int(count))
        for offset in 0..<count {
            let (number, numberOverflow) = startNumber.addingReportingOverflow(offset)
            let (time, timeOverflow) = offset.multipliedReportingOverflow(by: duration)
            guard !numberOverflow, !timeOverflow else {
                throw WidevineDASHProviderError.invalidSegmentTemplate
            }
            result.append(SegmentPoint(number: number, time: time))
        }
        return result
    }

    private func timelinePoints(
        template: DASHSegmentTemplate,
        startNumber: UInt64,
        periodDuration: String?
    ) throws -> [SegmentPoint] {
        var result: [SegmentPoint] = []
        var currentTime: UInt64 = 0
        var number = startNumber
        for (index, entry) in template.timeline.enumerated() {
            guard let duration = entry.duration, duration > 0 else {
                throw WidevineDASHProviderError.invalidSegmentTemplate
            }
            if let start = entry.startTime {
                guard start >= 0 else { throw WidevineDASHProviderError.invalidSegmentTemplate }
                currentTime = UInt64(start)
            }
            let repeatCount: UInt64
            switch entry.repeatCount ?? 0 {
            case let repeatValue where repeatValue >= 0:
                repeatCount = UInt64(repeatValue) + 1
            case -1:
                if index + 1 < template.timeline.count,
                   let nextStart = template.timeline[index + 1].startTime,
                   nextStart >= 0,
                   UInt64(nextStart) > currentTime {
                    repeatCount = ceilingDivision(
                        UInt64(nextStart) - currentTime,
                        by: duration
                    )
                } else if let endNumber = template.endNumber, endNumber >= number {
                    repeatCount = try inclusiveCount(from: number, through: endNumber)
                } else if let periodDuration,
                          let seconds = parseISODuration(periodDuration) {
                    let scaled = ceil(seconds * Double(template.timescale ?? 1))
                    guard scaled.isFinite,
                          scaled > 0,
                          scaled <= Double(Int64.max) else {
                        throw WidevineDASHProviderError.invalidSegmentTemplate
                    }
                    let scaledDuration = UInt64(scaled)
                    guard scaledDuration > currentTime else {
                        throw WidevineDASHProviderError.invalidSegmentTemplate
                    }
                    repeatCount = ceilingDivision(
                        scaledDuration - currentTime,
                        by: duration
                    )
                } else {
                    throw WidevineDASHProviderError.invalidSegmentTemplate
                }
            default:
                throw WidevineDASHProviderError.invalidSegmentTemplate
            }
            guard repeatCount > 0,
                  repeatCount <= UInt64(Self.maximumSegmentsPerTrack - result.count) else {
                throw WidevineDASHProviderError.segmentLimitExceeded
            }
            for _ in 0..<repeatCount {
                result.append(SegmentPoint(number: number, time: currentTime))
                let (nextTime, timeOverflow) = currentTime.addingReportingOverflow(duration)
                let (nextNumber, numberOverflow) = number.addingReportingOverflow(1)
                guard !timeOverflow, !numberOverflow else {
                    throw WidevineDASHProviderError.invalidSegmentTemplate
                }
                currentTime = nextTime
                number = nextNumber
            }
        }
        return result
    }

    private func ceilingDivision(_ value: UInt64, by divisor: UInt64) -> UInt64 {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }

    private func inclusiveCount(from start: UInt64, through end: UInt64) throws -> UInt64 {
        let (distance, underflow) = end.subtractingReportingOverflow(start)
        let (count, overflow) = distance.addingReportingOverflow(1)
        guard !underflow, !overflow else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        return count
    }

    private func listReferences(
        _ list: DASHSegmentList,
        baseURL: URL,
        referer: URL,
        rootURL: URL
    ) throws -> (WidevineDASHSegmentReference, [WidevineDASHSegmentReference]) {
        let initializationURL: URL
        if let source = list.initializationSourceURL {
            initializationURL = try resolvedSegmentURL(source, baseURL: baseURL, rootURL: rootURL)
        } else if list.initializationRange != nil {
            initializationURL = try validatedSegmentURL(baseURL, rootURL: rootURL)
        } else {
            throw WidevineDASHProviderError.segmentAddressingMissing
        }
        let initialization = WidevineDASHSegmentReference(
            url: initializationURL,
            referer: referer,
            byteRange: try parseRange(list.initializationRange)
        )
        guard !list.segmentURLs.isEmpty,
              list.segmentURLs.count <= Self.maximumSegmentsPerTrack else {
            throw WidevineDASHProviderError.segmentLimitExceeded
        }
        let segments = try list.segmentURLs.map { segment in
            let url: URL
            if let media = segment.media {
                url = try resolvedSegmentURL(media, baseURL: baseURL, rootURL: rootURL)
            } else if segment.mediaRange != nil {
                url = try validatedSegmentURL(baseURL, rootURL: rootURL)
            } else {
                throw WidevineDASHProviderError.segmentAddressingMissing
            }
            return WidevineDASHSegmentReference(
                url: url,
                referer: referer,
                byteRange: try parseRange(segment.mediaRange)
            )
        }
        return (initialization, segments)
    }

    private func parseRange(_ rawValue: String?) throws -> ByteRange? {
        guard let rawValue else { return nil }
        let parts = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        guard parts.count == 2,
              let start = UInt64(parts[0]),
              let end = UInt64(parts[1]),
              end >= start,
              start <= UInt64(Int64.max),
              end <= UInt64(Int64.max) else {
            throw WidevineDASHProviderError.invalidSegmentRange
        }
        let length = end - start + 1
        guard length <= UInt64(Int64.max) else {
            throw WidevineDASHProviderError.invalidSegmentRange
        }
        return ByteRange(offset: Int64(start), length: Int64(length))
    }

    private func resolvedSegmentURL(
        _ rawValue: String,
        baseURL: URL,
        rootURL: URL
    ) throws -> URL {
        guard let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else {
            throw WidevineDASHProviderError.unsafeSegmentURL
        }
        return try validatedSegmentURL(url, rootURL: rootURL)
    }

    private func validatedSegmentURL(_ url: URL, rootURL: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              AutomaticNavigationPolicy.isAllowedFrameNavigation(from: rootURL, to: url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WidevineDASHProviderError.unsafeSegmentURL
        }
        components.fragment = nil
        guard let normalized = components.url else {
            throw WidevineDASHProviderError.unsafeSegmentURL
        }
        return normalized
    }

    private func expandTemplate(
        _ template: String,
        representationID: String?,
        bandwidth: UInt64?,
        number: UInt64,
        time: UInt64
    ) throws -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "$" else {
                result.append(template[index])
                index = template.index(after: index)
                continue
            }
            let tokenStart = template.index(after: index)
            if tokenStart < template.endIndex, template[tokenStart] == "$" {
                result.append("$")
                index = template.index(after: tokenStart)
                continue
            }
            guard let tokenEnd = template[tokenStart...].firstIndex(of: "$") else {
                throw WidevineDASHProviderError.invalidSegmentTemplate
            }
            let token = String(template[tokenStart..<tokenEnd])
            result += try templateValue(
                token,
                representationID: representationID,
                bandwidth: bandwidth,
                number: number,
                time: time
            )
            index = template.index(after: tokenEnd)
        }
        guard !result.isEmpty, result.utf8.count <= 16_384 else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        return result
    }

    private func templateValue(
        _ token: String,
        representationID: String?,
        bandwidth: UInt64?,
        number: UInt64,
        time: UInt64
    ) throws -> String {
        let components = token.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(components[0])
        let numericValue: UInt64?
        switch name {
        case "RepresentationID":
            guard components.count == 1, let representationID else {
                throw WidevineDASHProviderError.invalidSegmentTemplate
            }
            return representationID
        case "Bandwidth": numericValue = bandwidth
        case "Number": numericValue = number
        case "Time": numericValue = time
        default: throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        guard let numericValue else { throw WidevineDASHProviderError.invalidSegmentTemplate }
        guard components.count == 2 else { return String(numericValue) }
        let format = String(components[1])
        guard format.hasPrefix("0"), format.hasSuffix("d"),
              let width = Int(format.dropFirst().dropLast()),
              (1...20).contains(width) else {
            throw WidevineDASHProviderError.invalidSegmentTemplate
        }
        return String(format: "%0*llu", width, numericValue)
    }

    private func parseISODuration(_ value: String) -> Double? {
        let pattern = #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.range == NSRange(value.startIndex..<value.endIndex, in: value) else {
            return nil
        }
        func capture(_ index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: value) else { return 0 }
            return Double(value[swiftRange]) ?? 0
        }
        let result = capture(1) * 86_400 + capture(2) * 3_600 + capture(3) * 60 + capture(4)
        return result.isFinite ? result : nil
    }
}

private enum WidevineKeyID {
    static func normalize(_ value: String) -> String? {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "urn:uuid:", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard compact.count == 32,
              compact.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            return nil
        }
        return [8, 4, 4, 4, 12].reduce(into: (parts: [String](), index: compact.startIndex)) {
            state, length in
            let end = compact.index(state.index, offsetBy: length)
            state.parts.append(String(compact[state.index..<end]))
            state.index = end
        }.parts.joined(separator: "-")
    }

    static func normalize(_ value: Data) -> String? {
        guard value.count == 16 else { return nil }
        let hex = value.map { String(format: "%02x", $0) }.joined()
        return normalize(hex)
    }
}
