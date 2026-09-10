import Core
import SwiftUI

/// Chapter history and a content-hugging passage/translation button share one glass surface.
struct BibleNavigationSelector: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var bookSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var translationSize: CGFloat = 11

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    let backLabel: String?
    let forwardLabel: String?
    let wraps: Bool
    let isRestoring: Bool
    let morph: GlassMorphID
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
                        passageButton
                    }
                }
            } else {
                horizontalRow
            }
        }
        .superGlassSurface(in: RoundedRectangle(cornerRadius: 22), morph: morph)
        .disabled(isRestoring)
    }

    private var horizontalRow: some View {
        HStack(spacing: 0) {
            historyButtons
            divider
            passageButton
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

    private var passageButton: some View {
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
            .padding(.horizontal, 10)
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

    /// Adjacent compact tap regions retain the approved 28 pt glyph-center spacing.
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
