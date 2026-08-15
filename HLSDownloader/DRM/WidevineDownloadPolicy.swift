import Foundation

private let downloadableWidevineHosts: Set<String> = [
    "widevine.sprink.cloud"
]

/// Returns whether this app may accept and process Widevine from this manifest URL.
///
/// This is deliberately an HTTPS URL plus exact-host comparison. Subdomains,
/// parent-domain suffixes, URL paths and query strings never participate in
/// the decision, and credential-bearing URLs are rejected. Callers must pass
/// the manifest's final URL after redirects.
func isDownloadableWidevineDomain(_ url: URL) -> Bool {
    //return true
    return false
    //guard let components = URLComponents(
    //    url: url,
    //    resolvingAgainstBaseURL: false
    //),
    //      components.scheme?.lowercased() == "https",
    //      components.user == nil,
    //      components.password == nil,
    //      let host = components.host?.lowercased() else {
    //    return false
    //}
    //return downloadableWidevineHosts.contains(host)
}
