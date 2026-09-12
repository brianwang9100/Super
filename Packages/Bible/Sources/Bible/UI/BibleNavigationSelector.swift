import Core
import SwiftUI

struct BibleNavigationSelector: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var bookSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var translationSize: CGFloat = 11
    // Nearest-rank p90 of 66 book names at 14pt medium (86.33pt), plus " 12" (19pt), rounded up.
    @ScaledMetric(relativeTo: .body) private var preferredLabelWidth: CGFloat = 106

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    let backLabel: String?
    let forwardLabel: String?
    let wraps: Bool
    let isRestoring: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Group {
            if wraps {
                ViewThatFits(in: .horizontal) {
                    horizontalRow
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 0) {
                        historyButtons
                        Rectangle()
                            .fill(theme.border.opacity(0.6))
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                            .accessibilityHidden(true)
                        passageButton(preferredWidth: nil)
                    }
                }
            } else {
                horizontalRow
            }
        }
        .disabled(isRestoring)
    }

    private var horizontalRow: some View {
        HStack(spacing: 0) {
            historyButtons
            divider
            passageButton(preferredWidth: preferredLabelWidth * typography.fontScale)
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 0) {
            historyButton(image: "chevron.left", offset: 2, label: "Go back",
                          destination: backLabel, action: onBack)
            historyButton(image: "chevron.right", offset: -2, label: "Go forward",
                          destination: forwardLabel, action: onForward)
        }
    }

    private func passageButton(preferredWidth: CGFloat?) -> some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                Text("\(bookName) \(chapterNumber)")
                    .font(typography.font(size: bookSize, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(wraps ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                Text(translation.rawValue)
                    .font(typography.font(size: translationSize, weight: .medium))
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize()
            }
            .frame(minWidth: 0, idealWidth: preferredWidth, maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .layoutPriority(-1)
        .accessibilityLabel("\(bookName) \(chapterNumber), \(translation.name), choose passage and translation")
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border.opacity(0.6))
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    /// The opposing image offsets keep adjacent glyph centers 28 points apart at the default size.
    private func historyButton(
        image: String, offset: CGFloat, label: String,
        destination: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(typography.font(size: glyphSize, weight: .medium))
                .foregroundStyle(theme.ink)
                .offset(x: offset)
                .padding(4)
                .frame(minWidth: 32, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .disabled(destination == nil)
        .opacity(destination == nil ? 0.35 : 1)
        .accessibilityLabel(label)
        .accessibilityHint(destination.map { "\($0)." } ?? "No chapter in this direction.")
    }
}
