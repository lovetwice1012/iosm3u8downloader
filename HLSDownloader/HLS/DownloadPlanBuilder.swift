import Foundation

final class DownloadPlanBuilder: Sendable {
    private let resolver: SourceResolver

    init(resolver: SourceResolver) {
        self.resolver = resolver
    }

    func build(from initialDocument: PlaylistDocument) async throws -> DownloadPlan {
        var document = initialDocument
        var selectedAudio: URLCandidates?
        let requestReferer = initialDocument.referer ?? initialDocument.effectiveURL

        for _ in 0..<6 {
            switch try PlaylistParser.parse(
                text: document.text,
                effectiveURL: document.effectiveURL,
                requestReferer: requestReferer
            ) {
            case .media(let media):
                guard media.hasEndList else { throw HLSError.livePlaylistUnsupported }
                let audio = try await loadAudio(selectedAudio, referer: requestReferer)
                return DownloadPlan(sourceURL: initialDocument.effectiveURL, main: media, audio: audio)

            case .master(let master):
                let variant = selectVariant(master.variants)
                if let groupID = variant.audioGroupID,
                   let rendition = selectAudioRendition(master.renditions, groupID: groupID) {
                    selectedAudio = rendition.url
                }
                document = try await resolver.load(variant.url, referer: requestReferer)
            }
        }
        throw HLSError.invalidPlaylist("master playlistの入れ子が深すぎます")
    }

    private func loadAudio(_ candidates: URLCandidates?, referer: URL?) async throws -> MediaPlaylist? {
        guard let candidates else { return nil }
        var document = try await resolver.load(candidates, referer: referer)

        for _ in 0..<4 {
            switch try PlaylistParser.parse(
                text: document.text,
                effectiveURL: document.effectiveURL,
                requestReferer: referer
            ) {
            case .media(let media):
                guard media.hasEndList else { throw HLSError.livePlaylistUnsupported }
                return media
            case .master(let master):
                document = try await resolver.load(selectVariant(master.variants).url, referer: referer)
            }
        }
        throw HLSError.invalidPlaylist("音声playlistの入れ子が深すぎます")
    }

    private func selectVariant(_ variants: [Variant]) -> Variant {
        variants.max {
            ($0.averageBandwidth ?? $0.bandwidth) < ($1.averageBandwidth ?? $1.bandwidth)
        } ?? variants[0]
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
}
