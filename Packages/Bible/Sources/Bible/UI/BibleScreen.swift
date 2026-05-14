import SwiftUI

/// M0 placeholder for the Bible applet backdrop. Renders the applet glyph
/// inside a soft accent disc plus the display name and a "Coming soon"
/// caption — the same shape `App/Shell/Placeholders/AppletPlaceholderScreen`
/// used to render before the real package landed. Real chapter rendering
/// (paragraphs, verse spans, navigation, selection, sheets) lands in M1+.
///
/// Uses system colors (`Color.primary`, `Color(.systemBackground)`) so M0
/// can ship without depending on `SuperTheme` — that type currently lives in
/// the Chat package and Bible cannot import Chat. M1 either hoists
/// `SuperTheme` into `Core` or exposes the per-theme tokens applets need
/// through a smaller protocol; either way the swap is local to this view.
public struct BibleScreen: View {
    /// Reuses `BibleApplet.accentColor` so the literal lives in one place
    /// until M1's `SuperTheme` migration replaces it.
    private static let accent = BibleApplet.accentColor

    public init() {}

    public var body: some View {
        ZStack {
            #if canImport(UIKit)
            Color(.systemBackground)
                .ignoresSafeArea()
            #else
            Color.primary.opacity(0.04)
                .ignoresSafeArea()
            #endif

            VStack(spacing: 18) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Self.accent.opacity(0.12))
                        .frame(width: 96, height: 96)
                    BibleAppletIcon(size: 44)
                        .foregroundStyle(Self.accent)
                }
                Text("Bible")
                    .font(.system(size: 36, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.primary)
                Text("Coming soon.")
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                Spacer()
                // Reserve bottom inset so the chat overlay's minimized pill
                // doesn't permanently obscure the caption — matches the
                // 76pt reserve used by `AppletPlaceholderScreen`.
                Color.clear.frame(height: 76)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    BibleScreen()
}
