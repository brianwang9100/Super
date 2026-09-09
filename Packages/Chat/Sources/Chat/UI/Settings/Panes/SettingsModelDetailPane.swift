import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum SettingsKeyboard {
    case text
    case url
    case numberPad
}

struct SettingsModelDetailPane: View {
    @Bindable var viewModel: SettingsViewModel
    let editingId: String?

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    @State private var providerID: String
    @State private var modelCatalogID: String
    @State private var name: String
    @State private var baseURLText: String
    @State private var modelId: String
    @State private var apiKey: String
    @State private var supportsThinking: Bool
    @State private var maxContextText: String
    @State private var searchBackend: String?
    @State private var showingDeleteConfirm: Bool = false
    /// Synthetic bullets mean an existing secret, never key material. Save passes an empty
    /// key while this flag is set so updateModel preserves the stored credential.
    @State private var apiKeyIsPlaceholder: Bool
    @State private var contextWindowError: String?
    @FocusState private var apiKeyFieldFocused: Bool

    // Fixed length avoids disclosing the stored key's length.
    private static let apiKeyPlaceholderDots = String(repeating: "•", count: 12)

    private let storedModelFallback: LLMCatalogModel?

    @State private var audioEnabled: Bool
    @State private var useThisKey: Bool
    @State private var audioRevision: Int
    @State private var committedModelId: String?
    @State private var isSavingModel = false
    @State private var formSession: Int?
    private var isModelBusy: Bool {
        isSavingModel || ((editingId ?? committedModelId).map { viewModel.isModelMutationInFlight(id: $0) } == true)
    }
    private var canSave: Bool { isValid && !isModelBusy }
    private var showsAudioSetup: Bool { providerID == "openai" && viewModel.audioSetup != nil && (keyHasContent || isEditing) }

    private var isEditing: Bool { editingId != nil }

    struct InitialSelection: Equatable, Sendable {
        let providerID: String

        init(providerID: String) {
            self.providerID = providerID
        }

        static let custom = InitialSelection(providerID: LLMProviderCatalog.customProviderID)
        static let apple = InitialSelection(providerID: LLMProviderCatalog.appleProviderID)
        static let openAI = InitialSelection(providerID: "openai")
        static let anthropic = InitialSelection(providerID: "anthropic")
        static let google = InitialSelection(providerID: "google")
        static let xai = InitialSelection(providerID: "xai")
    }

    init(
        viewModel: SettingsViewModel,
        editingId: String?,
        initialSelection: InitialSelection = .custom,
        initialContextWindowError: String? = nil,
        initialAPIKey: String? = nil
    ) {
        self.viewModel = viewModel
        self.editingId = editingId
        let audio = viewModel.audioSetup?.snapshot()
        _audioEnabled = State(initialValue: audio?.enabled ?? true)
        _useThisKey = State(initialValue: audio?.source == nil || audio?.source?.id == editingId)
        _audioRevision = State(initialValue: audio?.revision ?? 0)
        // Seed before rendering; onAppear is too late for the first frame and snapshots.
        let row = editingId.flatMap { viewModel.model(id: $0) }
        if let row {
            let resolved = Self.resolveEditProvider(
                kind: row.kind,
                modelId: row.modelId,
                baseURL: row.baseURL
            )
            let resolvedProviderID = row.providerId ?? resolved.providerID
            let resolvedCatalogID = resolved.catalogID
            _providerID = State(initialValue: resolvedProviderID)
            _modelCatalogID = State(initialValue: resolvedCatalogID)
            let fallback = Self.makeStoredModelFallback(
                resolvedProviderID: resolvedProviderID,
                modelId: row.modelId,
                maxContextTokens: row.maxContextTokens,
                supportsThinking: row.supportsThinking
            )
            storedModelFallback = fallback
            _name = State(initialValue: Self.editSeedName(
                rowName: row.name,
                resolvedProviderID: resolvedProviderID,
                resolvedCatalogID: resolvedCatalogID,
                storedFallback: fallback
            ))
            _baseURLText = State(initialValue: row.baseURL?.absoluteString ?? "")
            _modelId = State(initialValue: row.modelId)
            _supportsThinking = State(initialValue: row.supportsThinking)
            _maxContextText = State(initialValue: String(row.maxContextTokens))
            _searchBackend = State(initialValue: row.searchBackend)
            let seedDots = row.hasAPIKey
            _apiKey = State(initialValue: seedDots ? Self.apiKeyPlaceholderDots : "")
            _apiKeyIsPlaceholder = State(initialValue: seedDots)
        } else {
            let seeded = Self.makeCreateSeeds(providerID: initialSelection.providerID)
            storedModelFallback = nil
            _providerID = State(initialValue: seeded.providerID)
            _modelCatalogID = State(initialValue: seeded.modelCatalogID)
            _name = State(initialValue: seeded.name)
            _baseURLText = State(initialValue: seeded.baseURLText)
            _modelId = State(initialValue: seeded.modelId)
            _supportsThinking = State(initialValue: seeded.supportsThinking)
            _maxContextText = State(initialValue: seeded.maxContextText)
            _searchBackend = State(initialValue: nil)
            _apiKey = State(initialValue: initialAPIKey ?? "")
            _apiKeyIsPlaceholder = State(initialValue: false)
        }
        _contextWindowError = State(initialValue: initialContextWindowError)
        // AFM's read-only context window comes from the device, not a catalog or persisted value.
        if LLMProviderCatalog.entry(forID: _providerID.wrappedValue)?.kind == .appleFoundation {
            _maxContextText = State(initialValue: String(viewModel.appleFoundationContextTokens))
        }
    }

