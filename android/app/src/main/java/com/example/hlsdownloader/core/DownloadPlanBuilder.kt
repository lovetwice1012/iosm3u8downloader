package com.example.hlsdownloader.core

class DownloadPlanBuilder(private val resolver: SourceResolver) {
    suspend fun build(initialDocument: PlaylistDocument): DownloadPlan {
        var document = initialDocument
        var selectedAudio: UrlCandidates? = null
        val requestReferer = initialDocument.referer ?: initialDocument.effectiveUrl

        repeat(6) {
            when (
                val kind = PlaylistParser.parse(
                    document.text,
                    document.effectiveUrl,
                    requestReferer,
                )
            ) {
                is PlaylistKind.Media -> {
                    val media = kind.playlist
                    if (!media.hasEndList) throw HlsException.LivePlaylistUnsupported()
                    validateForDownload(media)
                    val audio = loadAudio(selectedAudio, requestReferer)
                    return DownloadPlan(initialDocument.effectiveUrl, media, audio)
                }
                is PlaylistKind.Master -> {
                    val variant = selectVariant(kind.playlist.variants)
                    variant.audioGroupId?.let { groupId ->
                        selectedAudio = selectAudioRendition(kind.playlist.renditions, groupId)?.url
                    }
                    document = resolver.load(variant.url, requestReferer)
                }
            }
        }
        throw HlsException.InvalidPlaylist("master playlistの入れ子が深すぎます")
    }

    private suspend fun loadAudio(candidates: UrlCandidates?, referer: okhttp3.HttpUrl?): MediaPlaylist? {
        if (candidates == null) return null
        var document = resolver.load(candidates, referer)
        repeat(4) {
            when (val kind = PlaylistParser.parse(document.text, document.effectiveUrl, referer)) {
                is PlaylistKind.Media -> {
                    if (!kind.playlist.hasEndList) throw HlsException.LivePlaylistUnsupported()
                    validateForDownload(kind.playlist)
                    return kind.playlist
                }
                is PlaylistKind.Master -> {
                    document = resolver.load(selectVariant(kind.playlist.variants).url, referer)
                }
            }
        }
        throw HlsException.InvalidPlaylist("音声playlistの入れ子が深すぎます")
    }

    private fun selectVariant(variants: List<Variant>): Variant =
        variants.maxByOrNull { it.averageBandwidth ?: it.bandwidth } ?: variants.first()

    private fun selectAudioRendition(
        renditions: List<MediaRendition>,
        groupId: String,
    ): MediaRendition? = renditions
        .asSequence()
        .filter { it.type == "AUDIO" && it.groupId == groupId && it.url != null }
        .sortedByDescending { (if (it.isDefault) 2 else 0) + (if (it.isAutoSelect) 1 else 0) }
        .firstOrNull()

    private fun validateForDownload(playlist: MediaPlaylist) {
        if (playlist.segments.any { it.hasDiscontinuity }) {
            throw HlsException.InvalidPlaylist("EXT-X-DISCONTINUITYを含むHLSには対応していません")
        }
    }
}
