#if canImport(UIKit)
import SwiftUI
import UIKit

/// A thin SwiftUI wrapper over `UIActivityViewController` so the system share
/// sheet can be presented *programmatically* (via `.sheet`) once an async job
/// produces its artifact — `ShareLink` only fires from a direct tap, so it
/// can't front a spinner-then-share flow. UIKit-only; the package's macOS
/// `swift build`/`swift test` compile this file out.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