    private var currentProvider: LLMProviderCatalogEntry {
        LLMProviderCatalog.entry(forID: providerID)
            ?? LLMProviderCatalog.entry(forID: LLMProviderCatalog.customProviderID)
            ?? LLMProviderCatalogEntry(
                id: LLMProviderCatalog.customProviderID,
                displayName: "Custom",
                kind: .openAICompatible,
                defaultBaseURL: nil,
                models: []
            )
    }

    private var displayedModels: [LLMCatalogModel] {
        Self.displayedModels(
            fetched: viewModel.fetchedModels[providerID],
            catalog: currentProvider.models,
            storedFallback: storedModelFallback
        )
    }

    private var currentCatalogModel: LLMCatalogModel? {
        guard !isCustom, !modelCatalogID.isEmpty else { return nil }
        return displayedModels.first(where: { $0.id == modelCatalogID })
    }

    private var isApple: Bool {
        currentProvider.kind == .appleFoundation
    }

    private var isCustom: Bool {
        providerID == LLMProviderCatalog.customProviderID
    }

    private var isAppleProviderDisabled: Bool {
        !viewModel.appleFoundationAvailability.isAvailable
            || viewModel.hasAppleFoundationModel
    }

    private var showsBaseURLField: Bool { isCustom }
    private var showsNameField: Bool { isCustom }
    private var showsAPIKeyField: Bool { !isApple }
    private var showsModelIDField: Bool { isCustom }
    private var showsThinkingToggle: Bool {
        if let model = currentCatalogModel { return model.supportsThinking }
        return isCustom
    }
    private var showsModelDropdownInPickerSection: Bool { isApple }
    private var showsModelDropdownInForm: Bool { !isApple && !isCustom }

