import Core
import SwiftUI

/// The single active generation job on the hub. Title lists every book in the
/// run; progress is measured in **annotations added**, not chapters. The whole
/// card is tappable (drills into per-book progress); the trailing control
/// pauses/resumes.
struct BulkJobCard: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let snapshot: BulkRunSnapshot
    let onOpen: () -> Void
    let onTogglePause: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if snapshot.isRunning {
                        BulkSpinner(size: 16, stroke: 3)
                    } else {
                        Image(systemName: "pause.fill")
                            .font(typography.font(size: 12, weight: .bold))
                            .foregroundStyle(theme.inkMute)
                            .frame(width: 16, height: 16)
                    }
                    Text(snapshot.bookNames.joined(separator: ", "))
                        .font(typography.font(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(typography.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.inkMute)
                }

                Text("\(snapshot.producedCount) of \(snapshot.estimatedTotal) annotations")
                    .font(typography.mono(11.5))
                    .foregroundStyle(theme.accent)
                    .padding(.leading, 26)
                    .padding(.top, 2)
                    .padding(.bottom, 10)

                HStack(spacing: 11) {
                    BulkProgressBar(value: snapshot.isRunning ? snapshot.fractionComplete : nil, height: 6)
                    pauseButton
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.backgroundRaised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.borderFaint, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.bookNames.joined(separator: ", ")), \(snapshot.producedCount) of \(snapshot.estimatedTotal) annotations")
        .accessibilityHint("Opens per-book progress")
    }

    private var pauseButton: some View {
        Button(action: onTogglePause) {
            Image(systemName: snapshot.isRunning ? "pause.fill" : "play.fill")
                .font(typography.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.inkSoft)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .superGlassButton(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(snapshot.isRunning ? "Pause" : "Resume")
    }
}
