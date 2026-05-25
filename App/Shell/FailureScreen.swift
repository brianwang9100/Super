import SwiftUI

/// Inline error pane shown when bootstrap fails or the chat view model
/// can't be wired. Lives in `App/Shell/` because both the outer per-target
/// content view (`SuperOSContentView` / `SuperBibleContentView`, for
/// `.failed(_)`) and the inner `ChatLayer` (for the post-bootstrap
/// "could not open chat" path) render it, and the SuperOS + SuperBible
/// targets both include this file.
struct FailureScreen: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bootstrap failed")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
