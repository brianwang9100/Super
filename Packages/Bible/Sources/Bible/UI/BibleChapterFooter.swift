import Core
import SwiftUI

struct BibleChapterFooter: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let previousLabel: String?
    let nextLabel: String?
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        // Share glass sampling while preserving the gap and separate card shapes.
        SuperGlassContainer(spacing: 0) {
            HStack(spacing: 8) {
                if let previousLabel {
                    card(isPrevious: true, label: previousLabel, action: onPrevious)
                }
                if let nextLabel {
                    card(isPrevious: false, label: nextLabel, action: onNext)
                }
            }
        }
        .padding(.top, 28)
    }

    private func card(
        isPrevious: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let kicker = isPrevious ? "Previous" : "Next"
        let alignment: HorizontalAlignment = isPrevious ? .leading : .trailing
        return Button(action: action) {
            HStack(spacing: 10) {
                if isPrevious {
                    Image(systemName: "chevron.left")
                        .font(typography.font(size: 12, weight: .semibold))
                }
                VStack(alignment: alignment, spacing: 2) {
                    Text(kicker.uppercased())
                        .font(typography.font(size: 9.5, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(theme.inkFaint)
                    Text(label)
                        .font(typography.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: isPrevious ? .leading : .trailing)
                if !isPrevious {
                    Image(systemName: "chevron.right")
                        .font(typography.font(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(theme.inkSoft)
            .padding(14)
            .frame(maxWidth: .infinity)
            .superGlassButton(in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("\(kicker) chapter, \(label)")
    }
}
