import Core
import SwiftUI

public struct ModelPill: View {
    /// id is ModelConfigurationRecord.id, not the shared upstream model ID.
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

struct FooterPillLabel: View {
    let text: String
    let theme: SuperTheme
    @Environment(\.superTypography) private var typography

    var body: some View {
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
        // Restore the capsule hit target after passive glass; otherwise its padding stops receiving Menu taps.
        .superGlassSurface(in: Capsule())
        .contentShape(Capsule())
    }
}
