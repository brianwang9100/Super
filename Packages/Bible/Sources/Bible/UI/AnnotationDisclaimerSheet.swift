import Core
import SwiftUI

/// One-time liability sheet shown the first time the user fires any
/// annotation tool call.
///
/// Anatomy: drag handle, an accent-soft icon panel with a filled
/// `AnnotationBubble` glyph, a serif title, two short body paragraphs,
/// and a prominent accent-filled "Got it" button. Acknowledgement is
/// persisted by the caller in PR 3 (`UserDefaults` key
/// `"bible.annotations.disclaimerAcknowledged"`) — this view itself
/// only fires `onGotIt()`.
///
/// Body copy is fixed by the spec (`docs/SuperBible/ANNOTATIONS.md` §8)
/// so it lives inline here rather than as an inputable string.
struct AnnotationDisclaimerSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Extra bottom padding so the button clears the shell's minimized
    /// chat pill; `0` in standalone (snapshot) contexts.
    let bottomInset: CGFloat
    let onGotIt: () -> Void

    /// Required `onGotIt` first, optional `bottomInset` last, per the
    /// root AGENTS.md "Default parameter values" rule.
    init(onGotIt: @escaping () -> Void, bottomInset: CGFloat = 0) {
        self.bottomInset = bottomInset
        self.onGotIt = onGotIt
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            iconPanel
                .padding(.top, 4)
                .padding(.bottom, 16)
            Text("About AI annotations")
                .font(typography.font(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)
            paragraph("Annotations are AI-generated and may contain errors. SuperBible doesn’t verify theological accuracy.")
                .padding(.bottom, 8)
            paragraph("Treat them as a starting point — not as commentary you’d cite.")
            Spacer(minLength: 24)
            gotItButton
                .padding(.bottom, 30 + bottomInset)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(theme.background)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var iconPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.accentSoft)
                .frame(width: 56, height: 56)
            AnnotationBubble(state: .filled, size: 28)
        }
        .accessibilityHidden(true)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(typography.font(size: 14.5))
            .lineSpacing(3)
            .foregroundStyle(theme.inkSoft)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var gotItButton: some View {
        Button(action: onGotIt) {
            Text("Got it")
                .font(typography.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Acknowledge")
    }
}
