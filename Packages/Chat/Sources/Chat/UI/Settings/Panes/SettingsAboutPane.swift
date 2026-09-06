import SwiftUI

/// About pane. Mirrors `AboutPane` from `settings.jsx`: large italic-serif
/// brand wordmark (`SuperOS` / `SuperBible`, from `SuperAppInfo.bundleName`),
/// a mono `v… · build …` line, and a centered tagline.
struct SettingsAboutPane: View {
    let viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            Text(viewModel.appInfo.bundleName)
                // Fixed brand wordmark: pinned off the font-scale slider
                // (tracksFontScale: false) so a 56pt mark doesn't balloon at
                // max slider. The version/description below it are content and
                // scale with the slider like the rest of the pane.
                .font(typography.display(56, relativeTo: nil, tracksFontScale: false))
                .italic()
                .foregroundStyle(theme.ink)
                .padding(.bottom, 10)

            Text("v\(viewModel.appInfo.version) · build \(viewModel.appInfo.build)")
                .font(typography.mono(12, relativeTo: .caption))
                .tracking(0.5)
                .foregroundStyle(theme.inkFaint)

            Text("A personal chat app. Local history. Your choice of local or cloud AI.")
                .font(typography.font(.subheadline))
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 260)
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
