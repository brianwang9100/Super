import CoreText
import Foundation
import os

public extension Core {
    /// Registers bundled fonts once. Call before the first SwiftUI render.
    static func registerBundledFonts() {
        _ = FontRegistration.didRegister
    }
}

/// Reports named failures because `Font.custom` otherwise silently falls back.
private enum FontRegistration {
    private static let bundledFaces: [(name: String, fileName: String)] = [
        ("EBGaramond-Regular", "EBGaramond-Regular"),
        ("EBGaramond-Italic", "EBGaramond-Italic"),
        ("EBGaramond-SemiBold", "EBGaramond-SemiBold"),
        ("EBGaramond-SemiBoldItalic", "EBGaramond-SemiBoldItalic"),
        ("JetBrainsMono-Regular", "JetBrainsMono-Regular"),
    ]

    static let didRegister: Bool = {
        let log = Logger(subsystem: "com.brianwang.Super.Core", category: "FontRegistration")
        var allOK = true
        for face in bundledFaces {
            // SwiftPM processing flattens Resources/Fonts into the bundle root.
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
            // Persistent registration is rejected by the iOS sandbox; use process lifetime.
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError)
            if !ok {
                let err = cfError?.takeRetainedValue()
                let code = err.map { CFErrorGetCode($0) }
                // An already registered face resolves correctly and is not a failure.
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
