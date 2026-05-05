import Foundation

/// Returns `true` when it is safe to attach a credential (typically an
/// `Authorization: Bearer …` header) to a request bound for `url`.
///
/// Policy:
/// - `https://` is always safe.
/// - `http://` is allowed only for loopback (`localhost`, `127.0.0.1`,
///   `::1`) and `*.local` (Bonjour / mDNS) hosts — i.e. destinations the
///   request cannot physically reach without staying on the user's
///   device or LAN. Required because BYOK (Bring Your Own Key) local-LLM
///   stacks (Ollama, LM Studio, MLX, llama.cpp's server) commonly bind
///   to `127.0.0.1` or `<host>.local` over plain HTTP and the user
///   should still be able to point Super at them.
/// - Anything else (other schemes, non-loopback `http://`) returns
///   `false` and the caller MUST NOT attach a credential.
///
/// This is a defense-in-depth check on top of iOS App Transport Security
/// (ATS): ATS blocks the request from leaving the device, but the
/// `Authorization` header has already been built by the time ATS fires,
/// and we don't want secrets in any in-flight `URLRequest` we couldn't
/// actually send.
public func isCleartextSafeForCredentials(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    if scheme == "https" { return true }
    guard scheme == "http" else { return false }
    guard let host = url.host?.lowercased() else { return false }
    if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
    if host.hasSuffix(".local") { return true }
    return false
}
