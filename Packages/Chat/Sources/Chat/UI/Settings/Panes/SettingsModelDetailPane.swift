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
/// `editingId == nil` ⇒ blank form, Save creates a new row. `editingId`
/// non-nil ⇒ form is seeded from the existing row and Save updates it
/// in place; a Delete button appears at the bottom (with a destructive
/// confirmation dialog) so the user can remove the endpoint.
///
/// Validation is local: Save stays disabled until name, base URL, model
/// id, and max-context all have legal values. The API-key field is
/// optional in edit mode (blank means "keep existing"); in create mode
/// it's required.
struct SettingsModelDetailPane: View {
    @Bindable var viewModel: SettingsViewModel
    /// `nil` ⇒ create. Non-nil ⇒ id of the row to edit.
    let editingId: String?

    @Environment(\.superTheme) private var theme

    @State private var name: String
    @State private var baseURLText: String
    @State private var modelId: String
    @State private var apiKey: String
    @State private var supportsThinking: Bool
    @State private var maxContextText: String
    @State private var showingDeleteConfirm: Bool = false
    /// Active preset in the create flow. Edit mode pins to
    /// ``Preset/custom`` so the picker is suppressed entirely — existing
    /// rows already have their fields set and the user is past the
    /// "which provider" decision.
    @State private var preset: Preset
    /// `true` while `apiKey` holds the synthetic bullets we seeded to
    /// signal "a key is stored" — flips to `false` the first time the
    /// field gains focus (clearing the bullets) or the user mutates the
    /// text any other way (e.g. paste). When `true`, `save()` passes
    /// `""` for apiKey so the existing "blank ⇒ don't rotate" contract
    /// in `SettingsViewModel.updateModel` preserves the stored key.
    @State private var apiKeyIsPlaceholder: Bool
    @FocusState private var apiKeyFieldFocused: Bool

    /// Fixed number of bullets used as the synthetic stand-in for an
    /// existing key. Length is intentionally fixed rather than matching
    /// the real key length — leaking key length is a small information
    /// disclosure we have no reason to invite.
    private static let apiKeyPlaceholderDots = String(repeating: "•", count: 12)

    private var isEditing: Bool { editingId != nil }

    /// `true` when the form is in create mode and the active preset is
    /// `.appleFoundation`. AFM rows carry no URL, key, or editable model
    /// id, so those fields are hidden under this preset and the save
    /// path dispatches through `createAppleFoundationModel`.
    private var isAppleFoundationPreset: Bool {
        !isEditing && preset == .appleFoundation
    }

    /// `true` when the Apple Intelligence preset cannot be activated.
    /// Two disjoint reasons: (a) the OS reports AFM as unavailable on
    /// this device (`appleIntelligenceNotEnabled`, etc.), (b) an
    /// `.appleFoundation` row already exists (one is enough).
    private var isAppleFoundationPresetDisabled: Bool {
        !viewModel.appleFoundationAvailability.isAvailable
            || viewModel.hasAppleFoundationModel
    }

