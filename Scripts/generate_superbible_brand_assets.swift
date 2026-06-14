#!/usr/bin/env swift
//
// generate_superbible_brand_assets.swift
//
// Regenerates the brand assets for BOTH app targets — SuperBible and SuperOS —
// from a single source of truth: the Vellum Light theme tokens, the finalized
// 8-point Star of Bethlehem (SuperBible), and the 12-ray spark (SuperOS).
//
// The design (the Claude "Theme Icons & Splash" design artifact — external to
// this repo): a flat themed ground with the centered mark, no wordmark. Each
// app icon sits on the slightly deeper `bgSunken` paper; the launch/splash
// ground uses the brighter `bg`. SuperBible's mark is the filled star in the
// theme `accent` (clay, hue 52); SuperOS's mark is the stroked spark in
// `accentDark` (the deeper clay the SwiftUI `SplashView` strokes its spark
// with), so the icon and the launch splash read identically. The Vellum tokens
// below mirror `Packages/Core/Sources/Core/Theme/SuperTheme.swift` (vellumLight)
// and `docs/design/palettes.jsx`.
//
// Colours are produced by the SAME OKLCH → sRGB transform Core ships in
// `Packages/Core/Sources/Core/Theme/OKLCH.swift`, so the baked PNG/colorset
// pixels match what SwiftUI renders for `theme.background` etc. — no flash
// between the system `UILaunchScreen` and SwiftUI's first frame.
//
// App-icon PNGs are rendered in an OPAQUE (`noneSkipLast`) context so the
// exported file carries NO alpha channel — App Store Connect rejects icon PNGs
// with alpha (ITMS-90717). The SuperBible launch image deliberately keeps its
// alpha (it's a transparent-ground mark; the Vellum field shows through from the
// SplashBackground colour behind it).
//
// Run from the repo root:  swift Scripts/generate_superbible_brand_assets.swift
// It writes directly into App-SuperBible/Assets.xcassets/ and
// App-SuperOS/Assets.xcassets/.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - OKLCH → sRGB (ported verbatim from Core/Theme/OKLCH.swift)

