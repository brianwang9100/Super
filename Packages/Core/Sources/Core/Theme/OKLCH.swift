import SwiftUI

/// OKLCH (Oklab Lightness-Chroma-Hue) color space helper.
///
/// The design palette in `.design-tmp/chat/project/src/theme.jsx` is
/// expressed in CSS `oklch(L C H)` triplets. SwiftUI has no native OKLCH
/// constructor on iOS 18, so this type converts the three components into
/// an sRGB `Color` at theme-build time.
///
/// The conversion follows the published Oklab transform (Björn Ottosson,
/// 2020): OKLCH → Oklab → linear sRGB → gamma-encoded sRGB. The matrix
/// constants below come from the public domain reference. Out-of-gamut
/// values are clamped to `[0, 1]` per channel — the design palette stays
/// safely inside the sRGB gamut, but clamping prevents an extreme accent
/// hue from producing a negative component that SwiftUI would reject.
public struct OKLCH: Sendable, Equatable {
    /// Perceptual lightness, 0 (black) to 1 (white).
    public let l: Double
    /// Chroma (saturation magnitude). Typical UI values stay below 0.2.
    public let c: Double
    /// Hue angle in degrees, 0…360.
    public let h: Double
    /// Alpha, 0 (transparent) to 1 (opaque). Defaults to 1.
    public let alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1.0) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    /// Resolved sRGB `Color`. Computed once per call — themes cache the
    /// result on a `Color` property rather than re-resolving every frame.
    public var color: Color {
        let (r, g, b) = Self.toSRGB(l: l, c: c, h: h)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// OKLCH → sRGB conversion. Returns gamma-encoded sRGB components in
    /// `[0, 1]`. Clamps each channel before returning so out-of-gamut
    /// hues don't produce negative or super-unit values.
    static func toSRGB(l: Double, c: Double, h: Double) -> (r: Double, g: Double, b: Double) {
        let hRad = h * .pi / 180.0
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        // Oklab → LMS' (cube root scale)
        let lP = l + 0.3963377774 * a + 0.2158037573 * b
        let mP = l - 0.1055613458 * a - 0.0638541728 * b
        let sP = l - 0.0894841775 * a - 1.2914855480 * b

        let lLin = lP * lP * lP
        let mLin = mP * mP * mP
        let sLin = sP * sP * sP

        // LMS → linear sRGB
        let rLin =  4.0767416621 * lLin - 3.3077115913 * mLin + 0.2309699292 * sLin
        let gLin = -1.2684380046 * lLin + 2.6097574011 * mLin - 0.3413193965 * sLin
        let bLin = -0.0041960863 * lLin - 0.7034186147 * mLin + 1.7076147010 * sLin

        return (
            r: clamp(srgbEncode(rLin)),
            g: clamp(srgbEncode(gLin)),
            b: clamp(srgbEncode(bLin))
        )
    }

    /// Linear-sRGB → gamma-encoded sRGB transfer function.
    private static func srgbEncode(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x <= 0.0031308 { return 12.92 * x }
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }

    private static func clamp(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}
