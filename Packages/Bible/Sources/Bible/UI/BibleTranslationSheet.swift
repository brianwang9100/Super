import Core
import SwiftUI

/// The translation picker: a short bottom-aligned sheet listing the bundled
/// translations. Tapping a row switches the reading translation and closes
/// the sheet; the active translation's row is tinted and checked.
struct BibleTranslationSheet: View {
    @Environment(\.superTheme) private var theme

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
        // Top clearance for the system drag indicator now that the native
        // `.sheet` supplies it in place of the removed custom grabber.
        .padding(.top, 10)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var header: some View {
        HStack {
            Text("Translation")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
            Spacer()
            Button("Done", action: onClose)
                .font(.system(size: 14))
                .foregroundStyle(theme.inkFaint)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func row(_ translation: BibleTranslation) -> some View {
        let isActive = translation == current
        return Button {
            onSelect(translation)
        } label: {
            HStack(spacing: 14) {
                Text(translation.rawValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(isActive ? theme.accentInk : theme.inkSoft)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(isActive ? theme.accent : theme.backgroundSunken)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(translation.rawValue)
                        .font(.system(size: 15, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? theme.accent : theme.ink)
                    Text(translation.name)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.inkFaint)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
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
    .superTheme(.make(.light))
}
