import SwiftUI

/// About pane. Mirrors `AboutPane` from `settings.jsx`: large italic-serif
/// "Super" wordmark, a mono `v… · build …` line, and a centered tagline.
struct SettingsAboutPane: View {
    let viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text("Super")
                .font(.system(size: 56, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(theme.ink)
                .padding(.bottom, 10)

            Text("v\(viewModel.appInfo.version) · build \(viewModel.appInfo.build)")
                .font(.system(.caption, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(theme.inkFaint)

            Text("A personal chat app. Your chats stay on device.")
                .font(.system(.subheadline))
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