    init(
        viewModel: SettingsViewModel,
        editingId: String?,
        initialPreset: Preset = .custom
    ) {
        self.viewModel = viewModel
        self.editingId = editingId
        // Seed @State at init time so the first render shows live data.
        // Doing this in `.onAppear` made the snapshot capture pre-seed
        // values for the toggle (the lifecycle hook hadn't fired yet).
        let row = editingId.flatMap { viewModel.model(id: $0) }
        if let row {
            _name = State(initialValue: row.name)
            _baseURLText = State(initialValue: row.baseURL?.absoluteString
                ?? "https://api.openai.com/v1")
            _modelId = State(initialValue: row.modelId)
            _supportsThinking = State(initialValue: row.supportsThinking)
            _maxContextText = State(initialValue: String(row.maxContextTokens))
            let seedDots = row.hasAPIKey
            _apiKey = State(initialValue: seedDots ? Self.apiKeyPlaceholderDots : "")
            _apiKeyIsPlaceholder = State(initialValue: seedDots)
            // Edit mode pins to .custom — picker is hidden in body anyway.
            _preset = State(initialValue: .custom)
        } else {
            // Create flow: seed @State from the preset's defaults so the
            // snapshot tests can pin an initial preset and the first
            // render shows that preset's prefilled fields.
            let seeds = initialPreset.defaults
            _name = State(initialValue: seeds.name)
            _baseURLText = State(initialValue: seeds.baseURLText)
            _modelId = State(initialValue: seeds.modelId)
            _supportsThinking = State(initialValue: seeds.supportsThinking)
            _maxContextText = State(initialValue: seeds.maxContextText)
            _apiKey = State(initialValue: "")
            _apiKeyIsPlaceholder = State(initialValue: false)
            _preset = State(initialValue: initialPreset)
        }
    }

