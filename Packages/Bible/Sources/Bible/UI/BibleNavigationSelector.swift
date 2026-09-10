import Core
import SwiftUI

struct BibleNavigationSelector: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var bookSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var translationSize: CGFloat = 11
    // Mean of 66 book names at 15pt medium (59.62pt), plus " 12" (20pt), rounded up.
    @ScaledMetric(relativeTo: .body) private var minimumLabelWidth: CGFloat = 80

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
                        passageButton(minimumWidth: nil)
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
            passageButton(minimumWidth: minimumLabelWidth * typography.fontScale)
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

    private func passageButton(minimumWidth: CGFloat?) -> some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                Text("\(bookName) \(chapterNumber)")
                    .font(typography.font(size: bookSize, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(wraps ? nil : 1)
                    .fixedSize(horizontal: !wraps, vertical: true)
                    .multilineTextAlignment(.center)
                Text(translation.rawValue)
                    .font(typography.font(size: translationSize, weight: .medium))
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize()
            }
            .frame(minWidth: minimumWidth)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("\(bookName) \(chapterNumber), \(translation.name), choose passage and translation")
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.border.opacity(0.6))
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    /// The opposing image offsets keep adjacent glyph centers 28 points apart.
    private func historyButton(
        image: String, offset: CGFloat, label: String,
        destination: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(typography.font(size: glyphSize, weight: .medium))
                .foregroundStyle(theme.ink)
                .offset(x: offset)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .disabled(destination == nil)
        .opacity(destination == nil ? 0.35 : 1)
        .accessibilityLabel(label)
        .accessibilityHint(destination.map { "\($0)." } ?? "No chapter in this direction.")
    }
}
