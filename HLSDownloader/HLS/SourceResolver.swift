import Foundation

struct PlaylistDocument: Sendable {
    let text: String
    let effectiveURL: URL
    let referer: URL?
}

final class SourceResolver: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    func resolve(input: String) async throws -> PlaylistDocument {
        let inputURL = try URIResolver.normalizeInput(input)
        let payload = try await client.fetch(inputURL)
        guard let text = decodeText(payload.data) else {
            throw HLSError.noPlaylistFound
        }

        if PlaylistParser.isPlaylist(text) {
            return PlaylistDocument(text: text, effectiveURL: payload.effectiveURL, referer: inputURL)
        }

        let candidates = extractM3U8Candidates(from: text, baseURL: payload.effectiveURL)
        for candidate in candidates.prefix(24) {
            do {
                let candidatePayload = try await client.fetch(candidate, referer: payload.effectiveURL)
                guard let candidateText = decodeText(candidatePayload.data),
                      PlaylistParser.isPlaylist(candidateText) else { continue }
                return PlaylistDocument(
                    text: candidateText,
                    effectiveURL: candidatePayload.effectiveURL,
                    referer: payload.effectiveURL
                )
            } catch let error as HLSError {
                if case .cancelled = error { throw error }
                continue
            } catch is CancellationError {
                throw HLSError.cancelled
            } catch {
                continue
            }
        }
        throw HLSError.noPlaylistFound
    }

    func load(_ candidates: URLCandidates, referer: URL?) async throws -> PlaylistDocument {
        let payload = try await client.fetch(candidates, referer: referer)
        guard let text = decodeText(payload.data), PlaylistParser.isPlaylist(text) else {
            throw HLSError.invalidPlaylist("リンク先がm3u8ではありません")
        }
        return PlaylistDocument(text: text, effectiveURL: payload.effectiveURL, referer: referer)
    }

    private func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func extractM3U8Candidates(from html: String, baseURL: URL) -> [URLCandidates] {
        let decoded = URIResolver.decodeEscapes(html)
        let pattern = #"(?i)((?:https?:)?//[^\s\"'<>]+?\.m3u8(?:\?[^\s\"'<>]*)?|(?:\.\.?/|/)[^\s\"'<>]+?\.m3u8(?:\?[^\s\"'<>]*)?|[A-Za-z0-9_%@+.-]+(?:/[A-Za-z0-9_%@+.,~!$&()*;=:-]+)*\.m3u8(?:\?[^\s\"'<>]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
        var seen = Set<URL>()
        var result: [URLCandidates] = []

        for match in regex.matches(in: decoded, range: range) {
            guard let matchRange = Range(match.range(at: 1), in: decoded) else { continue }
            var raw = String(decoded[matchRange])
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{};,"))
            guard let candidate = try? URIResolver.resolve(raw, relativeTo: baseURL),
                  seen.insert(candidate.primary).inserted else { continue }
            result.append(candidate)
        }
        return result
    }
}
