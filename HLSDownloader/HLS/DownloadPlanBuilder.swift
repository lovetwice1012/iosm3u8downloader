import Foundation

enum HLSResolutionCatalog {
    static func options(from document: PlaylistDocument?) -> [HLSResolutionOption] {
        guard let document,
              let parsed = try? PlaylistParser.parse(
                text: document.text,
                effectiveURL: document.effectiveURL,
                requestReferer: document.referer
              ),
              case .master(let master) = parsed else {
            return []
        }
        return options(from: master.variants)
    }

    static func options(from variants: [Variant]) -> [HLSResolutionOption] {
        var bestByResolution: [MediaResolution: Int] = [:]
        for variant in variants {
            guard let resolution = MediaResolution(hlsAttribute: variant.resolution) else { continue }
            let bandwidth = effectiveBandwidth(variant)
            bestByResolution[resolution] = max(bestByResolution[resolution] ?? 0, bandwidth)
        }
        return bestByResolution.map {
            HLSResolutionOption(resolution: $0.key, bandwidth: $0.value)
        }.sorted { lhs, rhs in
            if lhs.resolution.pixelCount != rhs.resolution.pixelCount {
                return lhs.resolution.pixelCount > rhs.resolution.pixelCount
            }
            if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
            return lhs.resolution.id > rhs.resolution.id
        }
    }

    static func selectVariant(
        _ variants: [Variant],
        preferredResolution: MediaResolution?
    ) throws -> Variant {
        let candidates: [Variant]
        if let preferredResolution {
            candidates = variants.filter {
                MediaResolution(hlsAttribute: $0.resolution) == preferredResolution
            }
            guard !candidates.isEmpty else {
                throw HLSError.invalidPlaylist("選択した解像度は現在のmaster playlistにありません")
            }
        } else {
            candidates = variants
        }
        guard let selected = candidates.max(by: {
            effectiveBandwidth($0) < effectiveBandwidth($1)
        }) else {
            throw HLSError.invalidPlaylist("画質variantがありません")
        }
        return selected
    }

    private static func effectiveBandwidth(_ variant: Variant) -> Int {
        max(variant.averageBandwidth ?? variant.bandwidth, 0)
    }
}

struct PreparedDownloadPlan: Sendable {
    let plan: DownloadPlan
    let mainRequestedURL: URL
    let audioRequestedURL: URL?

    var containsSampleAES: Bool {
        mainContainsSampleAES || audioContainsSampleAES
    }

    var mainContainsSampleAES: Bool {
        Self.containsSampleAES(plan.main)
    }

    var audioContainsSampleAES: Bool {
        plan.audio.map(Self.containsSampleAES) == true
    }

    var hasMixedSampleAESRenditionEncryption: Bool {
        plan.audio != nil && mainContainsSampleAES != audioContainsSampleAES
    }

    var containsAES128: Bool {
        Self.containsMethod(.aes128, in: plan.main)
            || plan.audio.map { Self.containsMethod(.aes128, in: $0) } == true
    }

    func validateSampleAESPermit() throws {
        guard containsSampleAES else { return }
        guard !hasMixedSampleAESRenditionEncryption else {
            throw HLSError.drmUnsupported("mixed SAMPLE-AES rendition encryption")
        }
        if mainContainsSampleAES {
            guard isDownloadableWidevineDomain(mainRequestedURL),
                  isDownloadableWidevineDomain(plan.main.effectiveURL) else {
                throw HLSError.drmUnsupported("SAMPLE-AES main playlist domain not allowed")
            }
        }
        if audioContainsSampleAES, let audio = plan.audio {
            guard let audioRequestedURL,
                  isDownloadableWidevineDomain(audioRequestedURL),
                  isDownloadableWidevineDomain(audio.effectiveURL) else {
                throw HLSError.drmUnsupported("SAMPLE-AES audio playlist domain not allowed")
            }
        }
    }

    private static func containsSampleAES(_ playlist: MediaPlaylist) -> Bool {
        containsMethod(.sampleAES, in: playlist)
    }

