import SwiftUI

/// Personalization pane. Replaces the previous "System Prompt" pane —
/// the orchestration-side system prompt is no longer user-facing.
/// Single text editor for the user's free-form "about me" text, plus a
/// short helper caption.
///
/// Persistence is committed when the user dismisses the keyboard (loses
/// focus) or leaves the pane — not on every keystroke, since each write
/// is a GRDB (Swift SQLite library) transaction. Local `draft` is the
/// source of truth while the editor has focus; the view model takes
/// over the moment we commit.
struct SettingsPersonalizationPane: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var draft: String = ""
    @State private var hasLoaded = false
    @FocusState private var isFocused: Bool

    @Environment(\.superTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(.subheadline))
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
                    // Commit on focus loss so the user doesn't pay one
                    // GRDB write per keystroke. The displayed draft
                    // remains the source of truth until then.
                    if !focused, hasLoaded, draft != viewModel.settings.userPersonalization {
                        Task { await viewModel.setUserPersonalization(draft) }
                    }
                }

            Text("Tell Super about yourself — your name, preferences, or anything you'd like the assistant to keep in mind.")
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(16)
        .onAppear {
            // Seed the local draft once. `hasLoaded` blocks the focus
            // commit above from firing a redundant write of the value
            // we just read.
            if !hasLoaded {
                draft = viewModel.settings.userPersonalization
                hasLoaded = true
            }
        }
        .onDisappear {
            // Pane teardown also commits, in case the user backed out
            // before the keyboard ever lost focus.
            if hasLoaded, draft != viewModel.settings.userPersonalization {
                Task { await viewModel.setUserPersonalization(draft) }
            }
        }
    }
}
