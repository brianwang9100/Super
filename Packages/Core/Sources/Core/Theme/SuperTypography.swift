import SwiftUI

/// Resolved type system for the app — the single place that owns *which font
/// faces render which roles*. The companion to `SuperTheme`: where the theme
/// resolves a semantic color token to a `Color`, `SuperTypography` resolves a
/// semantic type role to a `Font`. Swapping the brand face app-wide is a
/// one-line change to a `make(_:)` arm.
///
/// It carries the active `superFontScale` so call sites read a single
/// environment value (`@Environment(\.superTypography)`) and never multiply
/// the scale themselves — the scale is folded into every accessor.
///
/// ## Face resolution
/// Each identity declares an optional `displayFace` (brand serif) and
/// `monoFace`. When a face is present the accessor returns a `Font.custom`;
/// when it's `nil` the accessor falls back to the system font in the matching
/// `Font.Design` (`.serif` / `.monospaced` / `.default`). The `.system`
/// identity nils both faces, so it renders entirely with system faces — the
/// escape hatch for "turn the brand off" and the reference for the no-op
/// migration invariant (a system-design role resolves byte-identically to the
/// hand-written `.font(.system(size:design:))` it replaces).
///
/// ## Dynamic Type
/// Custom-face accessors pass `relativeTo:` so the brand text scales with the
/// OS Dynamic Type setting *and* the app `fontScale`. Pass `relativeTo: nil`
/// for fixed-size brand marks that must not scale (the splash wordmark). The
/// system-font path scales with `fontScale` only — matching the existing
/// `.system(size: N * fontScale)` call sites, which a migrating view pairs
/// with its own `@ScaledMetric` base when it needs OS Dynamic Type too.
public struct SuperTypography: Sendable, Equatable {
    /// Swappable type systems. `.serif` is the brand set (Instrument Serif
    /// Italic display + JetBrains Mono); `.system` drops to system faces.
    /// Adding a face set is one new case plus one `make(_:)` arm.
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case serif
        case system
    }

    /// Semantic type roles, mirroring Apple's text styles so migration off
    /// `.font(.system(size:))` is mechanical. `display` is the brand title
    /// role (serif, larger than `largeTitle`); the rest are system-sans body
    /// and chrome roles. Base point sizes match each style's size at the
    /// default content-size category.
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

        /// Base point size at the default content-size category.
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
    /// App-wide font-size multiplier, folded into every accessor.
    public let fontScale: CGFloat
    /// Brand serif face name (PostScript), or `nil` to use the system serif.
    let displayFace: String?
    /// Monospaced face name (PostScript), or `nil` to use the system mono.
    let monoFace: String?

    // MARK: Accessors

    /// Brand display title (e.g. "Tasks", "Chats", "John 3"). Resolves to the
    /// `displayFace` when present, else the system serif. Pass `relativeTo:
    /// nil` for a fixed-size mark that must not scale with Dynamic Type.
    public func display(_ size: CGFloat = 36, // == Role.display.baseSize
                        relativeTo: Font.TextStyle? = .largeTitle) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: nil, design: .serif)
    }

    /// A system-sans role at its base size. Scales with `fontScale`; for OS
    /// Dynamic Type the view supplies its own `@ScaledMetric` base via
    /// `font(size:)`. Use `display(_:)` for the brand serif title instead.
    ///
    /// `weight` is honored for every role, including `.display` — under the
    /// `.system` identity the display role resolves to the system serif, whose
    /// weight is meaningful (the bundled Instrument Serif face is single-weight,
    /// so weight is a no-op there, but the API must not silently drop it).
    public func font(_ role: Role, weight: Font.Weight? = nil) -> Font {
        if role == .display {
            return resolve(size: role.baseSize, relativeTo: .largeTitle, weight: weight, design: .serif)
        }
        return resolve(size: role.baseSize, relativeTo: nil, weight: weight, design: .default)
    }

    /// Arbitrary fixed size that doesn't map to a `Role`. `design: .serif`
    /// resolves to the brand display face; `.monospaced` to the mono face;
    /// `.default` to system sans.
    public func font(size: CGFloat,
                     relativeTo: Font.TextStyle? = nil,
                     weight: Font.Weight? = nil,
                     design: Font.Design = .default) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: design)
    }

    /// Monospaced role (numeric chrome, section labels). Resolves to the
    /// `monoFace` when present, else the system monospaced design.
    public func mono(_ size: CGFloat,
                     relativeTo: Font.TextStyle? = .caption2,
                     weight: Font.Weight? = nil) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: .monospaced)
    }

    /// A fully-resolved font descriptor: the pure inputs to a `Font`, decided
    /// by identity + scale + design. Extracted so resolution logic is testable
    /// without relying on `SwiftUI.Font`'s opaque, provider-sensitive `==`
    /// (which can't reliably distinguish `.custom(size:)` from
    /// `.custom(size:relativeTo:)`, or `.system(size:weight:)` from the
    /// `design:` overload).
    struct FontSpec: Equatable {
        /// Custom face name, or `nil` to use the system font in `design`.
        var face: String?
        var size: CGFloat
        /// Dynamic Type anchor for a custom face; `nil` = fixed size.
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

    /// Decide the descriptor for a request: pick a custom face by `design`
    /// when the active identity provides one, fold in `fontScale`, and carry
    /// `relativeTo`/`weight` through. The single source of resolution truth;
    /// `internal` so tests can assert on it.
    func spec(size: CGFloat,
              relativeTo: Font.TextStyle?,
              weight: Font.Weight?,
              design: Font.Design) -> FontSpec {
        let face: String? = switch design {
        case .serif: displayFace
        case .monospaced: monoFace
        default: nil
        }
        // A custom face is fixed (no Dynamic Type) only when relativeTo is nil;
        // the system path ignores relativeTo (system fonts scale via the view's
        // own @ScaledMetric base, matching the call sites being migrated).
        return FontSpec(
            face: face,
            size: size * fontScale,
            relativeTo: face != nil ? relativeTo : nil,
            weight: weight,
            design: design
        )
    }

    private func resolve(size: CGFloat,
                         relativeTo: Font.TextStyle?,
                         weight: Font.Weight?,
                         design: Font.Design) -> Font {
        spec(size: size, relativeTo: relativeTo, weight: weight, design: design).font
    }

    /// Build a typography set by id, folding in the active font scale.
    public static func make(_ id: Identifier, fontScale: CGFloat = 1) -> SuperTypography {
        switch id {
        case .serif:
            return SuperTypography(
                id: .serif,
                fontScale: fontScale,
                displayFace: "InstrumentSerif-Italic",
                monoFace: "JetBrainsMono-Regular"
            )
        case .system:
            return SuperTypography(
                id: .system,
                fontScale: fontScale,
                displayFace: nil,
                monoFace: nil
            )
        }
    }
}

/// Environment slot for the active typography. Views read it via
/// `@Environment(\.superTypography)` and SwiftUI rebuilds them when it changes
/// (typography swap or font-scale change in Settings).
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
    /// Inject a typography set into the SwiftUI environment for this subtree.
    /// Pair with `.superTheme(_:)` / `.superFontScale(_:)` at the same
    /// composition boundary so theme, scale, and faces refresh together.
    func superTypography(_ typography: SuperTypography) -> some View {
        environment(\.superTypography, typography)
    }
}
