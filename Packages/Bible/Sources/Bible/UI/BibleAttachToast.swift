import Core
import SwiftUI

/// A dismissible reader message, with an optional action for recoverable failures.
///
/// A dark card regardless of the active theme, matching the design; a tap
/// anywhere on it dismisses. There is no auto-dismiss timer — the toast stays
/// until tapped, which keeps it free of a time-based test seam.
struct BibleAttachToast: View {
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var closeSize: CGFloat = 12
    let message: String
    let onDismiss: () -> Void
    var onRetry: (() -> Void)?
    var systemImage = "bubble.left.and.bubble.right.fill"

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onDismiss) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(typography.font(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
                    Text(message)
                        .font(typography.font(size: textSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "xmark")
                        .font(typography.font(size: closeSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(message)
            .accessibilityHint("Tap to dismiss")
            if let onRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(typography.font(size: textSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.trailing, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.sRGB, red: 0.11, green: 0.14, blue: 0.125, opacity: 0.96))
        )
    }
}
