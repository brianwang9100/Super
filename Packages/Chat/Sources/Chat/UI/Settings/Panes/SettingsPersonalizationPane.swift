import SwiftUI

struct SettingsPersonalizationPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var draft: String = ""
    @State private var hasLoaded = false
    @FocusState private var isFocused: Bool

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(typography.font(.subheadline))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(14)
                .frame(minHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.backgroundRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.borderFaint, lineWidth: 1)
                )
                .foregroundStyle(theme.ink)
                .onChange(of: isFocused) { _, focused in
                    // Commit on focus loss to avoid a database write per keystroke.
                    if !focused, hasLoaded, draft != viewModel.settings.userPersonalization {
                        Task { await viewModel.setUserPersonalization(draft) }
                    }
                }

            Text("Tell Super about yourself — your name, preferences, or anything you'd like the assistant to keep in mind.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(16)
        .onAppear {
            if !hasLoaded {
                draft = viewModel.settings.userPersonalization
                hasLoaded = true
            }
        }
        .onDisappear {
            // Also commit on teardown if focus loss never arrived.
            if hasLoaded, draft != viewModel.settings.userPersonalization {
                Task { await viewModel.setUserPersonalization(draft) }
            }
        }
    }
}
