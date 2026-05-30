import SwiftUI

/// Sticky chat header. Centered title that tracks the chat font-scale knob.
/// Renders the text *without* any backdrop — opacity 0 background per the
/// 2026-05-14 refinement. Message-list rows scroll under the title with
/// nothing visually masking them; the title itself is the only thing the
/// user reads at the top of the panel.
///
/// The hamburger menu lives in the shell chrome (`FixedHamburgerButton` in
/// `App/Shell/`) as of the 2026-05-13 design — it persists across the three
/// chat presentation states and is not part of this header.
public struct ChatHeader: View {
    public let title: String

    public init(title: String) {
        self.title = title
    }

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    public var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)
            Text(title)
                .font(typography.font(size: 17, relativeTo: .subheadline, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
