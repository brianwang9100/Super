import Core
import SwiftUI

/// A reader message with optional dismissal and a separate recovery action.
/// Unresolved read failures keep Retry visible; ordinary messages dismiss on tap.
struct BibleAttachToast: View {
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var closeSize: CGFloat = 12
    let message: String
    let onDismiss: (() -> Void)?
    var onRetry: (() -> Void)?
    var systemImage = "bubble.left.and.bubble.right.fill"

    var body: some View {
        HStack(spacing: 0) {
            if let onDismiss {
                Button(action: onDismiss) {
                    messageContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(message)
                .accessibilityHint("Tap to dismiss")
            } else {
                messageContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
            }
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

    private var messageContent: some View {
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
            if onDismiss != nil {
                Image(systemName: "xmark")
                    .font(typography.font(size: closeSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
