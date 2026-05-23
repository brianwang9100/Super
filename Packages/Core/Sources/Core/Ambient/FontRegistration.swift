import CoreText
import Foundation
import os

public extension Core {
    /// Register every `.ttf` shipped in `Bundle.module/Resources/Fonts/` with
    /// the Core Text font manager so callers can resolve them through
    /// `Font.custom("InstrumentSerif-Italic", size:)` and similar.
    ///
    /// Idempotent: re-entry is a no-op. The host must call this once before
    /// the first SwiftUI render that asks for a bundled face.
    ///
    /// Bundled fonts:
    /// - `InstrumentSerif-Italic.ttf` — splash wordmark + brand display
    /// - `JetBrainsMono-Regular.ttf` — splash version mark + numeric chrome
    static func registerBundledFonts() {
        _ = FontRegistration.didRegister
    }
}

/// Internal one-shot registrar. The `static let` runs exactly once thanks to
/// Swift's lazy static initialization, so callers don't need their own guard.
///
/// Registration failures (missing file, corrupt .ttf, CoreText rejecting the
/// table layout) are surfaced two ways: `assertionFailure` halts debug builds
/// with a named cause, and `os_log` at `.fault` records the failure in
/// release. Without these, `Font.custom(...)` would silently fall back to
/// system faces and the splash would ship off-design with no breadcrumb.
private enum FontRegistration {
    static let didRegister: Bool = {
        let log = Logger(subsystem: "com.brianwang.Super.Core", category: "FontRegistration")
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "ttf",
            subdirectory: nil
        ), !urls.isEmpty else {
            log.fault("No bundled .ttf URLs found in Bundle.module — splash will render with system faces.")
            assertionFailure("Core.registerBundledFonts: no .ttf resources in Bundle.module")
            return false
        }
        var allOK = true
        for url in urls {
            var cfError: Unmanaged<CFError>?
            // `.process` scope registers the font for the duration of the
            // running process. The right choice on iOS — `.persistent` would
            // try to register system-wide and is rejected in the app
            // sandbox.
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
            if !ok {
                let err = cfError?.takeRetainedValue()
                let description = err.map { CFErrorCopyDescription($0) as String? ?? "<unknown>" }
                    ?? "<no error>"
                log.fault("CTFontManagerRegisterFontsForURL failed for \(url.lastPathComponent, privacy: .public): \(description, privacy: .public)")
                assertionFailure("Core.registerBundledFonts: failed to register \(url.lastPathComponent): \(description)")
                allOK = false
            }
        }
        return allOK
    }()
}
