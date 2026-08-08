import Foundation

typealias ProgressHandler = @Sendable (DownloadProgress) async -> Void

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

final class SegmentDownloader: Sendable {
    private let client: HTTPClient
    private let maximumConcurrentDownloads: Int
    private let permitPool: DownloadPermitPool

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

    private func downloadSegmentWithPermit(
        _ segment: MediaSegment,
        prefix: String,
        directory: URL,
        keyData: [URL: Data],
        mapData: [InitializationMap: Data],
        referer: URL
    ) async throws -> DownloadedSegment {
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
            return result
        } catch {
            await permitPool.release()
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
        var result: [InitializationMap: Data] = [:]

        for map in maps {
            result[map] = try await fetchMap(
                map,
                keyData: keyData,
                referer: playlist.requestReferer ?? playlist.effectiveURL
            )
        }
        return result
    }

    private func fetchMap(
        _ map: InitializationMap,
        keyData: [URL: Data],
        referer: URL
    ) async throws -> Data {
        var lastError: Error = HLSError.invalidPlaylist("初期化データを取得できません")
        for candidate in map.url.all {
            do {
                let response = try await client.fetch(candidate, referer: referer, byteRange: map.byteRange)
                var data = response.data
                if let encryption = map.encryption {
                    guard let key = keyData[encryption.keyURL.primary],
                          let iv = encryption.explicitIV else {
                        throw HLSError.invalidAESKey
                    }
                    data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
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
        let (mediaData, response, mediaContainer) = try await fetchMedia(
            segment,
            keyData: keyData,
            referer: referer,
            stream: prefix == "audio" ? "音声" : "映像"
        )
        let initializationData = segment.initializationMap.flatMap { mapData[$0] }
        let finalData: Data
        if let initializationData {
            var combined = Data(capacity: initializationData.count + mediaData.count)
            combined.append(initializationData)
            combined.append(mediaData)
            finalData = combined
        } else {
            finalData = mediaData
        }

        guard let finalContainer = MediaPayloadInspector.detect(finalData, mimeType: response.mimeType),
              finalContainer == mediaContainer else {
            throw invalidPayloadError(
                stream: prefix == "audio" ? "音声" : "映像",
                number: segment.ordinal + 1,
                response: response,
                data: finalData
            )
        }

        let name = String(format: "%@-%06d.%@", prefix, segment.ordinal, finalContainer.fileExtension)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try finalData.write(to: destination, options: .atomic)
        return DownloadedSegment(
            source: segment,
            fileURL: destination,
            container: finalContainer,
            byteCount: finalData.count,
            initializationDataLength: initializationData?.count ?? 0
        )
    }

    private func fetchMedia(
        _ segment: MediaSegment,
        keyData: [URL: Data],
        referer: URL,
        stream: String
    ) async throws -> (Data, HTTPPayload, MediaContainer) {
        var lastError: Error = HLSError.invalidPlaylist("断片を取得できません")
        for candidate in segment.url.all {
            do {
                let response = try await client.fetch(candidate, referer: referer, byteRange: segment.byteRange)
                var data = response.data
                if let encryption = segment.encryption {
                    guard let key = keyData[encryption.keyURL.primary] else {
                        throw HLSError.invalidAESKey
                    }
                    let iv = encryption.explicitIV
                        ?? AES128CBCDecryptor.initializationVector(for: segment.mediaSequence)
                    data = try AES128CBCDecryptor.decrypt(data, key: key, iv: iv)
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
                return (data, response, container)
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
