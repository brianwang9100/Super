import SwiftUI

struct MemoryUpdatedPill: View {
    let call: MessageList.ToolCallItem
    private let parsed: ParsedMemoryCall
    @State private var isExpanded: Bool
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    init(call: MessageList.ToolCallItem) {
        self.call = call
        self.parsed = ParsedMemoryCall.parse(call.parametersJSON)
        self._isExpanded = State(initialValue: false)
    }

    /// Snapshot seam for expanded state.
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

    /// Forget inputs contain only an ID, so there is no memory text to reveal.
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

    private var accessibilityHint: String {
        switch parsed.op {
        case .save, .update, .unknown:
            return isExpanded ? "Collapse details" : "Show details"
        case .forget:
            return ""
        }
    }
}

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
