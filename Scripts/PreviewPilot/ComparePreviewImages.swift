import AppKit
import Foundation

/// Decodes PNGs to the same premultiplied sRGB representation for exact pixel comparison.
func pixels(at path: String) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? (width, height, bytes) : nil
}

// Arguments: repository root, export directory, report path. Never writes a baseline.
let args = CommandLine.arguments
precondition(args.count == 4, "Usage: swift ComparePreviewImages.swift ROOT EXPORTS REPORT")
let inventoryURL = URL(fileURLWithPath: args[1]).appendingPathComponent("Scripts/PreviewPilot/composer-inventory.json")
let inventory = try JSONSerialization.jsonObject(with: Data(contentsOf: inventoryURL)) as! [[String: Any]]
// Decode every exported PNG, including UIKit probes without legacy counterparts.
let exports = try FileManager.default.contentsOfDirectory(atPath: args[2]).filter { $0.hasSuffix(".png") }
for image in exports where pixels(at: args[2] + "/" + image) == nil {
    print("Invalid exported image: \(image)")
    exit(2)
}
var results: [[String: Any]] = []
for entry in inventory {
    let baseline = entry["baseline"] as! String
    let image = entry["image"] as! String
    var result: [String: Any] = ["baseline": baseline, "image": image, "precision": 1]
    if let old = pixels(at: args[1] + "/" + baseline), let new = pixels(at: args[2] + "/" + image) {
        result["baselinePixels"] = [old.width, old.height]
        result["previewPixels"] = [new.width, new.height]
        if old.width != new.width || old.height != new.height {
            result["status"] = "dimension-mismatch"
        } else {
            var changed = 0
            var changedAboveTwo = 0
            var maximumDifference = 0
            var absoluteDifference: UInt64 = 0
            for offset in stride(from: 0, to: old.bytes.count, by: 4) {
                var differs = false
                var pixelMaximum = 0
                for channel in 0..<4 {
                    let delta = abs(Int(old.bytes[offset + channel]) - Int(new.bytes[offset + channel]))
                    differs = differs || delta != 0
                    pixelMaximum = max(pixelMaximum, delta)
                    absoluteDifference += UInt64(delta)
                }
                if differs { changed += 1 }
                if pixelMaximum > 2 { changedAboveTwo += 1 }
                maximumDifference = max(maximumDifference, pixelMaximum)
            }
            result["changedPixels"] = changed
            result["changedPixelFraction"] = Double(changed) / Double(old.width * old.height)
            // Diagnostic only: these do not relax the exact-pixel pass criterion.
            result["pixelsWithChannelDifferenceAbove2"] = changedAboveTwo
            result["maximumChannelDifference"] = maximumDifference
            result["meanAbsoluteChannelDifference"] = Double(absoluteDifference) / Double(old.bytes.count)
            result["status"] = changed == 0 ? "exact" : "pixel-mismatch"
        }
    } else {
        result["status"] = "missing-or-invalid-image"
    }
    results.append(result)
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: args[3]))
print(Dictionary(grouping: results, by: { $0["status"] as! String }).mapValues(\.count))
// A successful renderer is not proof of parity. Non-exact rows remain a failing gate.
exit(results.allSatisfy { $0["status"] as? String == "exact" } ? 0 : 1)
