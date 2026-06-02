import SwiftUI

/// Collapsible tool-call card: header with tool name + status, expanded
/// body with INPUT and RESULT panels in monospace. `.verbose` opens by
/// default; `.simple` and `.thinking` keep it collapsed behind the chip.
struct ToolCallBlock: View {
    let call: MessageList.ToolCallItem
    let verbosity: ChatVerbosity
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @State private var isExpanded: Bool

    init(call: MessageList.ToolCallItem, verbosity: ChatVerbosity) {
        self.call = call
        self.verbosity = verbosity
        self._isExpanded = State(initialValue: Self.shouldExpand(for: verbosity))
    }

    /// Tool blocks are heavyweight (parameters + result), so only the
    /// `.verbose` setting opens them by default. `.simple` and `.thinking`
    /// keep them collapsed behind the header pill.
    static func shouldExpand(for verbosity: ChatVerbosity) -> Bool {
        verbosity == .verbose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(typography.font(.caption))
                        .foregroundStyle(theme.inkSoft)
                    Text(call.toolName)
                        .font(typography.mono(12, relativeTo: .caption))
                        .foregroundStyle(theme.ink)
                    statusBadge
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(typography.font(.caption2, weight: .semibold))
                        .foregroundStyle(theme.inkFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("INPUT")
                    monospaceBlock(call.parametersJSON)
                    if let result = call.resultText {
                        sectionLabel("RESULT")
                        monospaceBlock(result)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderFaint, lineWidth: 1)
        )
        // Verbosity changes broadcast a new default expansion state to every
        // block. Individual taps after that still win until the next switch.
        .onChange(of: verbosity) { _, newValue in
            isExpanded = Self.shouldExpand(for: newValue)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("running")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
        case .awaitingConfirmation:
            // Generic tool path — the native-search proposal renders its own
            // approve/skip row (`SearchConfirmationRow`) and never reaches
            // here, but a future destructive tool parked for approval would.
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.inkFaint)
                Text("awaiting approval")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.inkFaint)
            }
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(typography.font(.caption2, weight: .bold))
                    .foregroundStyle(theme.accent)
                Text("done")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.accent)
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.errorAccent)
                Text("failed")
                    .font(typography.font(.caption2))
                    .foregroundStyle(theme.errorAccent)
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(typography.font(.caption2, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(theme.inkFaint)
    }

    @ViewBuilder
    private func monospaceBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(typography.mono(11, relativeTo: .caption2))
                .foregroundStyle(theme.inkSoft)
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background)
        )
    }
}
