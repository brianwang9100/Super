import Core
import SwiftUI

/// Models pane. Mirrors `ModelsPane` from `settings.jsx`: each configured
/// model renders as a 14pt-padded card with a 36×36 monogram tile, name +
/// metadata stack, and a trailing custom switch. Below the list is a
/// dashed-border "Add model endpoint" CTA.
///
/// Card body taps push the edit pane; the trailing toggle handles its
/// own tap so it doesn't collide with the row push.
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
        .task { await viewModel.refreshAppleFoundationStatuses() }
    }

    /// All-caps section label matching the title-summarization footer's
    /// "CHAT TITLES" header. Aligned to the same 20pt leading inset.
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
            // Card body: tap pushes the edit pane. Wrapping just the body
            // (not the toggle) in a Button keeps the toggle's tap region
            // independent so flipping the switch doesn't also navigate.
            Button(action: { viewModel.openPane(.modelDetail(id: model.id)) }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accentSoft)
                        Text(model.monogram.uppercased())
                            // Fixed 36×36 tile: the monogram must not scale on
                            // either axis or it overflows. relativeTo: nil drops
                            // OS Dynamic Type; tracksFontScale: false drops the
                            // app font-scale slider (relativeTo: nil alone left
                            // the slider folding in, which still overflowed).
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
                            // Apple rows include processing location and a
                            // readiness reason; neither may disappear in an ellipsis.
                            .lineLimit(model.kind == .appleFoundation ? nil : 1)
                            .fixedSize(horizontal: false, vertical: model.kind == .appleFoundation)
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
                        // Defense-in-depth: the outer `.disabled(!isAvailable)`
                        // already gates the button tap, but a no-op set here
                        // means even an accessibility-side write to this
                        // Binding cannot flip the row to a state the user
                        // can't toggle back from once AFM becomes available.
                        guard isAvailable else { return }
                        Task { await viewModel.setModelEnabled(id: model.id, enabled: newValue) }
                    }
                ),
                accessibilityLabel: model.name
            )
            .disabled(!isAvailable)
        }
        .padding(14)
        // Passive glass card — the row hosts two independent tap targets (the
        // body button and the trailing toggle), so `superGlassSurface` (which
        // doesn't claim a hit region) keeps both live. Glass supplies its own
        // edge and elevation, so the old raised fill + faint stroke are gone.
        .superGlassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Whether the row is usable right now. `.openAICompatible` rows are
    /// always usable from the UI's perspective — wire-level errors
    /// surface as runtime banners, not toggle gating. `.appleFoundation`
    /// rows require their own readiness, quota, and resolved metadata.
    private func isModelAvailable(_ model: SettingsViewModel.ModelRow) -> Bool {
        switch model.kind {
        case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
            // Remote rows (compat shim or a native-search adapter) are
            // always usable from the UI's perspective; wire-level errors
            // surface as runtime banners, not toggle gating.
            return true
        case .appleFoundation:
            guard let variant = AppleFoundationModel(rawValue: model.modelId) else { return false }
            return viewModel.appleFoundationStatus(for: variant).canGenerate
        #if DEBUG
        case .debug:
            return true
        #endif
        }
    }

    /// `.openAICompatible` rows show context + endpoint (the existing
    /// monospaced "4K ctx · api.openai.com" line). `.appleFoundation`
    /// rows retain visible local/cloud identity even when a custom name is used,
    /// followed by measured context or an actionable status.
    private func subtitle(for model: SettingsViewModel.ModelRow) -> String {
        switch model.kind {
        case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
            return "\(model.maxContextTokens / 1000)K ctx · \(model.endpoint)"
        case .appleFoundation:
            guard let variant = AppleFoundationModel(rawValue: model.modelId) else { return "Unsupported Apple model" }
            let location = variant == .local ? "Local only · on-device" : "PCC · Apple cloud"
            if let message = viewModel.appleFoundationStatusMessage(for: variant) { return "\(location) · \(message)" }
            if let context = viewModel.appleFoundationStatus(for: variant).contextTokens {
                return "\(context / 1000)K ctx · \(location)"
            }
            return location
        #if DEBUG
        case .debug:
            return "\(model.maxContextTokens / 1000)K ctx · canned responses"
        #endif
        }
    }

    /// Footer: which model — if any — summarizes new chat titles, a knob
    /// independent of the conversation's active model. The toggle is the
    /// master on/off; when on, the radio list picks the summarizer from the
    /// configured models. Local Apple Intelligence is the automatic default
    /// (highlighted when the user hasn't made an explicit pick) and is shown
    /// disabled when it's unavailable on this device. When off — or when the
    /// resolved model is unavailable — titles fall back to the first message.
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
            Text("Automatic titles use Local only when configured; otherwise they use the first message. Choosing PCC here uses cloud processing and its daily quota.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 20)
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

    /// One radio row in the summarizer-model list. `nil` `titleModelId`
    /// (automatic) highlights only the local Apple row; an explicit id
    /// highlights its exact model. Unavailable rows are dimmed and non-selectable.
    private func titleModelRow(_ model: SettingsViewModel.ModelRow, isLast: Bool) -> some View {
        let isAvailable = isModelAvailable(model)
        let isSelected = isTitleModelSelected(model)
        return Button(action: {
            Task { await viewModel.setTitleModelId(model.id) }
        }) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(typography.font(.subheadline))
                    if let location = Self.appleModelLocation(kind: model.kind, modelID: model.modelId) {
                        Text(location)
                            .font(typography.font(.caption))
                    }
                }
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
            // Soft accent band marks the picked summarizer, matching how the
            // due-date / priority chips show selection — a clearer "picked"
            // state than the lone checkmark, and legible across all themes.
            // (A grouped radio row inside a solid card, so a neutral glass
            // lift would read near-invisible here; the accent tint carries it.)
            .background(isSelected ? theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !isLast { titleDivider }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(Self.titleModelAccessibilityLabel(
            name: model.name, kind: model.kind, modelID: model.modelId
        ))
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    /// Processing location remains visible even when a saved Apple model has a custom name.
    nonisolated static func appleModelLocation(kind: LLMProviderKind, modelID: String) -> String? {
        guard kind == .appleFoundation else { return nil }
        switch AppleFoundationModel(rawValue: modelID) {
        case .local: return "Local only · on-device"
        case .privateCloudCompute: return "PCC · Apple cloud"
        case .none: return "Unsupported Apple model"
        }
    }

    /// VoiceOver gets the same local/cloud disclosure as the visible title-model row.
    nonisolated static func titleModelAccessibilityLabel(name: String, kind: LLMProviderKind, modelID: String) -> String {
        guard let location = appleModelLocation(kind: kind, modelID: modelID) else { return name }
        return "\(name), \(location)"
    }

    private var titleDivider: some View {
        Rectangle()
            .fill(theme.borderFaint)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    /// Whether `model` is the current title summarizer. An explicit
    /// `titleModelId` matches by the row's unique **record id** (`model.id`,
    /// not `modelId` — two rows can share a `modelId`, which would light both
    /// up); the automatic default (`nil`) highlights the local Apple row only.
    private func isTitleModelSelected(_ model: SettingsViewModel.ModelRow) -> Bool {
        guard let id = viewModel.settings.titleModelId else {
            // Automatic titles never inherit the PCC chat default.
            return model.kind == .appleFoundation && model.modelId == AppleFoundationModel.local.rawValue
        }
        // Resolve to a single record id so exactly one row checks — including a
        // legacy persisted `LLMModel.id`, matching `TitleGenerator`'s
        // back-compat. A stored id that resolves to nothing (deleted model)
        // checks no row (and does not fall back to AFM).
        return model.id == Self.resolvedTitleRecordID(titleModelId: id, in: viewModel.models)
    }

    /// Map a stored title id to the record id that should be checked: the row
    /// whose record id equals it, else the first row whose `modelId` equals it
    /// (legacy `LLMModel.id` back-compat — keeps the checkmark in step with
    /// `TitleGenerator.resolveTitleModel`), else `nil` (deleted model → no
    /// check). For-loops rather than `first(where:)` per the in-tree
    /// `@MainActor` predicate-closure caveat.
    static func resolvedTitleRecordID(
        titleModelId id: String,
        in models: [SettingsViewModel.ModelRow]
    ) -> String? {
        for model in models where model.id == id { return id }
        for model in models where model.modelId == id { return model.id }
        return nil
    }
}
