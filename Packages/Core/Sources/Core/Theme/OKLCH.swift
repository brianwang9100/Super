import SwiftUI

/// Converts design OKLCH palettes to sRGB using Björn Ottosson's public-domain
/// Oklab reference matrices (2020). Out-of-gamut channels clamp to 0...1.
public struct OKLCH: Sendable, Equatable {
    /// Perceptual lightness, 0 (black) to 1 (white).
    public let l: Double
    /// Chroma (saturation magnitude). Typical UI values stay below 0.2.
    public let c: Double
    /// Hue angle in degrees, 0…360.
    public let h: Double
    public let alpha: Double

    public init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1.0) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    public var color: Color {
        let (r, g, b) = Self.toSRGB(l: l, c: c, h: h)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Returns gamma-encoded sRGB channels clamped to 0...1.
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
