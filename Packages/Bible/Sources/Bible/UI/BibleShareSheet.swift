import SwiftUI

#if canImport(UIKit)
import UIKit

struct BibleShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
struct BibleShareSheet: View {
    let text: String
    var body: some View { ShareLink(item: text).padding() }
}
#endif
