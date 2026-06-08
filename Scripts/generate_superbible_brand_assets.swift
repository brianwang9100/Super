#!/usr/bin/env swift
//
// generate_superbible_brand_assets.swift
//
// Regenerates SuperBible's brand assets — app icon, launch image, and the
// launch/splash background colour — from a single source of truth: the
// Vellum Light theme tokens and the finalized 8-point Star of Bethlehem.
//
// The design (the Claude "Theme Icons & Splash" design artifact — external to
// this repo): a flat themed ground with the star centered, no wordmark. The
// app icon sits on the slightly deeper `bgSunken` paper; the launch/splash
// ground uses the brighter `bg`. The star is the theme `accent` (clay) at
// hue 52. The Vellum tokens below mirror `docs/design/palettes.jsx`.
//
// Colours are produced by the SAME OKLCH → sRGB transform Core ships in
// `Packages/Core/Sources/Core/Theme/OKLCH.swift`, so the baked PNG/colorset
// pixels match what SwiftUI renders for `theme.background` etc. — no flash
// between the system `UILaunchScreen` and SwiftUI's first frame.
//
// Run from the repo root:  swift Scripts/generate_superbible_brand_assets.swift
// It writes directly into App-SuperBible/Assets.xcassets/.

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

// MARK: - Vellum Light tokens (from docs/design/palettes.jsx)

let vellumBg       = (l: 0.957, c: 0.018, h: 85.0)   // splash / launch ground
let vellumBgSunken = (l: 0.936, c: 0.022, h: 84.0)   // app-icon tile
let vellumAccent   = (l: 0.520, c: 0.090, h: 52.0)   // the star (clay)

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

// MARK: - CoreGraphics helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to a top-left origin so the geometry matches the SVG viewBox.
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

func writePNG(_ ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage() else { fatalError("makeImage failed for \(path)") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("CGImageDestination failed for \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed for \(path)") }
    print("  wrote \(path) (\(ctx.width)×\(ctx.height))")
}

// MARK: - Paths

let root = FileManager.default.currentDirectoryPath
let assets = "\(root)/App-SuperBible/Assets.xcassets"
guard FileManager.default.fileExists(atPath: assets) else {
    let msg = "error: \(assets) not found — run from the repo root: " +
        "swift Scripts/generate_superbible_brand_assets.swift\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(1)
}
let iconSet = "\(assets)/AppIcon.appiconset"
let launchSet = "\(assets)/LaunchImage.imageset"
let colorSet = "\(assets)/SplashBackground.colorset"

// MARK: - App icon — 1024², full-bleed bgSunken paper, star (accent) at 66%.

print("App icon:")
do {
    let px = 1024
    let ctx = context(px)
    ctx.setFillColor(color(vellumBgSunken))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    drawStar(in: ctx, px: px, coverage: 0.66, fill: color(vellumAccent))
    writePNG(ctx, to: "\(iconSet)/AppIcon.png")
}

// MARK: - Launch image — transparent square, centered star (accent).
// The Vellum ground comes from the SplashBackground colour behind it (both the
// system UILaunchScreen and SuperBibleContentView paint that colour first), so
// the image itself is just the mark. 130pt box → ~114pt star, ≈29% of a 393pt
// screen, matching the design splash (s=112 on 402-wide).

print("Launch image:")
do {
    // @2x = 260px, @3x = 390px (130pt logical).
    for (scale, px) in [(2, 260), (3, 390)] {
        let ctx = context(px)
        drawStar(in: ctx, px: px, coverage: 1.0, fill: color(vellumAccent))
        writePNG(ctx, to: "\(launchSet)/launch@\(scale)x.png")
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
    print("  wrote Contents.json")
}

// MARK: - SplashBackground colour — Vellum Light `bg`, single appearance.

print("SplashBackground colorset:")
do {
    let (r, g, b) = oklchToSRGB(vellumBg.l, vellumBg.c, vellumBg.h)
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
    try! contents.write(toFile: "\(colorSet)/Contents.json", atomically: true, encoding: .utf8)
    print("  wrote Contents.json (sRGB \(f(r)) \(f(g)) \(f(b)))")
}

print("Done.")
