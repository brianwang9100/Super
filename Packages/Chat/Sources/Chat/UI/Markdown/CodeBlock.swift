import Core
import SwiftUI

/// Code-block chrome matching `.design-tmp/chat/project/src/message-parts.jsx`
/// — a dark surface with a small lang label + copy pill in the header,
/// rounded corners, and a horizontally-scrollable monospaced body painted
/// by ``SplashHighlighter``.
///
/// Wired via `Theme.codeBlock` in `markdownTheme()` so every fenced block
/// inside a ``MarkdownText`` picks up the chrome automatically. The copy
/// state machine lives in ``CodeBlockCopyController`` so its timing and
/// cancellation behavior can be tested without rendering this view.
struct CodeBlock: View {
    let language: String?
    let code: String
    let superTheme: SuperTheme

    @Environment(\.pasteboardClient) private var pasteboard
    @Environment(\.superTypography) private var typography
    @State private var copyController = CodeBlockCopyController(pasteboard: SystemPasteboardClient())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            highlightedBody
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(superTheme.codeBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            // Swap the controller's pasteboard to the env-injected one
            // now that the environment is readable. Tests inject a
            // recording double via `.environment(\.pasteboardClient, ...)`
            // and rely on this swap to redirect copy() to it.
            copyController.pasteboard = pasteboard
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(language?.lowercased() ?? "Plain") code block"))
    }

    // MARK: - Header (lang + copy)

    private var header: some View {
        HStack {
            Text(language?.lowercased() ?? "text")
                .font(typography.mono(11, relativeTo: .caption2))
                .tracking(0.3)
                .foregroundStyle(superTheme.codeForeground.opacity(0.7))
            Spacer(minLength: 0)
            copyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            // The 1pt hairline divider matches the design's `border-bottom`
            // on the header row. Painted from the code foreground at low
            // opacity so it blends the same in light/dark/sepia.
            Rectangle()
                .fill(superTheme.codeForeground.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var copyButton: some View {
        let copied = copyController.state == .copied
        return Button {
            copyController.copy(code)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(typography.font(.caption2, weight: .semibold))
                Text(copied ? "copied" : "copy")
                    .font(typography.font(.caption2))
            }
            .foregroundStyle(superTheme.codeForeground.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy code")
        // VoiceOver announces the value change when state flips so the
        // user gets the same feedback the visible icon swap provides.
        .accessibilityValue(copied ? "Copied to clipboard" : "")
    }

    // MARK: - Body (highlighted code)

    private var highlightedBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SplashHighlighter
                .highlight(code, language: language, palette: .from(superTheme))
                .font(typography.mono(12, relativeTo: .caption))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
