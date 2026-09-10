import SwiftUI

/// Font accessors already apply the app slider; callers must not multiply it again.
/// Custom faces use relativeTo for Dynamic Type. System faces ignore relativeTo,
/// so Dynamic Type requires a ScaledMetric base passed to font(size:).
public struct SuperTypography: Sendable, Equatable {
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case serif
        case system
    }

    /// Use the family name when weight/italic traits must select real face members.
    public static let serifFamily = "EB Garamond"

    /// Reading body size shared by Bible and Chat, independent of system-sans Role.body chrome.
    public static let readingBodySize: CGFloat = 19

    /// Line gap as a fraction of rendered body size, shared by Bible and Chat.
    public static let readingLeadingEm: CGFloat = 4.0 / 17.0

    public enum Role: Sendable {
        case display
        case largeTitle
        case title
        case title2
        case title3
        case headline
        case body
        case callout
        case subheadline
        case footnote
        case caption
        case caption2

        var baseSize: CGFloat {
            switch self {
            case .display: return 36
            case .largeTitle: return 34
            case .title: return 28
            case .title2: return 22
            case .title3: return 20
            case .headline, .body: return 17
            case .callout: return 16
            case .subheadline: return 15
            case .footnote: return 13
            case .caption: return 12
            case .caption2: return 11
            }
        }
    }

    public let id: Identifier
    public let fontScale: CGFloat
    /// PostScript face, or nil for system serif.
    let displayFace: String?
    /// Roman reading face, separate from italic display; nil uses system serif.
    let readingFace: String?
    /// PostScript face, or nil for system monospaced.
    let monoFace: String?

    /// Family for selecting weight/italic members; nil means the system identity.
    public var readingFamily: String? {
        readingFace != nil ? Self.serifFamily : nil
    }

    // MARK: Accessors

    /// Brand display serif. Nil relativeTo disables Dynamic Type on custom faces.
    public func display(_ size: CGFloat = 36, // == Role.display.baseSize
                        relativeTo: Font.TextStyle? = .largeTitle,
                        tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: nil, design: .serif, tracksFontScale: tracksFontScale)
    }

    /// Roman reading serif, separate from italic display. Nil relativeTo fixes custom-face size.
    public func reading(_ size: CGFloat,
                        relativeTo: Font.TextStyle? = .body,
                        weight: Font.Weight? = nil,
                        tracksFontScale: Bool = true) -> Font {
        readingSpec(size: size, relativeTo: relativeTo, weight: weight, tracksFontScale: tracksFontScale).font
    }

    /// Roles always track the app slider. System-face Dynamic Type requires font(size:)
    /// with a ScaledMetric base. Weight cannot select another member of the single
    /// PostScript display face; use reading(weight:) or serifFamily for those members.
    public func font(_ role: Role, weight: Font.Weight? = nil) -> Font {
        if role == .display {
            return resolve(size: role.baseSize, relativeTo: .largeTitle, weight: weight, design: .serif)
        }
        return resolve(size: role.baseSize, relativeTo: nil, weight: weight, design: .default)
    }

    /// Arbitrary size: serif selects display, monospaced selects mono, default selects system sans.
    public func font(size: CGFloat,
                     relativeTo: Font.TextStyle? = nil,
                     weight: Font.Weight? = nil,
                     design: Font.Design = .default,
                     tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: design, tracksFontScale: tracksFontScale)
    }

    public func mono(_ size: CGFloat,
                     relativeTo: Font.TextStyle? = .caption2,
                     weight: Font.Weight? = nil,
                     tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: .monospaced, tracksFontScale: tracksFontScale)
    }

    // SwiftUI.Font equality cannot reliably distinguish provider/initializer variants.
    // Compare pure resolution inputs in tests instead.
    struct FontSpec: Equatable {
        var face: String?
        var size: CGFloat
        var relativeTo: Font.TextStyle?
        var weight: Font.Weight?
        var design: Font.Design

        var font: Font {
            if let face {
                let base = relativeTo.map { Font.custom(face, size: size, relativeTo: $0) }
                    ?? .custom(face, size: size)
                return weight.map { base.weight($0) } ?? base
            }
            return .system(size: size, weight: weight ?? .regular, design: design)
        }
    }

    func spec(size: CGFloat,
              relativeTo: Font.TextStyle?,
              weight: Font.Weight?,
              design: Font.Design,
              tracksFontScale: Bool = true) -> FontSpec {
        let face: String? = switch design {
        case .serif: displayFace
        case .monospaced: monoFace
        default: nil
        }
        // System fonts get Dynamic Type through the caller's ScaledMetric, not relativeTo.
        return FontSpec(
            face: face,
            size: tracksFontScale ? size * fontScale : size,
            relativeTo: face != nil ? relativeTo : nil,
            weight: weight,
            design: design
        )
    }

    // The serif design slot is italic display; roman reading requires its own face path.
    func readingSpec(size: CGFloat,
                     relativeTo: Font.TextStyle?,
                     weight: Font.Weight?,
                     tracksFontScale: Bool = true) -> FontSpec {
        FontSpec(
            face: readingFace,
            size: tracksFontScale ? size * fontScale : size,
            relativeTo: readingFace != nil ? relativeTo : nil,
            weight: weight,
            design: .serif
        )
    }

    private func resolve(size: CGFloat,
                         relativeTo: Font.TextStyle?,
                         weight: Font.Weight?,
                         design: Font.Design,
                         tracksFontScale: Bool = true) -> Font {
        spec(size: size, relativeTo: relativeTo, weight: weight, design: design, tracksFontScale: tracksFontScale).font
    }

    public static func make(_ id: Identifier, fontScale: CGFloat = 1) -> SuperTypography {
        switch id {
        case .serif:
            return SuperTypography(
                id: .serif,
                fontScale: fontScale,
                displayFace: "EBGaramond-Italic",
                readingFace: "EBGaramond-Regular",
                monoFace: "JetBrainsMono-Regular"
            )
        case .system:
            return SuperTypography(
                id: .system,
                fontScale: fontScale,
                displayFace: nil,
                readingFace: nil,
                monoFace: nil
            )
        }
    }
}

public struct SuperTypographyKey: EnvironmentKey {
    public static let defaultValue: SuperTypography = .make(.serif)
}

public extension EnvironmentValues {
    var superTypography: SuperTypography {
        get { self[SuperTypographyKey.self] }
        set { self[SuperTypographyKey.self] = newValue }
    }
}

public extension View {
    func superTypography(_ typography: SuperTypography) -> some View {
        environment(\.superTypography, typography)
    }
}
