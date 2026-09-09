import SwiftUI

struct SettingsModelsPane: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader("ALL MODELS")
                .padding(.bottom, 8)

            ForEach(viewModel.models) { model in
                modelCard(model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            titleSummarizationSection
                .padding(.top, 12)
                .padding(.bottom, 12)
        }
        .padding(.top, 8)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(typography.font(.caption2, weight: .semibold))
            .foregroundStyle(theme.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private func modelCard(_ model: SettingsViewModel.ModelRow) -> some View {
        let isAvailable = isModelAvailable(model)
        return HStack(spacing: 10) {
            // Keep the toggle outside the navigation button so changing enablement cannot push a pane.
            Button(action: { viewModel.openPane(.modelDetail(id: model.id)) }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accentSoft)
                        Text(model.monogram.uppercased())
                            // Fixed badge: disable both Dynamic Type and app font scaling to prevent overflow.
                            .font(typography.mono(13, relativeTo: nil, weight: .semibold, tracksFontScale: false))
                            .foregroundStyle(theme.accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(typography.font(.subheadline, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Text(subtitle(for: model))
                            .font(typography.mono(12, relativeTo: .caption))
                            .foregroundStyle(isAvailable ? theme.inkFaint : theme.errorInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit model")

            SettingsToggle(
                isOn: Binding(
                    get: { model.isEnabled && isAvailable },
                    set: { newValue in
                        // Gate binding writes too; accessibility must not enable an unavailable row.
                        guard isAvailable else { return }
                        Task { await viewModel.setModelEnabled(id: model.id, enabled: newValue) }
                    }
                ),
                accessibilityLabel: model.name
            )
            .disabled(!isAvailable)
        }
        .padding(14)
        // Passive glass preserves the independent body button and toggle hit targets.
        .superGlassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func isModelAvailable(_ model: SettingsViewModel.ModelRow) -> Bool {
        switch model.kind {
        case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
            // Remote errors surface during requests; only local AFM availability gates the toggle.
            return true
        case .appleFoundation:
            return viewModel.appleFoundationAvailability.isAvailable
        #if DEBUG
        case .debug:
            return true
        #endif
        }
    }

    private func subtitle(for model: SettingsViewModel.ModelRow) -> String {
        switch model.kind {
        case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
            return "\(model.maxContextTokens / 1000)K ctx · \(model.endpoint)"
        case .appleFoundation:
            switch viewModel.appleFoundationAvailability {
            case .available:
                return "\(model.maxContextTokens / 1000)K ctx · on-device"
            case .unavailable(let reason):
                return reason.subtitle
            }
        #if DEBUG
        case .debug:
            return "\(model.maxContextTokens / 1000)K ctx · canned responses"
        #endif
        }
    }

    private var titleSummarizationSection: some View {
        let isOn = viewModel.settings.summarizeTitlesEnabled
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CHAT TITLES")

            SettingsGroup {
                titleToggleRow(showsDivider: isOn && !viewModel.models.isEmpty)
                if isOn {
                    ForEach(Array(viewModel.models.enumerated()), id: \.element.id) { index, model in
                        titleModelRow(model, isLast: index == viewModel.models.count - 1)
                    }
                }
            }
        }
    }

    private func titleToggleRow(showsDivider: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summarize chat titles")
                    .font(typography.font(.subheadline))
                    .foregroundStyle(theme.ink)
                Text("Name new chats with a short AI summary. Off uses the first message.")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsToggle(
                isOn: Binding(
                    get: { viewModel.settings.summarizeTitlesEnabled },
                    set: { newValue in Task { await viewModel.setSummarizeTitlesEnabled(newValue) } }
                ),
                accessibilityLabel: "Summarize chat titles"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if showsDivider { titleDivider }
        }
    }

    private func titleModelRow(_ model: SettingsViewModel.ModelRow, isLast: Bool) -> some View {
        let isAvailable = isModelAvailable(model)
        let isSelected = isTitleModelSelected(model)
        return Button(action: {
            Task { await viewModel.setTitleModelId(model.id) }
        }) {
            HStack(spacing: 14) {
                Text(model.name)
                    .font(typography.font(.subheadline))
                    .foregroundStyle(isAvailable ? theme.ink : theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    CheckIcon(size: 16)
                        .foregroundStyle(isAvailable ? theme.accent : theme.inkFaint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(isSelected ? theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !isLast { titleDivider }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(model.name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var titleDivider: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private func isTitleModelSelected(_ model: SettingsViewModel.ModelRow) -> Bool {
        guard let id = viewModel.settings.titleModelId else {
            return model.kind == .appleFoundation
        }
        return model.id == Self.resolvedTitleRecordID(titleModelId: id, in: viewModel.models)
    }

    /// Resolve record ID first, then a legacy upstream model ID, matching TitleGenerator.
    /// Use loops to avoid MainActor predicate-closure inference issues.
    static func resolvedTitleRecordID(
        titleModelId id: String,
        in models: [SettingsViewModel.ModelRow]
    ) -> String? {
        for model in models where model.id == id { return id }
        for model in models where model.modelId == id { return model.id }
        return nil
    }

}
