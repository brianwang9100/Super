import SwiftUI

/// Compact error pill rendered above the composer. Pulls its message +
/// optional custom action button (or default Retry pill) from a
/// ``MessageList/ErrorState`` value.
///
/// When the error carries a verbose ``MessageList/ErrorState/detail`` (e.g. a
/// provider's raw error body), the banner stays compact and offers a "Details"
/// disclosure that expands to show the full text — rather than dumping the
/// whole payload inline.
struct ErrorBanner: View {
    let banner: MessageList.ErrorState
    let onRetry: () -> Void
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var showsDetail: Bool

    /// - Parameter initiallyExpanded: Seeds the detail-disclosure state.
    ///   Production always starts collapsed; snapshot tests pass `true` to
    ///   pin the expanded state (otherwise reachable only via tap).
    init(
        banner: MessageList.ErrorState,
        initiallyExpanded: Bool = false,
        onRetry: @escaping () -> Void
    ) {
        self.banner = banner
        self.onRetry = onRetry
        _showsDetail = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(banner.message)
                    .font(typography.font(.footnote))
                    .foregroundStyle(theme.errorInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingControl
            }

            if banner.detail != nil {
                detailDisclosure
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

    @ViewBuilder
    private var trailingControl: some View {
        if let label = banner.actionLabel, let action = banner.action {
            Button(action: action) {
                pill(label)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(label)")
        } else if banner.showsRetry {
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(typography.font(.caption2, weight: .semibold))
                    Text("Retry")
                        .font(typography.font(.caption, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.errorAccent))
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(_ label: String) -> some View {
        Text(label)
            .font(typography.font(.caption, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.errorAccent))
    }

    @ViewBuilder
    private var detailDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsDetail.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(showsDetail ? "Hide details" : "Details")
                    .font(typography.font(.caption, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(typography.font(.caption2, weight: .semibold))
                    .rotationEffect(.degrees(showsDetail ? 180 : 0))
            }
            .foregroundStyle(theme.errorInk.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDetail ? "Hide error details" : "Show error details")

        if showsDetail, let detail = banner.detail {
            // Rendered inline (not a nested ScrollView): the banner lives inside
            // the chat transcript's own ScrollView, so a second scroll view here
            // would fight it for the scroll gesture. The outer transcript scrolls
            // the expanded detail instead.
            Text(detail)
                .font(typography.mono(11))
                .foregroundStyle(theme.errorInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.errorBorder.opacity(0.12))
                )
        }
    }
}