    /// Validation for the openAI-compatible flow: all four required
    /// fields legal. URL must parse and pass `isCleartextSafeForCredentials`
    /// (HTTPS, or HTTP against localhost / 127.0.0.1 / ::1 / *.local
    /// — i.e. local-LLM configurations). Max-context must be a positive
    /// integer; key required only in create mode. When the Apple
    /// Intelligence preset is active, the URL/key/modelId requirements
    /// drop because those fields are not part of the AFM row's shape —
    /// only Name and Max context need to be valid.
    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let maxCtx = Int(maxContextText), maxCtx > 0 else { return false }
        if isAppleFoundationPreset {
            return true
        }
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespaces)),
              isCleartextSafeForCredentials(url) else { return false }
        guard !modelId.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isEditing, apiKey.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEditing {
                presetPicker
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
            }

            SettingsGroup {
                fieldRow(label: "Name", placeholder: namePlaceholder, text: $name)
                if !isAppleFoundationPreset {
                    fieldRow(label: "Base URL", placeholder: "https://api.openai.com/v1", text: $baseURLText, keyboard: .url)
                    fieldRow(label: "Model ID", placeholder: "gpt-5.5", text: $modelId)
                    apiKeyFieldRow()
                }
                fieldRow(label: "Max context", placeholder: "200000", text: $maxContextText, keyboard: .numberPad, monospaced: true)
                toggleRow(label: "Supports thinking", isOn: $supportsThinking, borderBottom: false)
            }
            .padding(.top, 16)

            saveButton
                .padding(.horizontal, 16)
                .padding(.top, 18)

            if let errorMessage = viewModel.modelEditError {
                Text(errorMessage)
                    .font(.system(.footnote))
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
                .font(.system(.caption).weight(.medium))
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
                .font(.system(.caption).weight(.medium))
                .foregroundStyle(theme.inkFaint)
                .textCase(.uppercase)
                .tracking(0.5)
            SecureField(isEditing ? "•••• (tap to change)" : "sk-…", text: $apiKey)
                .focused($apiKeyFieldFocused)
                .font(.system(.callout))
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
                .font(.system(.callout))
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

    private var saveButton: some View {
        Button(action: save) {
            Text(isEditing ? "Save" : "Add Model")
                .font(.system(.body).weight(.semibold))
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
                .font(.system(.callout).weight(.medium))
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

    private func save() {
        guard isValid else { return }
        guard let maxCtx = Int(maxContextText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Apple Intelligence: no URL, key, or model id — the secure-field
        // bookkeeping below is a no-op for this branch because the field
        // isn't rendered.
        if isAppleFoundationPreset {
            viewModel.beforePopCleanup = nil
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
            return
        }
        guard let url = URL(string: baseURLText.trimmingCharacters(in: .whitespaces)) else { return }
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

    // MARK: - Preset picker

    /// Add-Model preset. Drives field prefill + which fields render in
    /// the create flow. Edit mode pins to `.custom` and the picker is
    /// hidden (the row's identity is locked once persisted).
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case appleFoundation
        case google
        case custom

        var id: String { rawValue }

        /// Pill label shown in the picker. Short by design — three
        /// pills need to fit on a single 402pt-wide iPhone row without
        /// truncation.
        var label: String {
            switch self {
            case .appleFoundation: return "Apple"
            case .google: return "Google"
            case .custom: return "Custom"
            }
        }

        /// Initial @State values to seed when this preset becomes
        /// active. Centralized as a pure helper so both the init seam
        /// (for snapshot tests that pin an initial preset) and the
        /// runtime applyPreset path share one source of truth.
        struct Defaults: Equatable, Sendable {
            let name: String
            let baseURLText: String
            let modelId: String
            let maxContextText: String
            let supportsThinking: Bool
        }

        var defaults: Defaults {
            switch self {
            case .appleFoundation:
                return Defaults(
                    name: "Apple Intelligence",
                    baseURLText: "",
                    modelId: "system-default",
                    maxContextText: "4096",
                    supportsThinking: false
                )
            case .google:
                return Defaults(
                    name: "Gemini 2.5 Pro",
                    baseURLText: "https://generativelanguage.googleapis.com/v1beta/openai/",
                    modelId: "gemini-2.5-pro",
                    maxContextText: "1000000",
                    supportsThinking: true
                )
            case .custom:
                return Defaults(
                    name: "",
                    baseURLText: "https://api.openai.com/v1",
                    modelId: "",
                    maxContextText: "200000",
                    supportsThinking: false
                )
            }
        }
    }

    /// Hint shown in the Name field's placeholder. The preset's
    /// recommended name doubles as the placeholder so the user can
    /// either accept (it's already typed) or override.
    private var namePlaceholder: String {
        switch preset {
        case .appleFoundation: return "Apple Intelligence"
        case .google: return "Gemini 2.5 Pro"
        case .custom: return "GPT 5.5"
        }
    }

    /// Three-segment pill picker styled to match the rest of the
    /// settings sheet (rounded card, accent fill on the selected pill,
    /// border-faint stroke on inactive pills). Hidden in edit mode so
    /// existing rows can't be reclassified through the form.
    @ViewBuilder
    private var presetPicker: some View {
        HStack(spacing: 8) {
            ForEach(Preset.allCases) { option in
                presetPill(for: option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preset")
    }

    @ViewBuilder
    private func presetPill(for option: Preset) -> some View {
        let isSelected = preset == option
        let isDisabled = option == .appleFoundation && isAppleFoundationPresetDisabled
        let foreground: Color = isSelected ? theme.background
            : (isDisabled ? theme.inkFaint : theme.inkSoft)
        let background: Color = isSelected ? theme.accent : theme.backgroundRaised
        Button(action: { applyPreset(option) }) {
            Text(option.label)
                .font(.system(.subheadline).weight(.medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.borderFaint, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint(isDisabled
            ? "Unavailable on this device or already added"
            : "Prefill the form with \(option.label) defaults")
    }

    /// Switch the active preset and reseed the form's @State to that
    /// preset's defaults. Guarded against re-applying the same preset
    /// so a stray tap on the already-selected pill doesn't blow away
    /// user-typed values. AFM preset is also short-circuited when
    /// disabled — the disabled pill should be uninteractive even if
    /// SwiftUI's `.disabled` somehow doesn't suppress the tap.
    private func applyPreset(_ option: Preset) {
        if option == .appleFoundation, isAppleFoundationPresetDisabled { return }
        guard preset != option else { return }
        preset = option
        let seeds = option.defaults
        name = seeds.name
        baseURLText = seeds.baseURLText
        modelId = seeds.modelId
        maxContextText = seeds.maxContextText
        supportsThinking = seeds.supportsThinking
        apiKey = ""
        apiKeyIsPlaceholder = false
    }
}