    private static func containsMethod(
        _ method: EncryptionDescriptor.Method,
        in playlist: MediaPlaylist
    ) -> Bool {
        playlist.segments.contains { segment in
            segment.encryption?.method == method
                || segment.initializationMap?.encryption?.method == method
        }
    }
}

final class DownloadPlanBuilder: Sendable {
    private let resolver: SourceResolver

    init(resolver: SourceResolver) {
        self.resolver = resolver
    }

    func build(
        from initialDocument: PlaylistDocument,
        requestedURL initialRequestedURL: URL? = nil,
        preferredResolution: MediaResolution? = nil
    ) async throws -> PreparedDownloadPlan {
        var document = initialDocument
        var requestedURL = initialRequestedURL ?? initialDocument.effectiveURL
        var selectedAudio: URLCandidates?
        var unresolvedPreferredResolution = preferredResolution
        let requestReferer = initialDocument.referer ?? initialDocument.effectiveURL

        for _ in 0..<6 {
            switch try PlaylistParser.parse(
                text: document.text,
                effectiveURL: document.effectiveURL,
                requestReferer: requestReferer
            ) {
            case .media(let media):
                guard media.hasEndList else { throw HLSError.livePlaylistUnsupported }
                try validateForDownload(media)
                let audioSelection = try await loadAudio(selectedAudio, referer: requestReferer)
                let prepared = PreparedDownloadPlan(
                    plan: DownloadPlan(
                        sourceURL: initialDocument.effectiveURL,
                        main: media,
                        audio: audioSelection?.playlist
                    ),
                    mainRequestedURL: requestedURL,
                    audioRequestedURL: audioSelection?.requestedURL
                )
                try prepared.validateSampleAESPermit()
                return prepared

            case .master(let master):
                let variant = try HLSResolutionCatalog.selectVariant(
                    master.variants,
                    preferredResolution: unresolvedPreferredResolution
                )
                unresolvedPreferredResolution = nil
                if let groupID = variant.audioGroupID,
                   let rendition = selectAudioRendition(master.renditions, groupID: groupID) {
                    selectedAudio = rendition.url
                }
                requestedURL = variant.url.primary
                document = try await resolver.load(variant.url, referer: requestReferer)
            }
        }
        throw HLSError.invalidPlaylist("master playlistの入れ子が深すぎます")
    }

    private struct SelectedAudioPlaylist: Sendable {
        let playlist: MediaPlaylist
        let requestedURL: URL
    }

    private func loadAudio(
        _ candidates: URLCandidates?,
        referer: URL?
    ) async throws -> SelectedAudioPlaylist? {
        guard let candidates else { return nil }
        var requestedURL = candidates.primary
        var document = try await resolver.load(candidates, referer: referer)

        for _ in 0..<4 {
            switch try PlaylistParser.parse(
                text: document.text,
                effectiveURL: document.effectiveURL,
                requestReferer: referer
            ) {
            case .media(let media):
                guard media.hasEndList else { throw HLSError.livePlaylistUnsupported }
                try validateForDownload(media)
                return SelectedAudioPlaylist(playlist: media, requestedURL: requestedURL)
            case .master(let master):
                let variant = try HLSResolutionCatalog.selectVariant(
                    master.variants,
                    preferredResolution: nil
                )
                requestedURL = variant.url.primary
                document = try await resolver.load(variant.url, referer: referer)
            }
        }
        throw HLSError.invalidPlaylist("音声playlistの入れ子が深すぎます")
    }

    private func selectAudioRendition(_ renditions: [MediaRendition], groupID: String) -> MediaRendition? {
        renditions
            .filter { $0.type == "AUDIO" && $0.groupID == groupID && $0.url != nil }
            .sorted {
                let left = ($0.isDefault ? 2 : 0) + ($0.isAutoSelect ? 1 : 0)
                let right = ($1.isDefault ? 2 : 0) + ($1.isAutoSelect ? 1 : 0)
                return left > right
            }
            .first
    }

    private func validateForDownload(_ playlist: MediaPlaylist) throws {
        if playlist.segments.contains(where: \.hasDiscontinuity) {
            throw HLSError.invalidPlaylist("EXT-X-DISCONTINUITYを含むHLSは現在MP4化できません")
        }
    }
}
