import Foundation

enum DownloadPhase: String, Sendable {
    case idle
    case resolving
    case downloading
    case composing
    case completed

    var title: String {
        switch self {
        case .idle: return "待機中"
        case .resolving: return "リンクを解析中"
        case .downloading: return "断片をダウンロード中"
        case .composing: return "MP4に結合中"
        case .completed: return "完了"
        }
    }
}

struct DownloadProgress: Sendable {
    let phase: DownloadPhase
    let completedItems: Int
    let totalItems: Int

    var fraction: Double? {
        guard totalItems > 0 else { return nil }
        return min(max(Double(completedItems) / Double(totalItems), 0), 1)
    }
}

struct DownloadResult: Sendable {
    let outputURL: URL
    let sourceURL: URL
    let segmentCount: Int
}

struct PlaylistDocument: Sendable {
    let text: String
    let effectiveURL: URL
    let referer: URL?
}

enum HLSCandidateOrigin: String, Hashable, Sendable {
    case direct
    case video
    case source
    case inlineScript
    case iframe
    case runtime

    var title: String {
        switch self {
        case .direct: return "m3u8直接リンク"
        case .video: return "videoタグ"
        case .source: return "sourceタグ"
        case .inlineScript: return "ページ内データ"
        case .iframe: return "iframeリンク"
        case .runtime: return "プレイヤー通信"
        }
    }
}

struct HLSCandidate: Identifiable, Sendable {
    let id: UUID
    let request: URLCandidates
    let requestReferer: URL?
    let document: PlaylistDocument?
    let pageURL: URL
    let title: String?
    let thumbnailURL: URL?
    let iframeDepth: Int
    let origin: HLSCandidateOrigin

    var playlistURL: URL { document?.effectiveURL ?? request.primary }
}

struct HLSDiscoveryResult: Sendable {
    let candidates: [HLSCandidate]
    let isDirectPlaylist: Bool
}

struct URLCandidates: Hashable, Sendable {
    let primary: URL
    let sameOriginQueryFallback: URL?

    var all: [URL] {
        if let fallback = sameOriginQueryFallback, fallback != primary {
            return [primary, fallback]
        }
        return [primary]
    }
}

struct ByteRange: Hashable, Sendable {
    let offset: Int64
    let length: Int64
}

struct EncryptionDescriptor: Hashable, Sendable {
    enum Method: String, Hashable, Sendable {
        case aes128 = "AES-128"
    }

    let method: Method
    let keyURL: URLCandidates
    let explicitIV: Data?
}

struct InitializationMap: Hashable, Sendable {
    let url: URLCandidates
    let byteRange: ByteRange?
    let encryption: EncryptionDescriptor?
}

struct MediaSegment: Hashable, Sendable {
    let ordinal: Int
    let mediaSequence: UInt64
    let duration: Double
    let url: URLCandidates
    let byteRange: ByteRange?
    let encryption: EncryptionDescriptor?
    let initializationMap: InitializationMap?
    let hasDiscontinuity: Bool
}

struct MediaPlaylist: Sendable {
    let effectiveURL: URL
    let requestReferer: URL?
    let segments: [MediaSegment]
    let hasEndList: Bool
}

struct Variant: Sendable {
    let url: URLCandidates
    let bandwidth: Int
    let averageBandwidth: Int?
    let resolution: String?
    let audioGroupID: String?
}

struct MediaRendition: Sendable {
    let type: String
    let groupID: String
    let name: String
    let url: URLCandidates?
    let isDefault: Bool
    let isAutoSelect: Bool
}

struct MasterPlaylist: Sendable {
    let effectiveURL: URL
    let variants: [Variant]
    let renditions: [MediaRendition]
}

struct DownloadPlan: Sendable {
    let sourceURL: URL
    let main: MediaPlaylist
    let audio: MediaPlaylist?

    var segmentCount: Int {
        main.segments.count + (audio?.segments.count ?? 0)
    }
}

