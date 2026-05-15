import Core
import SwiftUI

/// The reading surface's top bar: menu, chapter stepping, and the
/// book / translation pill.
///
/// M2 wires the prev / next arrows to chapter navigation. The hamburger and
/// `+` buttons render per the design but are inert until the shell sidebar
/// and chat hand-off land; the centre pill is display-only until the book
/// and translation pickers arrive.
struct BibleNavBar: View {
    @Environment(\.superTheme) private var theme

    let bookName: String
    let chapterNumber: Int
    let translationId: String
    let canStepBackward: Bool
    let canStepForward: Bool
    let onHamburger: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            circleButton(systemImage: "line.3.horizontal", action: onHamburger)
                .accessibilityLabel("Menu")

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
        .padding(.top, 20)
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

    /// The display-only book / translation pill — two segments split by a
    /// hairline. Tapping it opens the pickers in later milestones.
    private var pill: some View {
        HStack(spacing: 0) {
            Text("\(bookName) \(chapterNumber)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

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
        }
        .background(Capsule().fill(theme.backgroundRaised))
        .overlay(Capsule().strokeBorder(theme.borderFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bookName) \(chapterNumber), \(translationId)")
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
