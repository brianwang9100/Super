import SwiftUI

struct SettingsAboutPane: View {
    let viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            Text(viewModel.appInfo.bundleName)
                // The brand wordmark intentionally opts out of app font scaling.
                .font(typography.display(56, relativeTo: nil, tracksFontScale: false))
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