struct DownloadedSegment: Sendable {
    let source: MediaSegment
    let fileURL: URL
    let container: MediaContainer
    let byteCount: Int
    let initializationDataLength: Int
}

enum MediaContainer: String, Sendable {
    case transportStream = "MPEG-TS"
    case isoBaseMedia = "fMP4"
    case aac = "AAC"
    case mp3 = "MP3"
    case ac3 = "AC-3"
    case eac3 = "E-AC-3"

    var fileExtension: String {
        switch self {
        case .transportStream: return "ts"
        case .isoBaseMedia: return "mp4"
        case .aac: return "aac"
        case .mp3: return "mp3"
        case .ac3: return "ac3"
        case .eac3: return "ec3"
        }
    }
}

enum HLSError: LocalizedError, Sendable {
    case invalidURL
    case unsupportedScheme
    case network(String)
    case httpStatus(Int, String)
    case noPlaylistFound
    case htmlTooLarge
    case invalidPlaylist(String)
    case livePlaylistUnsupported
    case drmUnsupported(String)
    case gapUnsupported
    case invalidAESKey
    case decryptionFailed
    case byteRangeInvalid
    case invalidMediaPayload(stream: String, number: Int, mimeType: String?, byteCount: Int, signature: String)
    case mediaOpenFailed(stream: String, number: Int, container: String, byteCount: Int, detail: String)
    case remuxFailed(String)
    case noPlayableTracks
    case mp4ExportUnsupported
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URLを確認してください。"
        case .unsupportedScheme:
            return "http または https のURLだけを利用できます。"
        case .network(let detail):
            return "通信に失敗しました: \(detail)"
        case .httpStatus(let status, let host):
            return "\(host) が HTTP \(status) を返しました。URLの期限や認証を確認してください。"
        case .noPlaylistFound:
            return "ページ内に利用できるm3u8を見つけられませんでした。m3u8のURLを直接貼ってください。"
        case .htmlTooLarge:
            return "HTMLが大きすぎるため安全に解析できませんでした。m3u8のURLを直接貼ってください。"
        case .invalidPlaylist(let detail):
            return "HLSプレイリストを解析できません: \(detail)"
        case .livePlaylistUnsupported:
            return "終了位置のないライブ配信は保存できません。#EXT-X-ENDLIST を含むVODを指定してください。"
        case .drmUnsupported(let method):
            return "\(method) 暗号化またはDRMには対応していません。FairPlay等で保護された動画は保存できません。"
        case .gapUnsupported:
            return "欠損断片を含むHLSは、壊れたMP4を防ぐため保存を中止しました。"
        case .invalidAESKey:
            return "AES-128鍵が16バイトではありません。"
        case .decryptionFailed:
            return "AES-128断片の復号に失敗しました。"
        case .byteRangeInvalid:
            return "HLSのバイト範囲が不正です。"
        case .invalidMediaPayload(let stream, let number, let mimeType, let byteCount, let signature):
            let type = mimeType.flatMap { $0.isEmpty ? nil : $0 } ?? "不明"
            return "\(stream)断片\(number)がメディアデータではありません（Content-Type: \(type)、\(byteCount) bytes、先頭: \(signature)）。署名URLの期限やログイン状態を確認してください。"
        case .mediaOpenFailed(let stream, let number, let container, let byteCount, let detail):
            return "\(stream)断片\(number)を開けません（\(container)、\(byteCount) bytes）。\(detail)"
        case .remuxFailed(let detail):
            return "MPEG-TSをMP4へ変換できませんでした: \(detail)"
        case .noPlayableTracks:
            return "結合できる映像または音声トラックがありません。"
        case .mp4ExportUnsupported:
            return "このHLSのコーデックは端末上でMP4へ変換できません。"
        case .exportFailed(let detail):
            return "MP4の作成に失敗しました: \(detail)"
        case .cancelled:
            return "処理をキャンセルしました。"
        }
    }
}
