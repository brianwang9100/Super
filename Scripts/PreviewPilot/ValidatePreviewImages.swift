import AppKit
import Foundation

/// Decodes PNGs to the same premultiplied sRGB representation to validate the complete image payload.
func pixels(at path: String) -> (width: Int, height: Int, bytes: [UInt8])? {
    // ImageIO can recover truncated PNGs. Require the PNG terminator as well
    // so a partially written export never becomes a new visual baseline.
    let endChunk: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          data.suffix(endChunk.count).elementsEqual(endChunk),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetStatus(source) == .statusComplete,
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
    return rendered && CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        ? (width, height, bytes) : nil
}

// Validate every exported image, including UIKit probes. Inventory and dimensions
// are independently checked by verify.py before this decoder runs.
let args = CommandLine.arguments
precondition(args.count == 2, "Usage: swift ValidatePreviewImages.swift EXPORTS")
let exports = try FileManager.default.contentsOfDirectory(atPath: args[1]).filter { $0.hasSuffix(".png") }
guard !exports.isEmpty else {
    print("No exported images")
    exit(1)
}
for image in exports where pixels(at: args[1] + "/" + image) == nil {
    print("Invalid exported image: \(image)")
    exit(1)
}
print("Decoded \(exports.count) complete PNG images")
