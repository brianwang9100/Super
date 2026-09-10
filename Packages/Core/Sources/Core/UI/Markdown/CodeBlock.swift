import SwiftUI

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
            // Environment values are available here, after the State controller's construction.
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
