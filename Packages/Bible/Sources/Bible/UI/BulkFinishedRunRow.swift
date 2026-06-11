import Core
import SwiftUI

/// One entry in the hub's "Recently finished" section — a run that has reached a
/// terminal state and cleared from the active slot. A completed run reads as a
/// quiet "✓ N annotations"; a stopped run shows its halt reason and failed count
/// plus a **Retry**. Both carry a dismiss control that removes the run.
struct BulkFinishedRunRow: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let summary: FinishedRunSummary
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            leaf
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.bookNames.joined(separator: ", "))
                    .font(typography.font(.subheadline, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(typography.mono(11))
                    .foregroundStyle(summary.status == .failed ? theme.errorInk : theme.inkFaint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if summary.isRetryable { retryButton }
            dismissButton
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.borderFaint, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.bookNames.joined(separator: ", ")), \(detail)")
    }

    @ViewBuilder
    private var leaf: some View {
        if summary.status == .failed {
            Image(systemName: "exclamationmark.triangle")
                .font(typography.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.errorInk)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            AnnotationBubble(state: .filled, size: 22)
        }
    }

    /// `✓ N annotations` for a clean run; `Stopped · <reason> · N failed` for a
    /// halt; a partial completion notes its failed count alongside the total.
    private var detail: String {
        let annotations = "\(summary.producedCount) \(summary.producedCount == 1 ? "annotation" : "annotations")"
        if summary.status == .failed {
            var parts = ["Stopped"]
            if let reason = summary.haltReason { parts.append(Self.reasonText(reason)) }
            if summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
            return parts.joined(separator: " · ")
        }
        if summary.failedCount > 0 {
            return "\(annotations) · \(summary.failedCount) failed"
        }
        return "\(annotations)"
    }

    private static func reasonText(_ reason: BulkRunHaltReason) -> String {
        switch reason {
        case .auth: "Sign-in needed"
        case .quota: "Quota reached"
        case .consecutiveFailures: "Too many errors"
        }
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Text("Retry")
                .font(typography.font(.footnote, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .superGlassButton(in: Capsule())
        .accessibilityLabel("Retry")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(typography.font(size: 12, weight: .bold))
                .foregroundStyle(theme.inkSoft)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .superGlassButton(in: Circle())
        .accessibilityLabel("Dismiss")
    }
}
