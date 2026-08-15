import Foundation

private let downloadableWidevineHosts: Set<String> = [
    "widevine.sprink.cloud"
]

/// Returns whether this app may accept and process Widevine from this manifest URL.
///
/// This is deliberately an exact host comparison. Subdomains, parent-domain
/// suffixes, URL paths, query strings and user-info never participate in the
/// decision. Callers must pass the manifest's final URL after redirects.
func isDownloadableWidevineDomain(_ url: URL) -> Bool {
    guard let host = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.host?.lowercased() else {
        return false
    }
    return downloadableWidevineHosts.contains(host)
}
