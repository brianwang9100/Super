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
                .font(typography.display(56, relativeTo: nil))
                .italic()
                .foregroundStyle(theme.ink)
                .padding(.bottom, 10)

            Text("v\(viewModel.appInfo.version) · build \(viewModel.appInfo.build)")
                .font(typography.mono(12, relativeTo: .caption))
                .tracking(0.5)
                .foregroundStyle(theme.inkFaint)

            Text("A personal chat app. Your chats stay on device.")
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
