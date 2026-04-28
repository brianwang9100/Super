import Core
import SwiftUI

/// Composer footer pill that opens a Menu of available models. Reflects the
/// active model id; emits the new id via `onSelect`.
///
/// Mirrors `ModelPill` in `.design-tmp/chat/project/src/chat-view.jsx`.
/// Native `Menu` replaces the React popover so users get the system's
/// affordances (haptic, accessibility) for free.
public struct ModelPill: View {
    /// One row in the dropdown. Ids match `LLMModel.id`.
    public struct Option: Identifiable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let maxContextTokens: Int

        public init(id: String, displayName: String, maxContextTokens: Int) {
            self.id = id
            self.displayName = displayName
            self.maxContextTokens = maxContextTokens
        }
    }

    public let options: [Option]
    public let selectedId: String?
    public let onSelect: (String) -> Void
    /// Tapped when the user picks the trailing "Manage models…" entry.
    /// The host opens the Settings sheet routed to the Models pane so
    /// the user can add a new endpoint without leaving the composer.
    public let onManageModels: () -> Void

    public init(
        options: [Option],
        selectedId: String?,
        onSelect: @escaping (String) -> Void,
        onManageModels: @escaping () -> Void = {}
    ) {
        self.options = options
        self.selectedId = selectedId
        self.onSelect = onSelect
        self.onManageModels = onManageModels
    }

    @Environment(\.superTheme) private var theme

    private var current: Option? {
        if let selectedId, let match = options.first(where: { $0.id == selectedId }) {
            return match
        }
        return options.first
    }

    public var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    HStack {
                        Text(option.displayName)
                        Spacer()
                        Text("\(option.maxContextTokens / 1000)K")
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            // Sectioned divider keeps the management entry visually separate
            // from the model picks, so a careless tap doesn't switch models.
            Divider()
            Button {
                onManageModels()
            } label: {
                Label("Manage models…", systemImage: "slider.horizontal.3")
            }
        } label: {
            FooterPillLabel(
                text: current?.displayName ?? "No model",
                theme: theme
            )
        }
        .menuStyle(.borderlessButton)
        .menuOrder(.fixed)
    }
}

/// Visual treatment shared by `ModelPill` and `VerbosityPill`. A capsule
/// with a faint border, soft ink, and a trailing chevron — matches
/// `footerPill` in `chat-view.jsx`.
struct FooterPillLabel: View {
    let text: String
    let theme: SuperTheme

    var body: some View {
        // The pill body uses `.caption2` (11pt at default DT) so the pill
        // scales with Dynamic Type. The chevron stays at a fixed point
        // size — it's decorative and would look broken at XXL.
        HStack(spacing: 4) {
            Text(text)
                .font(.system(.caption2))
                .foregroundStyle(theme.inkSoft)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().stroke(theme.borderFaint, lineWidth: 1)
        )
        .contentShape(Capsule())
    }
}