    // Match loadAvailableModels' whitespace gate so fields cannot unlock for an unusable key.
    private var keyHasContent: Bool {
        !apiKeyIsPlaceholder && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsGatedCreateFields: Bool {
        Self.showsGatedCreateFields(
            isEditing: isEditing,
            isApple: isApple,
            isCustom: isCustom,
            trimmedKeyEmpty: !keyHasContent
        )
    }

    nonisolated static func showsGatedCreateFields(
        isEditing: Bool,
        isApple: Bool,
        isCustom: Bool,
        trimmedKeyEmpty: Bool
    ) -> Bool {
        isEditing || isApple || isCustom || !trimmedKeyEmpty
    }

    private struct SearchBackendOption: Identifiable {
        let value: String?
        let label: String
        var id: String { value ?? "__off__" }
    }

    private var searchBackendOptions: [SearchBackendOption] {
        var options = [SearchBackendOption(value: nil, label: "Off")]
        if currentProvider.supportsNativeSearch {
            options.append(SearchBackendOption(value: "native", label: "Native (\(currentProvider.displayName))"))
        }
        #if DEBUG
        options.append(SearchBackendOption(value: "debug", label: "Debug (mock)"))
        #endif
        return options
    }

    private var searchBackendLabel: String {
        searchBackendOptions.first { $0.value == searchBackend }?.label ?? "Off"
    }

    private var showsSearchPicker: Bool {
        !isApple && searchBackendOptions.count > 1
    }

    /// Native selection uses the catalog endpoint. Custom URLs cannot select native search,
    /// so this branch has no user-entered URL to preserve.
    private func resolvedSearchSelection(
        compatBaseURL: URL
    ) -> (kind: LLMProviderKind, baseURL: URL, searchBackend: String?) {
        if searchBackend == "native",
           let adapter = currentProvider.nativeSearchAdapter,
           let nativeURL = currentProvider.nativeSearchBaseURL {
            return (adapter, nativeURL, "native")
        }
        let backend: String? = (searchBackend == "debug") ? "debug" : nil
        return (currentProvider.kind, compatBaseURL, backend)
    }

    private var editHeaderLabel: String? {
        Self.editHeaderLabel(
            isEditing: isEditing,
            isApple: isApple,
            isCustom: isCustom,
            providerName: currentProvider.displayName,
            modelName: currentCatalogModel?.displayName
        )
    }

    nonisolated static func editHeaderLabel(
        isEditing: Bool,
        isApple: Bool,
        isCustom: Bool,
        providerName: String,
        modelName: String?
    ) -> String? {
        guard isEditing, !isCustom else { return nil }
        if isApple {
            return modelName.map { "\(providerName) · \($0)" }
        }
        return providerName
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let maxCtx = Int(maxContextText), maxCtx > 0 else { return false }
        if isApple {
            return true
        }
        if !isCustom {
            if !isEditing, !keyHasContent { return false }
            // Validate catalog URLs too: a bad entry must not send credentials over remote cleartext.
            guard let url = currentProvider.defaultBaseURL,
                  isCleartextSafeForCredentials(url) else { return false }
            guard !modelCatalogID.isEmpty else { return false }
            return true
        }
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespaces)),
              isCleartextSafeForCredentials(url) else { return false }
        guard !modelId.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isEditing, !keyHasContent { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEditing {
                pickerSection
                    .padding(.top, 16)
            } else if let label = editHeaderLabel {
                editHeader(label)
                    .padding(.top, 16)
            }

            SettingsGroup {
                if showsNameField {
                    fieldRow(label: "Name", placeholder: customNamePlaceholder, text: $name)
                }
                if showsBaseURLField {
                    fieldRow(label: "Base URL", placeholder: "https://api.openai.com/v1", text: $baseURLText, keyboard: .url)
                }
                if showsModelIDField {
                    fieldRow(label: "Model ID", placeholder: "gpt-5.5", text: $modelId)
                }
                if showsAPIKeyField {
                    apiKeyFieldRow(borderBottom: showsGatedCreateFields)
                }
                if showsAudioSetup {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Text("Use OpenAI voices for narration")
                                .font(typography.font(.callout)).foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SettingsToggle(isOn: $audioEnabled, accessibilityLabel: "Use OpenAI voices for narration")
                        }
                        if let current = viewModel.audioSetup?.snapshot().source, current.id != editingId {
                            Text("Narration key: \(current.name)").font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
                            HStack(spacing: 14) {
                                Text("Use this key for narration")
                                    .font(typography.font(.callout)).foregroundStyle(theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                SettingsToggle(isOn: $useThisKey, accessibilityLabel: "Use this key for narration")
                            }
                        }
                        Text("Optional AI-generated narration. Text is sent to OpenAI when you play audio; API charges apply. Save confirms this choice.")
                            .font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
                    }.padding(16)
                }
                if showsGatedCreateFields {
                    if showsModelDropdownInForm {
                        modelPickerRow(borderBottom: true)
                    }
                    if isApple {
                        appleContextRow()
                    } else {
                        fieldRow(
                            label: "Max context",
                            placeholder: "200000",
                            text: $maxContextText,
                            keyboard: .numberPad,
                            borderBottom: showsThinkingToggle || showsSearchPicker,
                            monospaced: true
                        )
                        if let errorMessage = contextWindowError {
                            contextWindowErrorRow(errorMessage)
                        }
                    }
                    if showsThinkingToggle {
                        toggleRow(label: "Supports thinking", isOn: $supportsThinking, borderBottom: showsSearchPicker)
                    }
                    if showsSearchPicker {
                        searchBackendPickerRow(borderBottom: false)
                    }
                }
            }
            .padding(.top, 16)

