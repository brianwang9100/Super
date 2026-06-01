import SwiftUI

/// Inline pill rendered under an assistant message whose turn produced a
/// successful `memory` tool call.
///
/// Compact and faint so it doesn't compete with the message body — the
/// LLM (Large Language Model) saving a memory should feel ambient, not
/// like a tool-use receipt. Tap toggles between the collapsed "Memory
/// updated" chip and an expanded line that names the op (Saved / Updated
/// / Forgot) and the text. Failed memory calls fall back to the normal
/// `ToolCallBlock` upstream so the error is still surfaced.
struct MemoryUpdatedPill: View {
    /// Single successful memory tool call rendered by this pill. The
    /// `parametersJSON` is parsed once at init time; failure to parse
    /// (a malformed payload from a future tool revision) collapses to
    /// the generic "Memory updated" label without leaking JSON.
    let call: MessageList.ToolCallItem
    /// Parsed view of the tool's `op` and `text` parameters, computed
    /// once in init so `body`'s repeated reads from `headline` and the
    /// accessibility label don't re-run `JSONSerialization` per render.
    /// Unexpected payloads collapse to `.unknown` with empty text.
    private let parsed: ParsedMemoryCall
    @State private var isExpanded: Bool
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    /// Production initializer — pill starts collapsed; user taps to expand.
    init(call: MessageList.ToolCallItem) {
        self.call = call
        self.parsed = ParsedMemoryCall.parse(call.parametersJSON)
        self._isExpanded = State(initialValue: false)
    }

    /// Test-only seam that seeds the `isExpanded` `@State` so snapshot
    /// tests can pin the expanded baseline without driving a tap. The
    /// underscore prefix follows the codebase convention for surfaces
    /// that are not stable API (see `ChatScreenViewModel
    /// ._waitForPendingTitleTask()` per AGENTS.md §Testing rule 2).
    init(call: MessageList.ToolCallItem, _isExpanded: Bool) {
        self.call = call
        self.parsed = ParsedMemoryCall.parse(call.parametersJSON)
        self._isExpanded = State(initialValue: _isExpanded)
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "brain")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.inkFaint)
                Text(headline)
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkSoft)
                if let detail = detailText {
                    Text("— \(detail)")
                        .font(typography.font(.caption))
                        .foregroundStyle(theme.inkFaint)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.backgroundSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.borderFaint, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var headline: String {
        switch parsed.op {
        case .save: return "Saved to memory"
        case .update: return "Updated memory"
        case .forget: return "Forgot memory"
        case .unknown: return "Memory updated"
        }
    }

    /// Detail text rendered in the expanded state. `nil` when nothing
    /// meaningful would render — either the pill is collapsed, the
    /// parsed `text` is empty, or the op is `forget` (whose input JSON
    /// only carries `id`, never the text being forgotten; "Forgot
    /// memory" alone is the right ambient confirmation).
    private var detailText: String? {
        guard isExpanded else { return nil }
        switch parsed.op {
        case .save, .update, .unknown:
            return parsed.text.isEmpty ? nil : parsed.text
        case .forget:
            return nil
        }
    }

    private var accessibilityLabel: String {
        if parsed.text.isEmpty {
            return headline
        }
        return "\(headline): \(parsed.text)"
    }

    /// VoiceOver hint describing what tapping the pill does. Without it,
    /// VO users hear "Saved to memory, button" with no signal that the
    /// row is expandable. Forget pills never reveal extra detail (the
    /// input JSON has no `text`), so the hint reflects that no-op.
    private var accessibilityHint: String {
        switch parsed.op {
        case .save, .update, .unknown:
            return isExpanded ? "Collapse details" : "Show details"
        case .forget:
            return ""
        }
    }
}

/// Two parameters extracted from the memory tool call's input JSON. Kept
/// as a dedicated value type so the parsing logic is shared between
/// `body` and the accessibility label, and so future descriptors that
/// add fields stay localized.
private struct ParsedMemoryCall: Equatable {
    enum Op: String, Equatable {
        case save, update, forget, unknown
    }

    let op: Op
    let text: String

    static func parse(_ raw: String) -> ParsedMemoryCall {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ParsedMemoryCall(op: .unknown, text: "")
        }
        let opRaw = (json["op"] as? String) ?? ""
        let op = Op(rawValue: opRaw) ?? .unknown
        let text = (json["text"] as? String) ?? ""
        return ParsedMemoryCall(op: op, text: text)
    }
}
