#if canImport(UIKit)
import SwiftUI
import UIKit

/// Presents after asynchronous export completes; ShareLink requires a direct tap.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
