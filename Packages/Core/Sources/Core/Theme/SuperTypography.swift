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
/// ## Two scaling axes
/// Type scales along two *independent* axes, and the accessors expose one knob
/// for each:
///
/// 1. **The app font-scale slider** (`fontScale`, set in Settings). It's folded
///    into every size by `spec` — `size * fontScale`. This is the axis you
///    *don't* want on chrome: a reading-content slider shouldn't move the
///    wordmark or the nav rows. Opt a mark out with `tracksFontScale: false`,
///    which renders at the unscaled base size regardless of the slider.
/// 2. **OS Dynamic Type** (the system text-size / accessibility setting). On a
///    custom brand face it's carried by `relativeTo:` (pass `nil` for a mark
///    that must ignore Dynamic Type too). The system-font path *always* strips
///    `relativeTo` — matching the literal `.system(size:)` call sites it
///    replaces — so a system-face surface that wants Dynamic Type pairs a
///    `@ScaledMetric` base with `font(size:)`.
///
/// The axes compose: drawer chrome that should honor the OS setting but ignore
/// the app slider uses a `@ScaledMetric` base *and* `tracksFontScale: false`.
/// Reading content (the default `tracksFontScale: true`) gets the slider.
public struct SuperTypography: Sendable, Equatable {
    /// Swappable type systems. `.serif` is the brand set (EB Garamond
    /// Italic display + EB Garamond Regular reading body + JetBrains Mono);
    /// `.system` drops to system faces. Adding a face set is one new case
    /// plus one `make(_:)` arm.
    public enum Identifier: String, Sendable, CaseIterable, Codable {
        case serif
        case system
    }

    /// Shared family name of the four bundled EB Garamond faces
    /// (Regular / Italic / SemiBold / SemiBold Italic). Reference *this*
    /// (rather than a single PostScript name) where weight/italic must
    /// resolve to the true family member — e.g. MarkdownUI's
    /// `FontFamily(.custom(_:))` for assistant message body, where `.strong`
    /// and `.emphasis` apply weight/slant traits the family must satisfy.
    public static let serifFamily = "EB Garamond"

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
    /// Brand display face name (PostScript) — the *italic* EB Garamond used
    /// for wordmarks, titles, and section headings. `nil` to use the system
    /// serif.
    let displayFace: String?
    /// Reading/body serif face name (PostScript) — the *roman* EB Garamond
    /// used for long-form reading content (Bible verse body, assistant
    /// message body). Distinct from `displayFace` (italic). `nil` to use the
    /// system serif.
    let readingFace: String?
    /// Monospaced face name (PostScript), or `nil` to use the system mono.
    let monoFace: String?

    // MARK: Accessors

    /// Brand display title (e.g. "Tasks", "Chats", "John 3"). Resolves to the
    /// `displayFace` when present, else the system serif. Pass `relativeTo:
    /// nil` for a mark that must not scale with OS Dynamic Type, and
    /// `tracksFontScale: false` for a brand mark (a wordmark) that must not
    /// move with the app font-scale slider.
    public func display(_ size: CGFloat = 36, // == Role.display.baseSize
                        relativeTo: Font.TextStyle? = .largeTitle,
                        tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: nil, design: .serif, tracksFontScale: tracksFontScale)
    }

    /// Reading/body serif (roman) — the long-form reading face, distinct from
    /// the *italic* brand `display(_:)`. Resolves to `readingFace` (EB
    /// Garamond Regular) when present, else the system serif. Used by the
    /// Bible verse body and the assistant message body. Pass `weight:` for an
    /// emphasized member (e.g. `.semibold`) and `relativeTo: nil` for a fixed
    /// size; `tracksFontScale: false` to ignore the app font-scale slider.
    public func reading(_ size: CGFloat,
                        relativeTo: Font.TextStyle? = .body,
                        weight: Font.Weight? = nil,
                        tracksFontScale: Bool = true) -> Font {
        readingSpec(size: size, relativeTo: relativeTo, weight: weight, tracksFontScale: tracksFontScale).font
    }

    /// A system-sans role at its base size. Scales with `fontScale`; for OS
    /// Dynamic Type the view supplies its own `@ScaledMetric` base via
    /// `font(size:)`. Use `display(_:)` for the brand serif title instead.
    ///
    /// There's deliberately no `tracksFontScale` knob here: the role API is the
    /// *content* surface, which scales with the slider by definition. Chrome
    /// that must ignore the slider also needs a `@ScaledMetric` base to keep OS
    /// Dynamic Type, so it goes through `font(size:tracksFontScale:)` instead.
    ///
    /// `weight` is honored for every role, including `.display` — under the
    /// `.system` identity the display role resolves to the system serif, whose
    /// weight is meaningful. The bundled EB Garamond *italic* display face is a
    /// single weight, so `.weight(...)` is a no-op on `.display`; the SemiBold
    /// members are reached via the family name (`serifFamily`) or `reading(_:
    /// weight:)`, not by re-weighting the display PostScript face.
    public func font(_ role: Role, weight: Font.Weight? = nil) -> Font {
        if role == .display {
            return resolve(size: role.baseSize, relativeTo: .largeTitle, weight: weight, design: .serif)
        }
        return resolve(size: role.baseSize, relativeTo: nil, weight: weight, design: .default)
    }

    /// Arbitrary fixed size that doesn't map to a `Role`. `design: .serif`
    /// resolves to the brand display face; `.monospaced` to the mono face;
    /// `.default` to system sans. Pass `tracksFontScale: false` (typically with
    /// a `@ScaledMetric` `size`) for chrome that should honor OS Dynamic Type
    /// but stay independent of the app font-scale slider.
    public func font(size: CGFloat,
                     relativeTo: Font.TextStyle? = nil,
                     weight: Font.Weight? = nil,
                     design: Font.Design = .default,
                     tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: design, tracksFontScale: tracksFontScale)
    }

    /// Monospaced role (numeric chrome, section labels). Resolves to the
    /// `monoFace` when present, else the system monospaced design. Pass
    /// `tracksFontScale: false` for a fixed brand mark (e.g. a version caption)
    /// that must not move with the app font-scale slider.
    public func mono(_ size: CGFloat,
                     relativeTo: Font.TextStyle? = .caption2,
                     weight: Font.Weight? = nil,
                     tracksFontScale: Bool = true) -> Font {
        resolve(size: size, relativeTo: relativeTo, weight: weight, design: .monospaced, tracksFontScale: tracksFontScale)
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
              design: Font.Design,
              tracksFontScale: Bool = true) -> FontSpec {
        let face: String? = switch design {
        case .serif: displayFace
        case .monospaced: monoFace
        default: nil
        }
        // A custom face is fixed (no Dynamic Type) only when relativeTo is nil;
        // the system path ignores relativeTo (system fonts scale via the view's
        // own @ScaledMetric base, matching the call sites being migrated).
        // The app font-scale slider is folded in only when tracksFontScale is
        // set — chrome and fixed brand marks opt out so the slider stays scoped
        // to reading content.
        return FontSpec(
            face: face,
            size: tracksFontScale ? size * fontScale : size,
            relativeTo: face != nil ? relativeTo : nil,
            weight: weight,
            design: design
        )
    }

    /// Resolution truth for the roman reading face. Mirrors `spec(...)` but
    /// always picks `readingFace` (the `.serif` design slot is owned by the
    /// italic `displayFace`, so reading needs its own path). `internal` so
    /// tests can assert on it.
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

    /// Build a typography set by id, folding in the active font scale.
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
