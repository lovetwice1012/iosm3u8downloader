package com.example.hlsdownloader.core

sealed class HlsException(
    val code: Code,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    enum class Code {
        INVALID_URL,
        UNSUPPORTED_SCHEME,
        NETWORK,
        HTTP_STATUS,
        NO_PLAYLIST_FOUND,
        HTML_TOO_LARGE,
        INVALID_PLAYLIST,
        LIVE_PLAYLIST_UNSUPPORTED,
        DRM_UNSUPPORTED,
        GAP_UNSUPPORTED,
        INVALID_AES_KEY,
        DECRYPTION_FAILED,
        BYTE_RANGE_INVALID,
        INVALID_MEDIA_PAYLOAD,
        REMUX_FAILED,
        NO_PLAYABLE_TRACKS,
        MP4_EXPORT_UNSUPPORTED,
        EXPORT_FAILED,
        CANCELLED,
    }

    class InvalidUrl : HlsException(Code.INVALID_URL, "URLを確認してください。")
    class UnsupportedScheme : HlsException(
        Code.UNSUPPORTED_SCHEME,
        "http または https のURLだけを利用できます。",
    )
    class Network(detail: String, cause: Throwable? = null) : HlsException(
        Code.NETWORK,
        "通信に失敗しました: $detail",
        cause,
    )
    class HttpStatus(val status: Int, val host: String) : HlsException(
        Code.HTTP_STATUS,
        "$host が HTTP $status を返しました。URLの期限や認証を確認してください。",
    )
    class NoPlaylistFound : HlsException(
        Code.NO_PLAYLIST_FOUND,
        "ページ内に利用できるm3u8を見つけられませんでした。",
    )
    class HtmlTooLarge : HlsException(
        Code.HTML_TOO_LARGE,
        "HTMLが大きすぎるため安全に解析できませんでした。",
    )
    class InvalidPlaylist(detail: String) : HlsException(
        Code.INVALID_PLAYLIST,
        "HLSプレイリストを解析できません: $detail",
    )
    class LivePlaylistUnsupported : HlsException(
        Code.LIVE_PLAYLIST_UNSUPPORTED,
        "終了位置のないライブ配信には対応していません。",
    )
    class DrmUnsupported(method: String) : HlsException(
        Code.DRM_UNSUPPORTED,
        "$method 暗号化またはDRMには対応していません。",
    )
    class GapUnsupported : HlsException(
        Code.GAP_UNSUPPORTED,
        "欠損断片を含むHLSには対応していません。",
    )
    class InvalidAesKey : HlsException(
        Code.INVALID_AES_KEY,
        "AES-128鍵が16バイトではありません。",
    )
    class DecryptionFailed(cause: Throwable? = null) : HlsException(
        Code.DECRYPTION_FAILED,
        "AES-128断片の復号に失敗しました。",
        cause,
    )
    class ByteRangeInvalid : HlsException(
        Code.BYTE_RANGE_INVALID,
        "HLSのバイト範囲が不正です。",
    )
    class InvalidMediaPayload(
        val stream: String,
        val number: Int,
        val mimeType: String?,
        val byteCount: Int,
        val signature: String,
    ) : HlsException(
        Code.INVALID_MEDIA_PAYLOAD,
        "$stream 断片${number}がメディアデータではありません。",
    )
    class RemuxFailed(detail: String, cause: Throwable? = null) : HlsException(
        Code.REMUX_FAILED,
        "MP4への変換に失敗しました: $detail",
        cause,
    )
    class NoPlayableTracks : HlsException(
        Code.NO_PLAYABLE_TRACKS,
        "結合できる映像または音声トラックがありません。",
    )
    class Mp4ExportUnsupported : HlsException(
        Code.MP4_EXPORT_UNSUPPORTED,
        "このHLSは端末上でMP4へ変換できません。",
    )
    class ExportFailed(detail: String, cause: Throwable? = null) : HlsException(
        Code.EXPORT_FAILED,
        "MP4の作成に失敗しました: $detail",
        cause,
    )
    class Cancelled : HlsException(Code.CANCELLED, "処理をキャンセルしました。")
}

internal fun Throwable.asHlsCancellation(): Throwable =
    if (this is kotlinx.coroutines.CancellationException) HlsException.Cancelled() else this
