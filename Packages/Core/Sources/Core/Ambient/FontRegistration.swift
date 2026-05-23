import CoreText
import Foundation
import os

public extension Core {
    /// Register the brand fonts shipped in `Bundle.module/Resources/Fonts/`
    /// with the Core Text font manager so callers can resolve them via
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
/// Each font is looked up by name+subdirectory rather than scanning the
/// bundle for any `.ttf`. A missing or renamed file therefore surfaces as
/// a *named* failure ("InstrumentSerif-Italic.ttf not found"), not as an
/// empty enumeration result the caller can mistake for "no fonts to
/// register." Registration failures (sandbox denial, CoreText rejecting the
/// table layout) are surfaced two ways: `assertionFailure` halts debug
/// builds with a named cause, and `os_log(.fault)` records the failure in
/// release. Without these, `Font.custom(...)` would silently fall back to
/// system faces and the splash would ship off-design with no breadcrumb.
private enum FontRegistration {
    /// Font face name (matches PostScript name, used at the `Font.custom`
    /// call site) → file path under `Bundle.module/Resources/Fonts/`.
    private static let bundledFaces: [(name: String, fileName: String)] = [
        ("InstrumentSerif-Italic", "InstrumentSerif-Italic"),
        ("JetBrainsMono-Regular", "JetBrainsMono-Regular"),
    ]

    static let didRegister: Bool = {
        let log = Logger(subsystem: "com.brianwang.Super.Core", category: "FontRegistration")
        var allOK = true
        for face in bundledFaces {
            // SwiftPM `.process("Resources")` flattens the source tree
            // (`Resources/Fonts/*.ttf`) into the bundle root, so we look up
            // by file name without a subdirectory. Confirmed by inspecting
            // the built `Core_Core.bundle` — both .ttfs sit at the root.
            guard let url = Bundle.module.url(
                forResource: face.fileName,
                withExtension: "ttf"
            ) else {
                log.fault("Bundled font \(face.fileName, privacy: .public).ttf missing from Bundle.module")
                assertionFailure("Core.registerBundledFonts: \(face.fileName).ttf not found in Bundle.module")
                allOK = false
                continue
            }
            var cfError: Unmanaged<CFError>?
            // `.process` scope registers the font for the lifetime of the
            // running process — the right choice on iOS, where `.persistent`
            // is rejected in the app sandbox.
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
            if !ok {
                let err = cfError?.takeRetainedValue()
                let code = err.map { CFErrorGetCode($0) }
                // `kCTFontManagerErrorAlreadyRegistered` is benign — the
                // host (or a prior call in the same process) already
                // registered the face, and `Font.custom` will resolve it.
                // Treat as success rather than tripping `assertionFailure`.
                if code == CTFontManagerError.alreadyRegistered.rawValue {
                    continue
                }
                let description = err.map { CFErrorCopyDescription($0) as String? ?? "<unknown>" }
                    ?? "<no error>"
                log.fault("CTFontManagerRegisterFontsForURL failed for \(face.fileName, privacy: .public).ttf: \(description, privacy: .public)")
                assertionFailure("Core.registerBundledFonts: failed to register \(face.fileName).ttf: \(description)")
                allOK = false
            }
        }
        return allOK
    }()
}
