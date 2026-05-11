import SwiftUI

/// Compact error pill rendered above the composer. Pulls its message +
/// optional custom action button (or default Retry pill) from a
/// ``MessageList/ErrorState`` value.
struct ErrorBanner: View {
    let banner: MessageList.ErrorState
    let onRetry: () -> Void
    @Environment(\.superTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(banner.message)
                .font(.system(.footnote))
                .foregroundStyle(theme.errorInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let label = banner.actionLabel, let action = banner.action {
                Button(action: action) {
                    Text(label)
                        .font(.system(.caption).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.errorAccent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(label)")
            } else if banner.showsRetry {
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(.caption2).weight(.semibold))
                        Text("Retry")
                            .font(.system(.caption).weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.errorAccent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.errorBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.errorBorder, lineWidth: 1)
        )
    }
}
