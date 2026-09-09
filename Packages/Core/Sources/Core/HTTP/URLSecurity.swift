import Foundation

/// Allows credentials on HTTPS or HTTP loopback/*.local endpoints for local LLMs.
/// Other destinations must receive no credential. Apply before constructing
/// authorization headers, even when ATS would later block the request.
public func isCleartextSafeForCredentials(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    if scheme == "https" { return true }
    guard scheme == "http" else { return false }
    guard let host = url.host?.lowercased() else { return false }
    if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
    if host.hasSuffix(".local") { return true }
    return false
}
