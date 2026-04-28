import SwiftUI

/// System Prompt pane. Mirrors `PromptPane` from `settings.jsx`: a 10-row
/// `--bg-raised` text area with a faint border, plus a `"Applied to new
/// chats. {N} chars."` caption underneath.
///
/// Persistence is committed when the user dismisses the keyboard (loses
/// focus) or leaves the pane — not on every keystroke, since each write
/// is a GRDB transaction. Local `draft` is the source of truth while the
/// editor has focus; the view model takes over the moment we commit.
struct SettingsPromptPane: View {
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
                    if !focused, hasLoaded, draft != viewModel.settings.systemPrompt {
                        Task { await viewModel.setSystemPrompt(draft) }
                    }
                }

            Text("Applied to new chats. \(draft.count) chars.")
                .font(.system(.caption))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(16)
        .onAppear {
            // Seed the local draft once. `hasLoaded` blocks the focus
            // commit above from firing a redundant write of the value
            // we just read.
            if !hasLoaded {
                draft = viewModel.settings.systemPrompt
                hasLoaded = true
            }
        }
        .onDisappear {
            // Pane teardown also commits, in case the user backed out
            // before the keyboard ever lost focus.
            if hasLoaded, draft != viewModel.settings.systemPrompt {
                Task { await viewModel.setSystemPrompt(draft) }
            }
        }
    }
}