            saveButton
                .padding(.horizontal, 16)
                .padding(.top, 18)

            if let errorMessage = viewModel.modelEditError {
                Text(errorMessage)
                    .font(typography.font(.footnote))
                    .foregroundStyle(theme.errorAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .accessibilityIdentifier("modelDetail.errorMessage")
            }

            if isEditing {
                deleteButton
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }

            Spacer(minLength: 24)
        }
        .padding(.bottom, 24)
        .onAppear {
            formSession = viewModel.beginModelFormSession()
            installPopScrub()
            viewModel.clearModelEditError()
            loadModelList(force: false)
        }
        .onChange(of: viewModel.fetchedModels[providerID]) { _, _ in
            // Check the displayed list, including the stored fallback, before clearing a removed live-only pick.
            guard !modelCatalogID.isEmpty else { return }
            if !displayedModels.contains(where: { $0.id == modelCatalogID }) {
                modelCatalogID = ""
            }
        }
        .task(id: apiKey) {
            // This task is the sole typed-key trigger; onSubmit would race the pending debounce.
            // Force refresh because the cache is keyed by provider, not credential.
            guard showsModelDropdownInForm, keyHasContent else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await viewModel.loadAvailableModels(providerID: providerID, apiKey: apiKey, force: true)
        }
        .onDisappear {
            if let formSession, viewModel.isModelFormSessionActive(formSession) {
                viewModel.beforePopCleanup = nil
                viewModel.endModelFormSession(formSession)
            }
        }
        .onChange(of: maxContextText) { _, _ in
            contextWindowError = nil
        }
        .confirmationDialog(
            "Delete this model endpoint?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard !isModelBusy, let editingId, let formSession,
                      viewModel.isModelFormSessionActive(formSession) else { return }
                isSavingModel = true
                Task {
                    defer { isSavingModel = false }
                    let deleted = await viewModel.deleteModel(id: editingId, formSession: formSession)
                    guard deleted, viewModel.isModelFormSessionActive(formSession) else { return }
                    apiKey = ""
                    viewModel.beforePopCleanup = nil
                    viewModel.popModelForm(ifCurrent: formSession)
                }
            }
            .disabled(isModelBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the endpoint and the API key from this device. Existing chats keep their transcripts.")
        }
    }

    @ViewBuilder
    private var pickerSection: some View {
        SettingsGroup {
            providerPickerRow(borderBottom: showsModelDropdownInPickerSection)
            if showsModelDropdownInPickerSection {
                modelPickerRow(borderBottom: false)
            }
        }
    }

    @ViewBuilder
    private func providerPickerRow(borderBottom: Bool) -> some View {
        pickerRow(label: "Provider", value: currentProvider.displayName, borderBottom: borderBottom) {
            ForEach(LLMProviderCatalog.all) { entry in
                let disabled = entry.id == LLMProviderCatalog.appleProviderID && isAppleProviderDisabled
                Button(action: { applyProviderSelection(entry.id) }) {
                    if disabled {
                        Label(entry.displayName, systemImage: "lock.fill")
                    } else {
                        Text(entry.displayName)
                    }
                }
                .disabled(disabled)
            }
        }
    }

    @ViewBuilder
    private func modelPickerRow(borderBottom: Bool) -> some View {
        let label = currentCatalogModel?.displayName ?? "Select model…"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(displayedModels) { model in
                        Button(action: { applyModelSelection(model.id) }) {
                            Text(model.displayName)
                        }
                    }
                } label: {
                    pickerLabelContent(label: "Model", value: label)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Model")
                .accessibilityValue(label)

                if !isApple {
                    modelRefreshAffordance
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if borderBottom {
                    Rectangle()
                        .fill(theme.borderFaint)
                        .frame(height: 1)
                        .padding(.leading, 18)
                }
            }

            if let note = viewModel.modelListNote[providerID] {
                Text(note)
                    .font(typography.font(.footnote))
                    .foregroundStyle(theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("modelDetail.modelListNote")
            }
        }
    }

    @ViewBuilder
    private var modelRefreshAffordance: some View {
        if viewModel.loadingModelsProviderID == providerID {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .accessibilityLabel("Loading models")
                .accessibilityIdentifier("modelDetail.modelsLoading")
        } else {
            Button(action: { loadModelList(force: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(typography.font(.footnote, weight: .semibold))
                    .foregroundStyle(theme.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh models")
            .accessibilityIdentifier("modelDetail.refreshModels")
        }
    }

    @ViewBuilder
    private func searchBackendPickerRow(borderBottom: Bool) -> some View {
        pickerRow(label: "Web search", value: searchBackendLabel, borderBottom: borderBottom) {
            ForEach(searchBackendOptions) { option in
                Button(action: { searchBackend = option.value }) {
                    Text(option.label)
                }
            }
        }
    }

    @ViewBuilder
    private func pickerRow<Content: View>(
        label: String,
        value: String,
        borderBottom: Bool,
        @ViewBuilder menuContent: () -> Content
    ) -> some View {
        Menu {
            menuContent()
        } label: {
            pickerLabelContent(label: label, value: value)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if borderBottom {
                        Rectangle()
                            .fill(theme.borderFaint)
                            .frame(height: 1)
                            .padding(.leading, 18)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    @ViewBuilder
    private func pickerLabelContent(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(typography.font(.caption, weight: .medium))
                    .foregroundStyle(theme.inkFaint)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(value)
                    .font(typography.font(.callout))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(typography.font(.footnote, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
        }
    }

    @ViewBuilder
    private func editHeader(_ text: String) -> some View {
        Text(text)
            .font(typography.font(.callout, weight: .medium))
            .foregroundStyle(theme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .accessibilityIdentifier("modelDetail.editHeader")
    }

    @ViewBuilder
    private func fieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: SettingsKeyboard = .text,
        isSecure: Bool = false,
        borderBottom: Bool = true,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(typography.font(.caption, weight: .medium))
                .foregroundStyle(theme.inkFaint)
                .textCase(.uppercase)
                .tracking(0.5)
            fieldEditor(placeholder: placeholder, text: text, isSecure: isSecure, keyboard: keyboard)
                .font(monospaced ? .system(.callout, design: .monospaced) : .system(.callout))
                .foregroundStyle(theme.ink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if borderBottom {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func appleContextRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Max context")
                .font(typography.font(.caption, weight: .medium))
                .foregroundStyle(theme.inkFaint)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(viewModel.appleFoundationContextTokens.formatted(.number))
                .font(typography.mono(16, relativeTo: .callout))
                .foregroundStyle(theme.ink)
            Text("Managed on-device by Apple Intelligence.")
                .font(typography.font(.caption))
                .foregroundStyle(theme.inkFaint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func apiKeyFieldRow(borderBottom: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(typography.font(.caption, weight: .medium))
                .foregroundStyle(theme.inkFaint)
                .textCase(.uppercase)
                .tracking(0.5)
            SecureField(isEditing ? "•••• (tap to change)" : "sk-…", text: $apiKey)
                // Offer password-manager AutoFill for the credential field.
                .textContentType(.password)
                .focused($apiKeyFieldFocused)
                .font(typography.font(.callout))
                .foregroundStyle(theme.ink)
                .onChange(of: apiKeyFieldFocused) { _, focused in
                    if focused, apiKeyIsPlaceholder {
                        apiKey = ""
                        apiKeyIsPlaceholder = false
                    }
                }
                .onChange(of: apiKey) { _, newValue in
                    // Paste and programmatic edits may bypass focus-based placeholder clearing.
                    if apiKeyIsPlaceholder, newValue != Self.apiKeyPlaceholderDots {
                        apiKeyIsPlaceholder = false
                    }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if borderBottom {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool,
        keyboard: SettingsKeyboard
    ) -> some View {
        if isSecure {
            SecureField(placeholder, text: text)
        } else {
            #if canImport(UIKit)
            TextField(placeholder, text: text)
                .keyboardType(uiKeyboard(for: keyboard))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            #else
            TextField(placeholder, text: text)
                .autocorrectionDisabled(true)
            #endif
        }
    }

    #if canImport(UIKit)
    private func uiKeyboard(for hint: SettingsKeyboard) -> UIKeyboardType {
        switch hint {
        case .text: return .default
        case .url: return .URL
        case .numberPad: return .numberPad
        }
    }
    #endif

    @ViewBuilder
    private func toggleRow(
        label: String,
        isOn: Binding<Bool>,
        borderBottom: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(typography.font(.callout))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsToggle(isOn: isOn, accessibilityLabel: label)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if borderBottom {
                Rectangle()
                    .fill(theme.borderFaint)
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func contextWindowErrorRow(_ message: String) -> some View {
        Text(message)
            .font(typography.font(.footnote))
            .foregroundStyle(theme.errorAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .accessibilityIdentifier("modelDetail.contextWindowError")
    }

    private var saveButton: some View {
        Button(action: save) {
            Text(isEditing ? "Save" : "Add Model")
                .font(typography.font(.body, weight: .semibold))
                .foregroundStyle(canSave ? theme.background : theme.inkFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canSave ? theme.accent : theme.backgroundRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.borderFaint, lineWidth: canSave ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    private var deleteButton: some View {
        Button(action: { if !isModelBusy { showingDeleteConfirm = true } }) {
            Text("Delete model endpoint")
                .font(typography.font(.callout, weight: .medium))
                .foregroundStyle(isModelBusy ? theme.inkFaint : theme.errorAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.backgroundRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.borderFaint, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isModelBusy)
        .accessibilityHint("Removes this model endpoint and its stored API key.")
    }

    /// Scrub drafts before UIKit tears down the field, preventing Save Password for discarded keys.
    /// Successful saves disarm the hook; untouched placeholder bullets still require scrubbing.
    private func installPopScrub() {
        let apiKeyBinding = $apiKey
        viewModel.beforePopCleanup = {
            apiKeyBinding.wrappedValue = ""
        }
    }

    private func applyProviderSelection(_ id: String) {
        if id == LLMProviderCatalog.appleProviderID, isAppleProviderDisabled { return }
        guard id != providerID else { return }
        let seeded = Self.makeCreateSeeds(providerID: id)
        providerID = seeded.providerID
        modelCatalogID = seeded.modelCatalogID
        name = seeded.name
        baseURLText = seeded.baseURLText
        modelId = seeded.modelId
        maxContextText = seeded.maxContextText
        if seeded.providerID == LLMProviderCatalog.appleProviderID {
            maxContextText = String(viewModel.appleFoundationContextTokens)
        }
        supportsThinking = seeded.supportsThinking
        // Native search availability belongs to the provider, so reset it on provider changes.
        searchBackend = nil
        apiKey = ""
        apiKeyIsPlaceholder = false
        contextWindowError = nil
        loadModelList(force: false)
    }

    /// Use the stored Keychain key while placeholder bullets are visible; never send the bullets.
    private func loadModelList(force: Bool) {
        guard !isCustom, !isApple else { return }
        let providerID = providerID
        if isEditing, !keyHasContent, let editingId {
            Task {
                await viewModel.loadAvailableModelsUsingStoredKey(
                    providerID: providerID,
                    editingModelID: editingId,
                    force: force
                )
            }
        } else {
            let apiKey = apiKey
            Task { await viewModel.loadAvailableModels(providerID: providerID, apiKey: apiKey, force: force) }
        }
    }

    private func applyModelSelection(_ catalogID: String) {
        guard let entry = displayedModels.first(where: { $0.id == catalogID }) else { return }
        guard catalogID != modelCatalogID else { return }
        modelCatalogID = catalogID
        name = entry.displayName
        modelId = entry.id
        maxContextText = String(entry.maxContextTokens)
        supportsThinking = entry.supportsThinking
        contextWindowError = nil
    }

    /// Resolve AFM and native adapters by kind before URL matching: native and compat endpoints can match.
    /// For compat rows, require both model ID and URL so editing a proxy cannot replace its endpoint.
    /// Preserve off-catalog native wire IDs through the stored-model fallback.
    nonisolated static func resolveEditProvider(
        kind: LLMProviderKind,
        modelId: String,
        baseURL: URL?
    ) -> (providerID: String, catalogID: String) {
        if kind == .appleFoundation {
            let catalogID = LLMProviderCatalog.entry(forID: LLMProviderCatalog.appleProviderID)?
                .models.first?.id ?? modelId
            return (LLMProviderCatalog.appleProviderID, catalogID)
        }
        switch kind {
        case .anthropicNative, .geminiNative, .openAIResponses:
            for entry in LLMProviderCatalog.all where entry.nativeSearchAdapter == kind {
                for model in entry.models where model.id == modelId {
                    return (entry.id, model.id)
                }
                return (entry.id, modelId)
            }
            return (LLMProviderCatalog.customProviderID, "")
        case .openAICompatible, .appleFoundation:
            break
        #if DEBUG
        case .debug:
            break
        #endif
        }
        if let match = LLMProviderCatalog.model(forModelId: modelId),
           Self.urlsMatchIgnoringTrailingSlash(match.provider.defaultBaseURL, baseURL) {
            return (match.provider.id, match.model.id)
        }
        return (LLMProviderCatalog.customProviderID, "")
    }

    /// Repair blank built-in names because their hidden Name field gives the user no way to unblock Save.
    /// Custom names remain editable.
    nonisolated static func editSeedName(
        rowName: String,
        resolvedProviderID: String,
        resolvedCatalogID: String,
        storedFallback: LLMCatalogModel?
    ) -> String {
        guard rowName.trimmingCharacters(in: .whitespaces).isEmpty else { return rowName }
        if let entry = LLMProviderCatalog.entry(forID: resolvedProviderID),
           let model = entry.models.first(where: { $0.id == resolvedCatalogID }) {
            return model.displayName
        }
        return storedFallback?.displayName ?? rowName
    }

    /// Preserve a stored context cap above the synthetic catalog default so valid existing rows stay savable.
    nonisolated static func makeStoredModelFallback(
        resolvedProviderID: String,
        modelId: String,
        maxContextTokens: Int,
        supportsThinking: Bool
    ) -> LLMCatalogModel? {
        guard !modelId.isEmpty,
              resolvedProviderID != LLMProviderCatalog.customProviderID,
              resolvedProviderID != LLMProviderCatalog.appleProviderID
        else { return nil }
        if let curated = LLMProviderCatalog.entry(forID: resolvedProviderID)?
            .models.first(where: { $0.id == modelId }) {
            return curated
        }
        return LLMCatalogModel(
            id: modelId,
            displayName: modelId,
            maxContextTokens: max(maxContextTokens, LLMProviderCatalog.defaultFetchedMaxContextTokens),
            supportsThinking: supportsThinking
        )
    }

    /// Include the stored model and replace synthetic live metadata with its authoritative values;
    /// otherwise an unknown live ID could shrink the cap or hide thinking on an untouched row.
    nonisolated static func displayedModels(
        fetched: [LLMCatalogModel]?,
        catalog: [LLMCatalogModel],
        storedFallback: LLMCatalogModel?
    ) -> [LLMCatalogModel] {
        let base = fetched ?? catalog
        guard let storedFallback else { return base }
        guard let index = base.firstIndex(where: { $0.id == storedFallback.id }) else {
            return base + [storedFallback]
        }
        var replaced = base
        replaced[index] = storedFallback
        return replaced
    }

    nonisolated static func urlsMatchIgnoringTrailingSlash(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (l?, r?):
            return Self.urlNormalized(l) == Self.urlNormalized(r)
        }
    }

    nonisolated static func urlNormalized(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    nonisolated static func makeCreateSeeds(providerID: String) -> CreateSeeds {
        let entry = LLMProviderCatalog.entry(forID: providerID)
            ?? LLMProviderCatalog.entry(forID: LLMProviderCatalog.customProviderID)
            ?? LLMProviderCatalogEntry(
                id: LLMProviderCatalog.customProviderID,
                displayName: "Custom",
                kind: .openAICompatible,
                defaultBaseURL: nil,
                models: []
            )
        let firstModel = entry.models.first
        if entry.id == LLMProviderCatalog.customProviderID {
            return CreateSeeds(
                providerID: entry.id,
                modelCatalogID: "",
                name: "",
                baseURLText: "https://api.openai.com/v1",
                modelId: "",
                maxContextText: "200000",
                supportsThinking: true
            )
        }
        // An empty built-in catalog would silently leave Save disabled; fail at the catalog boundary.
        guard let firstModel else {
            preconditionFailure("LLMProviderCatalog entry '\(entry.id)' has no models")
        }
        return CreateSeeds(
            providerID: entry.id,
            modelCatalogID: firstModel.id,
            name: firstModel.displayName,
            baseURLText: entry.defaultBaseURL?.absoluteString ?? "",
            modelId: firstModel.id,
            maxContextText: String(firstModel.maxContextTokens),
            supportsThinking: firstModel.supportsThinking
        )
    }

    struct CreateSeeds: Equatable, Sendable {
        let providerID: String
        let modelCatalogID: String
        let name: String
        let baseURLText: String
        let modelId: String
        let maxContextText: String
        let supportsThinking: Bool
    }

    private var customNamePlaceholder: String { "GPT 5.5" }

    private func save() {
        guard isValid, !isModelBusy, let formSession,
              viewModel.isModelFormSessionActive(formSession) else { return }
        guard let maxCtx = Int(maxContextText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Check the cap on Save so it can surface inline. Exempt AFM's device-managed window
        // from static catalog caps that could reject a valid live value.
        if !isApple, let cap = currentCatalogModel?.maxContextTokens, maxCtx > cap {
            contextWindowError = "Maximum context for this model is \(cap.formatted(.number)) tokens."
            return
        } else {
            contextWindowError = nil
        }
        if isApple {
            viewModel.beforePopCleanup = nil
            isSavingModel = true
            if let editingId {
                Task {
                    defer { isSavingModel = false }
                    let saved = await viewModel.updateModel(
                        id: editingId,
                        name: trimmedName,
                        baseURL: nil,
                        modelId: modelId,
                        apiKey: "",
                        supportsThinking: supportsThinking,
                        maxContextTokens: viewModel.appleFoundationContextTokens,
                        formSession: formSession
                    )
                    if saved != nil {
                        viewModel.popModelForm(ifCurrent: formSession)
                    }
                }
            } else {
                Task {
                    defer { isSavingModel = false }
                    let saved = await viewModel.createAppleFoundationModel(
                        name: trimmedName,
                        supportsThinking: supportsThinking,
                        maxContextTokens: viewModel.appleFoundationContextTokens,
                        formSession: formSession
                    )
                    if saved != nil {
                        viewModel.popModelForm(ifCurrent: formSession)
                    }
                }
            }
            return
        }
        let resolvedURL: URL?
        if isCustom {
            resolvedURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        } else {
            resolvedURL = currentProvider.defaultBaseURL
        }
        guard let url = resolvedURL else { return }
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespaces)
        // Allow password saving only for real entered keys. Keep placeholder scrubbing armed.
        if !apiKeyIsPlaceholder {
            viewModel.beforePopCleanup = nil
        }
        let keyForSave = apiKeyIsPlaceholder ? "" : apiKey
        let resolved = resolvedSearchSelection(compatBaseURL: url)
        let updateSelection: (kind: LLMProviderKind, searchBackend: String?)? =
            showsSearchPicker ? (kind: resolved.kind, searchBackend: resolved.searchBackend) : nil
        isSavingModel = true
        Task {
            defer { isSavingModel = false }
            let saved: ModelConfigurationRecord?
            if let editingId = editingId ?? committedModelId {
                saved = await viewModel.updateModel(
                    id: editingId,
                    name: trimmedName,
                    baseURL: resolved.baseURL,
                    modelId: trimmedModelId,
                    apiKey: keyForSave,
                    supportsThinking: supportsThinking,
                    maxContextTokens: maxCtx,
                    searchSelection: updateSelection,
                    providerId: providerID,
                    formSession: formSession
                )
            } else {
                saved = await viewModel.createModel(
                    name: trimmedName,
                    baseURL: resolved.baseURL,
                    modelId: trimmedModelId,
                    apiKey: keyForSave,
                    supportsThinking: supportsThinking,
                    maxContextTokens: maxCtx,
                    kind: resolved.kind,
                    searchBackend: resolved.searchBackend,
                    providerId: providerID,
                    formSession: formSession
                )
            }
            guard viewModel.isModelFormSessionActive(formSession) else { return }
            guard let saved else { installPopScrub(); return }
            committedModelId = saved.id
            var audioSaved = true
            if showsAudioSetup {
                audioSaved = await viewModel.commitModelFormAudioSetup(
                    for: saved, enabled: audioEnabled, useThisKey: useThisKey, revision: audioRevision, session: formSession
                )
                guard viewModel.isModelFormSessionActive(formSession) else { return }
                audioRevision = viewModel.audioSetup?.snapshot().revision ?? audioRevision
            }
            // A failed save stays open; re-arm scrubbing for a later Back action.
            if audioSaved {
                viewModel.popModelForm(ifCurrent: formSession)
            } else {
                installPopScrub()
            }
        }
    }
}