func oklchToSRGB(_ l: Double, _ c: Double, _ h: Double) -> (r: Double, g: Double, b: Double) {
    let hRad = h * .pi / 180.0
    let a = c * cos(hRad)
    let b = c * sin(hRad)

    let lP = l + 0.3963377774 * a + 0.2158037573 * b
    let mP = l - 0.1055613458 * a - 0.0638541728 * b
    let sP = l - 0.0894841775 * a - 1.2914855480 * b

    let lLin = lP * lP * lP
    let mLin = mP * mP * mP
    let sLin = sP * sP * sP

    let rLin =  4.0767416621 * lLin - 3.3077115913 * mLin + 0.2309699292 * sLin
    let gLin = -1.2684380046 * lLin + 2.6097574011 * mLin - 0.3413193965 * sLin
    let bLin = -0.0041960863 * lLin - 0.7034186147 * mLin + 1.7076147010 * sLin

    func encode(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x <= 0.0031308 { return 12.92 * x }
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
    func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    return (clamp(encode(rLin)), clamp(encode(gLin)), clamp(encode(bLin)))
}

// MARK: - Vellum Light tokens (mirror SuperTheme.vellumLight / palettes.jsx)

let vellumBg         = (l: 0.957, c: 0.018, h: 85.0)   // splash / launch ground
let vellumBgSunken   = (l: 0.936, c: 0.022, h: 84.0)   // app-icon tile
let vellumAccent     = (l: 0.520, c: 0.090, h: 52.0)   // star fill + global AccentColor (clay)
// `accentDark` for a light theme = OKLCH(0.36, accent.c, accent.h) — the stroke
// `SplashView` uses for the spark. Matching it keeps the SuperOS icon and splash
// identical.
let vellumAccentDark = (l: 0.360, c: 0.090, h: 52.0)   // spark stroke (deeper clay)

// MARK: - Star of Bethlehem geometry (from the design artifact's icons-splash)
// 16-point path on a 100×100 viewBox, radii alternating long/waist/short/waist.

func starPath(longR: Double = 44, shortR: Double = 22, waistR: Double = 8,
              cx: Double = 50, cy: Double = 50) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<16 {
        let a = Double(i) * .pi * 2 / 16 - .pi / 2
        let r: Double = (i % 4 == 0) ? longR : (i % 2 == 0 ? shortR : waistR)
        let p = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Spark geometry (ported verbatim from Core/Theme/SplashSpark.swift)
// 12 rays; endpoints expressed as fractions of the glyph box (the SVG's
// 24-unit viewBox divided by 24). Stroked with round caps — no fill.

let sparkRays: [(x1: Double, y1: Double, x2: Double, y2: Double)] = [
    (12.000 / 24,  6.720 / 24, 12.000 / 24,  0.960 / 24),
    (14.059 / 24,  8.433 / 24, 17.078 / 24,  3.204 / 24),
    (16.573 / 24,  9.360 / 24, 21.561 / 24,  6.480 / 24),
    (16.118 / 24, 12.000 / 24, 22.157 / 24, 12.000 / 24),
    (16.573 / 24, 14.640 / 24, 21.561 / 24, 17.520 / 24),
    (14.059 / 24, 15.567 / 24, 17.078 / 24, 20.796 / 24),
    (12.000 / 24, 17.280 / 24, 12.000 / 24, 23.040 / 24),
    ( 9.941 / 24, 15.567 / 24,  6.922 / 24, 20.796 / 24),
    ( 7.427 / 24, 14.640 / 24,  2.439 / 24, 17.520 / 24),
    ( 7.882 / 24, 12.000 / 24,  1.843 / 24, 12.000 / 24),
    ( 7.427 / 24,  9.360 / 24,  2.439 / 24,  6.480 / 24),
    ( 9.941 / 24,  8.433 / 24,  6.922 / 24,  3.204 / 24),
]

// MARK: - CoreGraphics helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// A `px`-square sRGB context with a top-left origin (so geometry matches the
/// SVG viewBox). `opaque: true` uses `noneSkipLast` (RGBX) so the exported PNG
/// has NO alpha channel — required for app icons (ITMS-90717). `opaque: false`
/// uses `premultipliedLast` so transparent-ground marks (the launch image) keep
/// their alpha.
func context(_ px: Int, opaque: Bool = false) -> CGContext {
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: alphaInfo.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func color(_ t: (l: Double, c: Double, h: Double), alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = oklchToSRGB(t.l, t.c, t.h)
    return CGColor(colorSpace: srgb, components: [CGFloat(r), CGFloat(g), CGFloat(b), alpha])!
}

/// Draw the star centered in a `px`-square context, scaled so its 100-unit
/// box occupies `coverage` of the square.
func drawStar(in ctx: CGContext, px: Int, coverage: Double, fill: CGColor) {
    let box = Double(px) * coverage
    let scale = box / 100.0
    let offset = (Double(px) - box) / 2.0
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(offset), y: CGFloat(offset))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.addPath(starPath())
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Stroke the spark centered in a `px`-square context, box = `coverage` of the
/// square, round caps. `strokeFraction` is the line width as a fraction of the
/// spark box (the splash strokes 3.2pt on a 44pt frame ≈ 0.073; an app-icon
/// mark reads better a touch bolder).
func drawSpark(in ctx: CGContext, px: Int, coverage: Double,
               strokeFraction: Double, stroke: CGColor) {
    let box = Double(px) * coverage
    let offset = (Double(px) - box) / 2.0
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(offset), y: CGFloat(offset))
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(CGFloat(box * strokeFraction))
    ctx.setLineCap(.round)
    let path = CGMutablePath()
    for r in sparkRays {
        path.move(to: CGPoint(x: r.x1 * box, y: r.y1 * box))
        path.addLine(to: CGPoint(x: r.x2 * box, y: r.y2 * box))
    }
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

func writePNG(_ ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage() else { fatalError("makeImage failed for \(path)") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("CGImageDestination failed for \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed for \(path)") }
    print("  wrote \(path) (\(ctx.width)×\(ctx.height))")
}

/// Write a single-appearance sRGB colorset (`Contents.json`) for `t`.
func writeColorset(_ t: (l: Double, c: Double, h: Double), to path: String) {
    let (r, g, b) = oklchToSRGB(t.l, t.c, t.h)
    func f(_ x: Double) -> String { String(format: "%.4f", x) }
    let contents = """
    {
      "colors" : [
        {
          "color" : {
            "color-space" : "srgb",
            "components" : {
              "alpha" : "1.000",
              "blue" : "\(f(b))",
              "green" : "\(f(g))",
              "red" : "\(f(r))"
            }
          },
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    print("  wrote \(path) (sRGB \(f(r)) \(f(g)) \(f(b)))")
}

// MARK: - Target roots

let root = FileManager.default.currentDirectoryPath
let superBibleAssets = "\(root)/App-SuperBible/Assets.xcassets"
let superOSAssets = "\(root)/App-SuperOS/Assets.xcassets"
for assets in [superBibleAssets, superOSAssets] where !FileManager.default.fileExists(atPath: assets) {
    let msg = "error: \(assets) not found — run from the repo root: " +
        "swift Scripts/generate_superbible_brand_assets.swift\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(1)
}

// MARK: - SuperBible — app icon (star), launch image, splash + accent colours.

print("SuperBible:")
do {
    // App icon — 1024², OPAQUE bgSunken paper, star (accent) at 66%.
    let px = 1024
    let ctx = context(px, opaque: true)
    ctx.setFillColor(color(vellumBgSunken))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    drawStar(in: ctx, px: px, coverage: 0.66, fill: color(vellumAccent))
    writePNG(ctx, to: "\(superBibleAssets)/AppIcon.appiconset/AppIcon.png")

    // Launch image — TRANSPARENT square, centered star (accent). The Vellum
    // ground comes from the SplashBackground colour behind it (both the system
    // UILaunchScreen and SuperBibleContentView paint that colour first), so the
    // image itself is just the mark. 130pt box → ~114pt star, ≈29% of a 393pt
    // screen, matching the design splash (s=112 on 402-wide).
    let launchSet = "\(superBibleAssets)/LaunchImage.imageset"
    for (scale, lpx) in [(2, 260), (3, 390)] {  // @2x=260px, @3x=390px (130pt)
        let lctx = context(lpx)  // transparent (premultipliedLast)
        drawStar(in: lctx, px: lpx, coverage: 1.0, fill: color(vellumAccent))
        writePNG(lctx, to: "\(launchSet)/launch@\(scale)x.png")
    }
    // Drop the retired 3x-named-launch.png from the green design if present.
    let stale = "\(launchSet)/launch.png"
    if FileManager.default.fileExists(atPath: stale) {
        try? FileManager.default.removeItem(atPath: stale)
        print("  removed stale launch.png")
    }
    let launchContents = """
    {
      "images" : [
        {
          "idiom" : "universal",
          "filename" : "launch@2x.png",
          "scale" : "2x"
        },
        {
          "idiom" : "universal",
          "filename" : "launch@3x.png",
          "scale" : "3x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! launchContents.write(toFile: "\(launchSet)/Contents.json", atomically: true, encoding: .utf8)
    print("  wrote LaunchImage Contents.json")

    // Splash ground (Vellum `bg`) + global accent (Vellum `accent`).
    writeColorset(vellumBg, to: "\(superBibleAssets)/SplashBackground.colorset/Contents.json")
    writeColorset(vellumAccent, to: "\(superBibleAssets)/AccentColor.colorset/Contents.json")
}

// MARK: - SuperOS — app icon (spark), splash + accent colours.
// SuperOS's launch screen is colour-only (no launch image), so the spark lives
// in the SwiftUI `SplashView`; the icon mirrors it (spark in `accentDark` on
// `bgSunken`).

print("SuperOS:")
do {
    let px = 1024
    let ctx = context(px, opaque: true)
    ctx.setFillColor(color(vellumBgSunken))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    drawSpark(in: ctx, px: px, coverage: 0.62, strokeFraction: 0.085,
              stroke: color(vellumAccentDark))
    writePNG(ctx, to: "\(superOSAssets)/AppIcon.appiconset/AppIcon.png")

    // Splash ground (Vellum `bg`, replacing the retired green) + global accent.
    writeColorset(vellumBg, to: "\(superOSAssets)/SplashBackground.colorset/Contents.json")
    writeColorset(vellumAccent, to: "\(superOSAssets)/AccentColor.colorset/Contents.json")
}

print("Done.")
