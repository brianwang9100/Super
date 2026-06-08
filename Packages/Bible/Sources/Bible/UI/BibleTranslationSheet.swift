import Core
import SwiftUI

/// The translation picker: a short bottom-aligned sheet listing the bundled
/// translations. Tapping a row switches the reading translation and closes
/// the sheet; the active translation's row is tinted and checked.
struct BibleTranslationSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Declared once and shared by the nav bar and the presentation so the two
    /// can't drift; a short content-sized sheet.
    private let sizing = SheetSizing.fitsContent

    /// The translation currently in use — its row renders as active.
    let current: BibleTranslation
    /// Extra bottom padding so the last row clears the shell's minimized
    /// chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    let onSelect: (BibleTranslation) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 2) {
                ForEach(BibleTranslation.allCases) { translation in
                    row(translation)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 22 + bottomInset)
        }
        // Detents + drag indicator + background, derived from `sizing`.
        .sheetPresentation(sizing, estimatedHeight: 320)
    }

    private var header: some View {
        SheetNavBar(title: "Translation", sizing: sizing, onClose: onClose)
    }

    private func row(_ translation: BibleTranslation) -> some View {
        let isActive = translation == current
        return Button {
            onSelect(translation)
        } label: {
            HStack(spacing: 14) {
                Text(translation.rawValue)
                    .font(typography.font(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(isActive ? theme.accentInk : theme.inkSoft)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(isActive ? theme.accent : theme.backgroundSunken)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(translation.rawValue)
                        .font(typography.font(size: 15, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? theme.accent : theme.ink)
                    Text(translation.name)
                        .font(typography.font(size: 13))
                        .foregroundStyle(theme.inkFaint)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(typography.font(size: 13, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? theme.accentSoft : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(translation.name)\(isActive ? ", selected" : "")")
    }
}

#Preview {
    BibleTranslationSheet(
        current: .kjv,
        bottomInset: 0,
        onSelect: { _ in },
        onClose: {}
    )
    .superTheme(.make(.vellumLight))
}
