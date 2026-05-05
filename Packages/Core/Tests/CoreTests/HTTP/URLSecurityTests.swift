import Foundation
import Testing
@testable import Core

/// Tests for `isCleartextSafeForCredentials` — the HTTPS-or-loopback gate
/// every credential-attaching call site goes through.
@Suite("URLSecurity")
struct URLSecurityTests {
    @Test func httpsIsAlwaysSafe() {
        #expect(isCleartextSafeForCredentials(URL(string: "https://api.openai.com/v1")!))
        #expect(isCleartextSafeForCredentials(URL(string: "https://example.com")!))
        #expect(isCleartextSafeForCredentials(URL(string: "https://10.0.0.5/v1")!))
    }

    @Test func httpToNonLoopbackIsRejected() {
        #expect(!isCleartextSafeForCredentials(URL(string: "http://api.openai.com/v1")!))
        #expect(!isCleartextSafeForCredentials(URL(string: "http://example.com")!))
        #expect(!isCleartextSafeForCredentials(URL(string: "http://10.0.0.5/v1")!))
        #expect(!isCleartextSafeForCredentials(URL(string: "http://203.0.113.5:8000")!))
    }

    @Test func httpToLoopbackHostnameIsAllowed() {
        #expect(isCleartextSafeForCredentials(URL(string: "http://localhost/v1")!))
        #expect(isCleartextSafeForCredentials(URL(string: "http://localhost:11434/v1")!))
        #expect(isCleartextSafeForCredentials(URL(string: "http://LOCALHOST/v1")!))
    }

    @Test func httpToLoopbackIPv4IsAllowed() {
        #expect(isCleartextSafeForCredentials(URL(string: "http://127.0.0.1/v1")!))
        #expect(isCleartextSafeForCredentials(URL(string: "http://127.0.0.1:1234/v1")!))
    }

    @Test func httpToLoopbackIPv6IsAllowed() {
        // URL.host strips the brackets, so the comparison runs against `::1`.
        #expect(isCleartextSafeForCredentials(URL(string: "http://[::1]:8080/v1")!))
    }

    @Test func httpToBonjourLocalIsAllowed() {
        #expect(isCleartextSafeForCredentials(URL(string: "http://my-mac.local:11434/v1")!))
        #expect(isCleartextSafeForCredentials(URL(string: "http://Studio.local/api")!))
    }

    @Test func nonHttpSchemesAreRejected() {
        #expect(!isCleartextSafeForCredentials(URL(string: "ftp://example.com")!))
        #expect(!isCleartextSafeForCredentials(URL(string: "file:///tmp/x")!))
        #expect(!isCleartextSafeForCredentials(URL(string: "ws://example.com")!))
    }

    @Test func malformedUrlIsRejected() {
        // `URL(string:)` accepts a fair bit, so build a host-less URL via
        // a scheme-only path to exercise the `host == nil` branch.
        let url = URL(string: "http://")!
        #expect(!isCleartextSafeForCredentials(url))
    }

    /// `*.local` is the *suffix* test, not "ends with `local`" — a host
    /// ending in something like `notlocal` must not be confused for a
    /// Bonjour name. (`URL.host` lowercases at compare time anyway.)
    @Test func plainWordLocalIsRejected() {
        // `localish.com` does not end in `.local` and so is rejected.
        #expect(!isCleartextSafeForCredentials(URL(string: "http://localish.com")!))
    }
}
