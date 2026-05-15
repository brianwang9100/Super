import Core
import SwiftUI

/// The reading surface's top bar: menu, chapter stepping, and the
/// book / translation pill.
///
/// M2 wires the prev / next arrows to chapter navigation; M3 wires the pill's
/// book segment to the book picker. The `+` button renders per the design but
/// is inert until chat hand-off lands; the pill's translation segment is
/// display-only until that picker arrives. The sidebar entry point is the
/// shell's own floating hamburger, so this bar deliberately has none.
struct BibleNavBar: View {
    @Environment(\.superTheme) private var theme

    let bookName: String
    let chapterNumber: Int
    let translationId: String
    let canStepBackward: Bool
    let canStepForward: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPill: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Balances the trailing `+` so the chapter group stays centered;
            // the shell's floating hamburger sits over this gap.
            Color.clear.frame(width: 36, height: 36)

            HStack(spacing: 6) {
                circleButton(systemImage: "chevron.left", action: onPrevious)
                    .disabled(!canStepBackward)
                    .opacity(canStepBackward ? 1 : 0.35)
                    .accessibilityLabel("Previous chapter")

                pill

                circleButton(systemImage: "chevron.right", action: onNext)
                    .disabled(!canStepForward)
                    .opacity(canStepForward ? 1 : 0.35)
                    .accessibilityLabel("Next chapter")
            }
            .frame(maxWidth: .infinity)

            plusButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(
            // Solid at the top, fading out at the bottom edge so verses
            // scroll cleanly under the bar instead of meeting a hard line.
            LinearGradient(
                colors: [theme.background, theme.background, theme.background.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    /// The book / translation pill — two segments split by a hairline. The
    /// book segment opens the book picker; the translation segment is
    /// display-only until that picker lands.
    private var pill: some View {
        HStack(spacing: 0) {
            Button(action: onPill) {
                Text("\(bookName) \(chapterNumber)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(bookName) \(chapterNumber), choose book")

            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            HStack(spacing: 4) {
                Text(translationId)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.inkSoft)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .accessibilityLabel("Translation \(translationId)")
        }
        .background(Capsule().fill(theme.backgroundRaised))
        .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 0.5))
    }

    private var plusButton: some View {
        Button(action: onPlus) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start chat with this chapter")
    }

    private func circleButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.backgroundRaised))
                .overlay(Circle().strokeBorder(theme.borderFaint, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
