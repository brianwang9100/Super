import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Field-specific keyboard type. Maps to UIKit's `UIKeyboardType` on iOS;
/// the macOS build ignores it. Defining a small wrapper keeps the
/// detail-pane signature platform-agnostic so the file compiles on both.
enum SettingsKeyboard {
    case text
    case url
    case numberPad
}

/// Create / edit form for a single LLM (Large Language Model) endpoint.
///
/// Create mode renders two stacked dropdowns — Provider and Model —
/// backed by `LLMProviderCatalog`. Picking a built-in provider auto-fills
/// the row's name, base URL, model id, max-context, and thinking flag
/// from the catalog and hides those fields. Custom exposes every field
/// for hand entry. AFM (Apple Foundation Model) hides URL/key/model-id
/// because the on-device kind has none of those.
///
/// Edit mode hides the dropdowns (the row's identity is locked once
/// persisted) and renders a "Provider · Model" header instead, when the
/// stored config maps to a known catalog entry. Validation is local:
/// Save stays disabled until the visible required fields have legal
/// values. The Context Window cap is checked post-Save-tap and surfaces
/// as an inline error so the user keeps control of the typed value.
struct SettingsModelDetailPane: View {
    @Bindable var viewModel: SettingsViewModel
    /// `nil` ⇒ create. Non-nil ⇒ id of the row to edit.
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
    @State private var showingDeleteConfirm: Bool = false
    /// `true` while `apiKey` holds the synthetic bullets we seeded to
    /// signal "a key is stored" — flips to `false` the first time the
    /// field gains focus (clearing the bullets) or the user mutates the
    /// text any other way (e.g. paste). When `true`, `save()` passes
    /// `""` for apiKey so the existing "blank ⇒ don't rotate" contract
    /// in `SettingsViewModel.updateModel` preserves the stored key.
    @State private var apiKeyIsPlaceholder: Bool
    /// Inline error shown beneath the Context Window field when the
    /// user tapped Save with a value above the selected model's
    /// catalog cap. Cleared when the value changes or another Save tap
    /// succeeds. Custom configs (no catalog model) never set this.
    @State private var contextWindowError: String?
    @FocusState private var apiKeyFieldFocused: Bool

    /// Fixed number of bullets used as the synthetic stand-in for an
    /// existing key. Length is intentionally fixed rather than matching
    /// the real key length — leaking key length is a small information
    /// disclosure we have no reason to invite.
    private static let apiKeyPlaceholderDots = String(repeating: "•", count: 12)

    private var isEditing: Bool { editingId != nil }

