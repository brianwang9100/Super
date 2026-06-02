import Core
import SwiftUI

/// The bottom toast that confirms a chat hand-off — used this milestone only
/// as the "chat ships later" stub.
///
/// A dark card regardless of the active theme, matching the design; a tap
/// anywhere on it dismisses. There is no auto-dismiss timer — the toast stays
/// until tapped, which keeps it free of a time-based test seam.
struct BibleAttachToast: View {
    @Environment(\.superTypography) private var typography
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(typography.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
                Text(message)
                    .font(typography.font(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .font(typography.font(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.sRGB, red: 0.11, green: 0.14, blue: 0.125, opacity: 0.96))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message)
        .accessibilityHint("Tap to dismiss")
    }
}
