import SwiftUI

/// Code-block chrome matching `.design-tmp/chat/project/src/message-parts.jsx`
/// — a dark surface with a small lang label + copy pill in the header,
/// rounded corners, and a horizontally-scrollable monospaced body painted
/// by ``SplashHighlighter``.
///
/// Wired via `Theme.codeBlock` in `markdownTheme()` so every fenced block
/// inside a ``MarkdownText`` picks up the chrome automatically.
struct CodeBlockView: View {
    let language: String?
    let code: String
    let superTheme: SuperTheme

    @State private var copyState: CopyState = .idle

    private enum CopyState: Equatable {
        case idle
        case copied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            body_
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(superTheme.codeBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header (lang + copy)

    private var header: some View {
        HStack {
            Text(language?.lowercased() ?? "text")
                .font(.system(.caption2, design: .monospaced))
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
        Button {
            UIPasteboardClient.copy(code)
            copyState = .copied
            // Revert the label after a short window so a glance back at
            // the block still says "copy"; the design uses the same
            // 1.2s window.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copyState = .idle
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copyState == .copied ? "checkmark" : "doc.on.doc")
                    .font(.system(.caption2).weight(.semibold))
                Text(copyState == .copied ? "copied" : "copy")
                    .font(.system(.caption2))
            }
            .foregroundStyle(superTheme.codeForeground.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copyState == .copied ? "Copied" : "Copy code")
    }

    // MARK: - Body (highlighted code)

    private var body_: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SplashHighlighter
                .highlight(code, language: language, palette: .from(superTheme))
                .font(.system(.caption, design: .monospaced))
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
