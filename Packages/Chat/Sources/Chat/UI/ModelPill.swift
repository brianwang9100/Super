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
    @Environment(\.superTypography) private var typography

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
                            .font(typography.mono(11, relativeTo: .caption2))
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

/// Visual treatment for composer-footer pills. A frosted glass capsule with
/// soft ink and a trailing chevron — matches `footerPill` in `chat-view.jsx`,
/// brought onto the same Liquid Glass surface as the nav-bar pills.
struct FooterPillLabel: View {
    let text: String
    let theme: SuperTheme
    @Environment(\.superTypography) private var typography

    var body: some View {
        // The pill body uses `.caption2` (11pt at default DT) so the pill
        // scales with Dynamic Type. The chevron stays at a fixed point
        // size — it's decorative and would look broken at XXL.
        HStack(spacing: 4) {
            Text(text)
                .font(typography.font(.caption2))
                .foregroundStyle(theme.inkSoft)
            Image(systemName: "chevron.down")
                .font(typography.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Passive glass surface replaces the old hairline-stroked capsule.
        // Glass collapses the hit region to the glyph (see `SuperGlass`), and
        // the hosting `Menu` owns the tap — so re-assert the full capsule as
        // the contentShape, or the frosted padding goes dead to taps.
        .superGlassSurface(in: Capsule())
        .contentShape(Capsule())
    }
}
