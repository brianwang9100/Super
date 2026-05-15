import Core
import SwiftUI

/// The reading surface's top bar: menu, chapter stepping, and the
/// book / translation pill.
///
/// The prev / next arrows step chapters and the pill's two segments open the
/// book and translation pickers. The `+` button renders per the design but is
/// inert until chat hand-off lands. The sidebar entry point is the shell's own
/// floating hamburger, so this bar deliberately has none.
struct BibleNavBar: View {
    @Environment(\.superTheme) private var theme

    let bookName: String
    let chapterNumber: Int
    let translation: BibleTranslation
    let canStepBackward: Bool
    let canStepForward: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPill: () -> Void
    let onTranslation: () -> Void
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

    /// The book / translation pill — two segments split by a hairline,
    /// matching the 36pt height of the circular nav buttons. The book
    /// segment opens the book picker; the translation segment opens the
    /// translation picker.
    private var pill: some View {
        HStack(spacing: 0) {
            Button(action: onPill) {
                Text("\(bookName) \(chapterNumber)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    // A fixed width so the arrows flanking the pill never
                    // shift as the reader steps between chapters or books;
                    // the few longest names scale down slightly to fit.
                    .frame(width: 108)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(bookName) \(chapterNumber), choose book")

            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            Button(action: onTranslation) {
                HStack(spacing: 4) {
                    Text(translation.code)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.inkSoft)
                .padding(.horizontal, 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Translation \(translation.code), choose translation")
        }
        .frame(height: 36)
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