    /// Initial selection used by snapshot tests to pin a starting
    /// provider in the create flow. Production callers default to
    /// Custom. The convenience statics line up with the providers in
    /// `LLMProviderCatalog.all` so a test reads as `.google` rather
    /// than `InitialSelection(providerID: "google")`.
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
        initialContextWindowError: String? = nil
    ) {
        self.viewModel = viewModel
        self.editingId = editingId
        // Seed @State at init time so the first render shows live data.
        // Doing this in `.onAppear` made the snapshot capture pre-seed
        // values for the toggle (the lifecycle hook hadn't fired yet).
        let row = editingId.flatMap { viewModel.model(id: $0) }
        if let row {
            // Edit mode: derive the original provider. AFM rows resolve
            // via kind and always use the canonical `system-default`
            // catalog id (legacy AFM rows with a different modelId
            // would otherwise skip the cap-check). OpenAI-compat rows
            // must match BOTH the catalog model id AND the catalog
            // base URL to count as built-in — a Custom row that
            // happens to use a catalog wire id (e.g. user pointed
            // `gpt-5.5` at a local proxy) must stay classified as
            // Custom or Save would silently overwrite their URL with
            // the catalog default.
            let resolved = Self.resolveEditProvider(
                kind: row.kind,
                modelId: row.modelId,
                baseURL: row.baseURL
            )
            let resolvedProviderID = resolved.providerID
            let resolvedCatalogID = resolved.catalogID
            _providerID = State(initialValue: resolvedProviderID)
            _modelCatalogID = State(initialValue: resolvedCatalogID)
            // Auto-heal the name if the row arrives with an empty
            // string AND the row resolves to a built-in catalog model
            // (Name field is hidden in that case, so an empty name
            // would otherwise permanently disable Save with no UI
            // surface for the user to fix). Falls back to row.name
            // for Custom rows (where the field is visible).
            let resolvedName: String
            if row.name.trimmingCharacters(in: .whitespaces).isEmpty,
               let entry = LLMProviderCatalog.entry(forID: resolvedProviderID),
               let model = entry.models.first(where: { $0.id == resolvedCatalogID }) {
                resolvedName = model.displayName
            } else {
                resolvedName = row.name
            }
            _name = State(initialValue: resolvedName)
            _baseURLText = State(initialValue: row.baseURL?.absoluteString ?? "")
            _modelId = State(initialValue: row.modelId)
            _supportsThinking = State(initialValue: row.supportsThinking)
            _maxContextText = State(initialValue: String(row.maxContextTokens))
            let seedDots = row.hasAPIKey
            _apiKey = State(initialValue: seedDots ? Self.apiKeyPlaceholderDots : "")
            _apiKeyIsPlaceholder = State(initialValue: seedDots)
        } else {
            // Create flow: seed @State from the initial selection's
            // first catalog model (or empty for Custom) so the first
            // render shows the prefilled shape for that provider.
            let seeded = Self.makeCreateSeeds(providerID: initialSelection.providerID)
            _providerID = State(initialValue: seeded.providerID)
            _modelCatalogID = State(initialValue: seeded.modelCatalogID)
            _name = State(initialValue: seeded.name)
            _baseURLText = State(initialValue: seeded.baseURLText)
            _modelId = State(initialValue: seeded.modelId)
            _supportsThinking = State(initialValue: seeded.supportsThinking)
            _maxContextText = State(initialValue: seeded.maxContextText)
            _apiKey = State(initialValue: "")
            _apiKeyIsPlaceholder = State(initialValue: false)
        }
        // Test seam: lets snapshot tests render the inline-error
        // visible state without driving a Save tap. Production
        // callers always pass nil and the error is set in `save()`
        // on an over-cap value.
        _contextWindowError = State(initialValue: initialContextWindowError)
    }

    // MARK: - Selection helpers

    /// Resolved provider entry for the current `providerID`. Falls back
    /// to the Custom entry — guarantees a non-nil value so visibility
    /// predicates don't have to deal with `Optional`. If both the
    /// requested id and the Custom id miss (catalog is empty or
    /// misconfigured), synthesizes a minimal Custom shape rather than
    /// crashing — bad behavior is preferable to a force-unwrap trap
    /// inside a view body.
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

    /// The selected catalog model when the user is on a built-in
    /// provider, or nil when the provider is Custom (no catalog
    /// models). Used by visibility + cap-validation paths.
    private var currentCatalogModel: LLMCatalogModel? {
        guard !isCustom, !modelCatalogID.isEmpty else { return nil }
        return currentProvider.models.first(where: { $0.id == modelCatalogID })
    }

    /// `true` when the active provider is the Apple Intelligence
    /// (`appleFoundation`) kind. URL / key / model-id fields drop out
    /// under this branch and the save path dispatches through
    /// `createAppleFoundationModel`.
    private var isApple: Bool {
        currentProvider.kind == .appleFoundation
    }

    /// `true` when the active provider is Custom — all fields render
    /// editable and no catalog cap applies to Context Window.
    private var isCustom: Bool {
        providerID == LLMProviderCatalog.customProviderID
    }

    /// `true` when the Apple Intelligence provider cannot be picked.
    /// Two disjoint reasons: (a) the OS reports AFM as unavailable on
    /// this device, (b) an `.appleFoundation` row already exists (one
    /// is enough).
    private var isAppleProviderDisabled: Bool {
        !viewModel.appleFoundationAvailability.isAvailable
            || viewModel.hasAppleFoundationModel
    }

    // MARK: - Field visibility

    /// Base URL hidden when a built-in provider (catalog supplies it)
    /// or Apple (no URL at all). Visible only for Custom.
    private var showsBaseURLField: Bool { isCustom }
    /// Same rule as Base URL — name is auto-derived from the picked
    /// catalog model for built-in providers.
    private var showsNameField: Bool { isCustom }
    /// API Key is needed for every provider except Apple (on-device).
    private var showsAPIKeyField: Bool { !isApple }
    /// Model ID text field is shown for Custom in both create AND
    /// edit modes — Custom users own their wire-level model id and
    /// must be able to fix typos after the fact. Built-in providers
    /// surface model selection through the Model dropdown in create
    /// mode, and lock it via the `Provider · Model` header in edit
    /// mode (the row's identity is fixed once persisted).
    private var showsModelIDField: Bool { isCustom }
    /// Thinking toggle is shown when the picked catalog model
    /// supports it, or for Custom (we can't auto-detect — leave it
    /// to the user). Apple's only model is non-thinking so the toggle
    /// stays hidden.
    private var showsThinkingToggle: Bool {
        if let model = currentCatalogModel { return model.supportsThinking }
        return isCustom
    }
    /// In create mode, the Model dropdown row is only useful when the
    /// provider has catalog models. Custom uses a Model ID text field
    /// instead. Apple has one model but we still render the dropdown
    /// for consistency (the entry is the only option).
    private var showsModelDropdown: Bool { !isCustom }

    /// Header text rendered above the form in edit mode when the row
    /// resolves to a built-in provider+model. Nil for Custom (no
    /// header — full editable form) and for unknown configs.
    private var editHeaderLabel: String? {
        guard isEditing else { return nil }
        if isApple {
            return currentProvider.displayName
        }
        if let model = currentCatalogModel {
            return "\(currentProvider.displayName) · \(model.displayName)"
        }
        return nil
    }

    // MARK: - Validation

    /// Validation for the openAI-compatible flow: all visible required
    /// fields legal. URL must parse and pass `isCleartextSafeForCredentials`
    /// (HTTPS, or HTTP against localhost / 127.0.0.1 / ::1 / *.local —
    /// i.e. local-LLM configurations). Max-context must be a positive
    /// integer; key required only in create mode. When Apple is
    /// selected, the URL/key/model-id requirements drop because those
    /// fields are not part of the AFM row's shape — only Name and Max
    /// context need to be valid. Context-window-vs-cap is NOT enforced
    /// here — it's checked on Save tap and surfaced inline so the user
    /// keeps control of the typed value.
    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let maxCtx = Int(maxContextText), maxCtx > 0 else { return false }
        if isApple {
            return true
        }
        // Built-in non-Apple providers: URL + modelId come from the
        // catalog (no field to validate), API key is the only
        // create-mode requirement.
        if !isCustom {
            if !isEditing, apiKey.isEmpty { return false }
            // Defence in depth — the catalog's URL must still parse
            // AND pass the cleartext-safety gate. If a future edit
            // ships a malformed or HTTP-on-non-local URL the form
            // refuses Save rather than persisting garbage that would
            // either fail at send-time or leak a key over cleartext.
            guard let url = currentProvider.defaultBaseURL,
                  isCleartextSafeForCredentials(url) else { return false }
            // Refuse Save if no catalog model is selected.
            guard !modelCatalogID.isEmpty else { return false }
            return true
        }
        // Custom: URL + modelId are user-typed.
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespaces)),
              isCleartextSafeForCredentials(url) else { return false }
        guard !modelId.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isEditing, apiKey.isEmpty { return false }
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
                    apiKeyFieldRow()
                }
                fieldRow(
                    label: "Max context",
                    placeholder: "200000",
                    text: $maxContextText,
                    keyboard: .numberPad,
                    borderBottom: showsThinkingToggle,
                    monospaced: true
                )
                if let errorMessage = contextWindowError {
                    contextWindowErrorRow(errorMessage)
                }
                if showsThinkingToggle {
                    toggleRow(label: "Supports thinking", isOn: $supportsThinking, borderBottom: false)
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
            installPopScrub()
            // Clear any stale message from a previous attempt so it
            // doesn't flash on this open.
            viewModel.clearModelEditError()
        }
        .onDisappear { viewModel.beforePopCleanup = nil }
        .onChange(of: maxContextText) { _, _ in
            // Don't keep a stale "Max for this model is N" error
            // hanging while the user is mid-correction.
            contextWindowError = nil
        }
        .confirmationDialog(
            "Delete this model endpoint?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Clear typed key + disarm cleanup so the dismissal is
                // silent on the iOS side — the user just removed the
                // record, no credential to remember.
                apiKey = ""
                viewModel.beforePopCleanup = nil
                Task {
                    if let editingId { await viewModel.deleteModel(id: editingId) }
                    viewModel.popPane()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the endpoint and the API key from this device. Existing chats keep their transcripts.")
        }
    }

    // MARK: - Picker section (create mode)

    /// Two stacked dropdown rows — Provider and Model — replacing the
    /// pre-PR preset pill row. Custom collapses the Model dropdown into
    /// a Model ID text field since there's no catalog to enumerate.
    @ViewBuilder
    private var pickerSection: some View {
        SettingsGroup {
            providerPickerRow(borderBottom: showsModelDropdown)
            if showsModelDropdown {
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
        // Placeholder for the unresolved state (modelCatalogID empty
        // or absent from the provider's catalog) — distinguishes
        // "nothing selected yet" from "the first option is selected,"
        // which would otherwise look identical and let Save commit
        // a value the user didn't choose.
        let label = currentCatalogModel?.displayName ?? "Select model…"
        pickerRow(label: "Model", value: label, borderBottom: borderBottom) {
            ForEach(currentProvider.models) { model in
                Button(action: { applyModelSelection(model.id) }) {
                    Text(model.displayName)
                }
            }
        }
    }

    /// One picker row: a label on the left, the current selection on
    /// the right, and a Menu opened by tapping the row. Styling
    /// mirrors `fieldRow` (label cap, callout value) so the two row
    /// types share the same visual rhythm.
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
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(typography.font(.caption, weight: .medium))
                    .foregroundStyle(theme.inkFaint)
                    .textCase(.uppercase)
                    .tracking(0.5)
                HStack(spacing: 8) {
                    Text(value)
                        .font(typography.font(.callout))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(typography.font(.footnote, weight: .semibold))
                        .foregroundStyle(theme.inkFaint)
                }
            }
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

    /// Static "Provider · Model" header rendered in edit mode in
    /// place of the dropdowns. Communicates the row's identity
    /// without inviting the user to reclassify a persisted config.
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

    // MARK: - Sub-views

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

    /// Dedicated row for the API-key `SecureField`. Owns the focus
    /// binding and the placeholder-bullet bookkeeping so the rest of
    /// the form keeps using the plain `fieldRow` helper. On first focus
    /// the synthetic bullets clear so the user types into an empty
    /// field; any other mutation (e.g. paste) also drops the
    /// placeholder flag so we don't accidentally treat user input as
    /// "no change."
    @ViewBuilder
    private func apiKeyFieldRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(typography.font(.caption, weight: .medium))
                .foregroundStyle(theme.inkFaint)
                .textCase(.uppercase)
                .tracking(0.5)
            SecureField(isEditing ? "•••• (tap to change)" : "sk-…", text: $apiKey)
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
                    // Catch paste / programmatic edits that bypass the
                    // focus-clear path. If the value diverged from the
                    // sentinel bullets we're no longer showing a
                    // placeholder.
                    if apiKeyIsPlaceholder, newValue != Self.apiKeyPlaceholderDots {
                        apiKeyIsPlaceholder = false
                    }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderFaint)
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }

    /// The actual text/secure field. Keyboard hints are applied here so
    /// the iOS-only modifiers stay in one gated branch.
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

    /// Inline error row beneath the Context Window field. Rendered
    /// only after a Save tap with an over-cap value.
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
                .foregroundStyle(isValid ? theme.background : theme.inkFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isValid ? theme.accent : theme.backgroundRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.borderFaint, lineWidth: isValid ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isValid)
    }

    private var deleteButton: some View {
        Button(action: { showingDeleteConfirm = true }) {
            Text("Delete model endpoint")
                .font(typography.font(.callout, weight: .medium))
                .foregroundStyle(theme.errorAccent)
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
        .accessibilityHint("Removes this model endpoint and its stored API key.")
    }

    // MARK: - Actions

    /// Installs the cleanup the view model invokes during `popPane` /
    /// `popToRoot`. We capture the `apiKey` @State binding so the closure
    /// can scrub it before the SecureField's UIView is torn down — this
    /// is what stops iOS from queueing a "Save Password?" prompt against
    /// the discarded content. The Save action removes this hook before
    /// popping so iOS still gets to offer iCloud Keychain save on a real
    /// commit.
    private func installPopScrub() {
        let apiKeyBinding = $apiKey
        viewModel.beforePopCleanup = {
            apiKeyBinding.wrappedValue = ""
        }
    }

    /// Switch the active provider and reseed the form's @State to the
    /// new provider's first catalog model (or empty when Custom).
    /// Guarded against re-selecting the current provider so a stray
    /// tap doesn't blow away user-typed values. Apple is also
    /// short-circuited when disabled.
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
        supportsThinking = seeded.supportsThinking
        apiKey = ""
        apiKeyIsPlaceholder = false
        contextWindowError = nil
    }

    /// Pick a different catalog model within the current provider.
    /// Reseeds name, modelId, max-context, and thinking from the
    /// catalog entry. API key is preserved (it's per-endpoint, not
    /// per-model). Custom never enters this path — its Model ID is a
    /// text field, not a picker.
    private func applyModelSelection(_ catalogID: String) {
        guard let entry = currentProvider.models.first(where: { $0.id == catalogID }) else { return }
        guard catalogID != modelCatalogID else { return }
        modelCatalogID = catalogID
        name = entry.displayName
        modelId = entry.id
        maxContextText = String(entry.maxContextTokens)
        supportsThinking = entry.supportsThinking
        contextWindowError = nil
    }

    /// Resolve which Add-Model "Provider" the edit form should open in for
    /// an existing row, plus the catalog model id to preselect. Extracted
    /// from `init` so the classification is unit-testable without standing
    /// up the whole view.
    ///
    /// Order matters:
    /// 1. **`.appleFoundation`** → the Apple entry (resolves by kind; legacy
    ///    AFM rows with an off-catalog `modelId` still get the canonical
    ///    `system-default` cap-check).
    /// 2. **Native-search kinds** (`.anthropicNative`/`.geminiNative`/
    ///    `.openAIResponses`) → classify **by kind, before any URL match**.
    ///    Their persisted `baseURL` (e.g. `api.openai.com/v1` for Responses)
    ///    is byte-identical to a compat entry's `defaultBaseURL`, so a
    ///    URL-first match would misfile an `.openAIResponses` row as the
    ///    `"openai"` compat provider and open it in compat-edit mode — where
    ///    a model-id change on Save could overwrite the native wire id. Until
    ///    the native edit UI ships these resolve to Custom (visible, fully
    ///    editable, never auto-reclassified by URL); the adapter PR maps them
    ///    to their own native provider entries here.
    /// 3. **OpenAI-compat** → must match BOTH the catalog model id AND the
    ///    catalog base URL (trailing-slash tolerant); otherwise Custom, so a
    ///    user who points a catalog wire id at their own proxy isn't
    ///    reclassified and re-URL'd on Save.
    static func resolveEditProvider(
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
            // Native-search kinds: classify by kind, **never by URL** — and
            // do it here, before the URL-match branch, *independent of*
            // `hasProviderAdapter`. This is deliberate: `.openAIResponses`
            // now has a shipped adapter (`hasProviderAdapter == true`) yet its
            // persisted `baseURL` (`https://api.openai.com/v1`) is
            // byte-identical to the compat "openai" entry's `defaultBaseURL`,
            // so a URL-first match would misfile it as the compat provider and
            // reopen it in compat-edit mode (where a model-id change on Save
            // could overwrite the native wire id). Resolving by kind keeps that
            // from happening regardless of the flag's value — the tripwire test
            // `resolveEditProviderNeverMisfilesOpenAIResponsesToCompat` pins it.
            //
            // Custom is the safe target until the native Add-Model edit UI
            // ships (web-search PR5): the row stays fully visible/editable and
            // is never URL-reclassified. PR5 maps these to their own native
            // provider entries here.
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

    /// Trailing-slash tolerant URL comparison. Treats `…/path` and
    /// `…/path/` as equal so edit-mode disambiguation in `init` doesn't
    /// misclassify a row whose persisted URL drifted by one slash.
    /// Returns `true` when both URLs are nil; otherwise normalises
    /// each side by stripping a single trailing `/` from
    /// `absoluteString` and compares the results.
    static func urlsMatchIgnoringTrailingSlash(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (l?, r?):
            return Self.urlNormalized(l) == Self.urlNormalized(r)
        }
    }

    /// Helper for ``urlsMatchIgnoringTrailingSlash`` — drops every
    /// trailing `/` from the URL's absolute string. The loop (rather
    /// than a single drop) handles values that arrive with multiple
    /// trailing slashes (`…/v1//`) without falling through to the
    /// Custom branch.
    static func urlNormalized(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Pure helper that produces the initial @State seed values for a
    /// given provider id in the create flow. Centralized so the init
    /// seam (for snapshot tests pinning an initial selection) and the
    /// runtime `applyProviderSelection` path share one source of truth.
    static func makeCreateSeeds(providerID: String) -> CreateSeeds {
        // Same three-level fallback as `currentProvider` — never
        // force-unwrap on a catalog lookup since the helper is called
        // from every `applyProviderSelection` tap.
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
                // Thinking-by-default for Custom — the user can't know
                // ahead of time what their endpoint supports and the
                // failure mode of enabling it on a non-thinking model
                // is benign (the provider ignores the flag).
                supportsThinking: true
            )
        }
        // Non-Custom providers must have ≥1 model — `nonCustomProvidersHaveModels`
        // pins this at the catalog layer, and this precondition is the
        // matching runtime guard so a future catalog drift fires loudly
        // here rather than silently disabling Save through the empty
        // `modelCatalogID` path in `isValid`.
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

    /// Seed bundle used by `init` and `applyProviderSelection`. Mirror
    /// of the @State fields a provider swap reseeds.
    struct CreateSeeds: Equatable, Sendable {
        let providerID: String
        let modelCatalogID: String
        let name: String
        let baseURLText: String
        let modelId: String
        let maxContextText: String
        let supportsThinking: Bool
    }

    /// Placeholder shown in the Name field when Custom is selected.
    /// Built-ins hide the Name field entirely (the picked model's
    /// display name auto-populates the row), so this is only consulted
    /// for Custom.
    private var customNamePlaceholder: String { "GPT 5.5" }

    private func save() {
        guard isValid else { return }
        guard let maxCtx = Int(maxContextText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Context-window cap is the one validation that surfaces as
        // an inline error rather than blocking Save preemptively.
        // Custom and unknown-modelId edits skip it (no catalog
        // entry → no cap). Editing a built-in row uses the catalog
        // model resolved from `modelId` at init time.
        if let cap = currentCatalogModel?.maxContextTokens, maxCtx > cap {
            contextWindowError = "Maximum context for this model is \(cap.formatted(.number)) tokens."
            return
        } else {
            contextWindowError = nil
        }
        // Apple Intelligence: no URL, key, or model id — the secure-field
        // bookkeeping below is a no-op for this branch because the field
        // isn't rendered.
        if isApple {
            viewModel.beforePopCleanup = nil
            // AFM rows are write-once (id and shape are fixed). The
            // edit path for AFM is purely Name + Max Context; the
            // create path runs `createAppleFoundationModel`. We
            // dispatch on `isEditing` even though AFM-in-edit shares
            // the same view-model surface as openAI-compat updates.
            if let editingId {
                // AFM rows have no baseURL — pass nil; updateModel
                // preserves the existing (nil) value for the row's
                // .appleFoundation kind.
                Task {
                    await viewModel.updateModel(
                        id: editingId,
                        name: trimmedName,
                        baseURL: nil,
                        modelId: modelId,
                        apiKey: "",
                        supportsThinking: supportsThinking,
                        maxContextTokens: maxCtx
                    )
                    if viewModel.modelEditError == nil {
                        viewModel.popPane()
                    }
                }
            } else {
                Task {
                    await viewModel.createAppleFoundationModel(
                        name: trimmedName,
                        supportsThinking: supportsThinking,
                        maxContextTokens: maxCtx
                    )
                    if viewModel.modelEditError == nil {
                        viewModel.popPane()
                    }
                }
            }
            return
        }
        // Resolve the base URL: built-in providers source it from the
        // catalog (the field is hidden); Custom reads the user-typed
        // value. We re-validate at save time even for catalog values
        // so a hypothetical bad catalog ships a hard error rather
        // than a malformed row.
        let resolvedURL: URL?
        if isCustom {
            resolvedURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        } else {
            resolvedURL = currentProvider.defaultBaseURL
        }
        guard let url = resolvedURL else { return }
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespaces)
        // Disarm the pop cleanup so the SecureField's content survives
        // dismissal — iOS sees a populated field on tear-down and offers
        // to save the credential in iCloud Keychain. (On Back without
        // save the cleanup runs and clears the field, suppressing that
        // same prompt.) Exception: when only the synthetic bullets are
        // in the field (user didn't touch the key), leave the scrub
        // armed so iOS doesn't offer to save the bullets as a password.
        if !apiKeyIsPlaceholder {
            viewModel.beforePopCleanup = nil
        }
        // When the user opened an existing row and never tapped into
        // the API-key field, `apiKey` still holds the synthetic
        // bullets — pass "" so `updateModel`'s blank-key branch leaves
        // the stored Keychain entry alone. Without this guard the
        // bullets would be persisted as the literal API key on save.
        let keyForSave = apiKeyIsPlaceholder ? "" : apiKey
        Task {
            if let editingId {
                await viewModel.updateModel(
                    id: editingId,
                    name: trimmedName,
                    baseURL: url,
                    modelId: trimmedModelId,
                    apiKey: keyForSave,
                    supportsThinking: supportsThinking,
                    maxContextTokens: maxCtx
                )
            } else {
                await viewModel.createModel(
                    name: trimmedName,
                    baseURL: url,
                    modelId: trimmedModelId,
                    apiKey: keyForSave,
                    supportsThinking: supportsThinking,
                    maxContextTokens: maxCtx
                )
            }
            // Only pop on success — a non-nil error keeps the pane up
            // so the user sees the message and can retry. Re-arm the
            // pop cleanup since we're staying so the SecureField gets
            // scrubbed on a subsequent Back tap.
            if viewModel.modelEditError == nil {
                viewModel.popPane()
            } else {
                installPopScrub()
            }
        }
    }
}
