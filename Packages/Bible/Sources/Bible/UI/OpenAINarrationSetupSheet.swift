import Core
import SwiftUI

/// Saving an explicitly supplied OpenAI credential connects narration after billing disclosure.
struct OpenAINarrationSetupSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: NarrationSettingsController
    let controller: NarrationController
    @State private var keyDraft: NarrationKeyDraft
    @FocusState private var keyFieldFocused: Bool
    @State private var sourceId: String
    @State private var revision: Int
    @State private var saving = false
    @State private var showsClearConfirmation = false
    @State private var message: String?

    init(settings: NarrationSettingsController, controller: NarrationController) {
        self.settings = settings
        self.controller = controller
        _keyDraft = State(initialValue: NarrationKeyDraft(hasSavedKey: settings.hasKey && settings.record.ownsKey))
        _sourceId = State(initialValue: settings.source?.id ?? "")
        _revision = State(initialValue: settings.record.revision)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "OpenAI", onClose: close) { saveButton }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Expressive voices for your reading")
                            .font(typography.font(.title3, weight: .semibold))
                        Text("Connect your OpenAI API key to narrate with Marin, Cedar, and more.")
                            .font(typography.font(.body)).foregroundStyle(theme.inkSoft)
                    }
                    credentialFields
                    billingDisclosure
                    if let message = settings.errorMessage ?? message {
                        Text(message).font(typography.font(.footnote)).foregroundStyle(theme.errorAccent)
                    }
                    if settings.hasKey || settings.record.enabled != nil { connectionActions }
                }
                .padding(20)
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.background)
        .tint(theme.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(saving)
        .onDisappear { keyDraft.clear() }
        .onChange(of: sourceId) { _, id in
            keyDraft = NarrationKeyDraft(hasSavedKey: settings.hasKey && settings.record.ownsKey && id == settings.record.sourceId)
        }
    }

    private var saveDisabled: Bool {
        let keepingSavedKey = settings.hasKey && sourceId == settings.source?.id
        let selectingKey = settings.sources.contains { $0.id == sourceId }
        return saving || (keyDraft.replacement.isEmpty && !keepingSavedKey && !selectingKey)
    }

    private var saveButton: some View {
        Button(action: save) {
            Group {
                if saving {
                    ProgressView().tint(theme.accentInk)
                } else {
                    Image(systemName: "checkmark")
                        .font(typography.font(size: 16, weight: .semibold))
                        .foregroundStyle(saveDisabled ? theme.inkMute : theme.accentInk)
                }
            }
            .frame(width: 44, height: 44)
            .superGlassCTAButton(in: Circle())
            .opacity(saveDisabled ? 0.6 : 1)
        }
        .buttonStyle(GlassHapticButtonStyle(.primary))
        .disabled(saveDisabled)
        .accessibilityLabel("Save OpenAI connection")
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !settings.sources.isEmpty {
                Picker("API key", selection: $sourceId) {
                    Text("Enter a narration-only key").font(typography.font(.body)).tag("")
                    if settings.record.ownsKey, let source = settings.source {
                        Text(source.name).font(typography.font(.body)).tag(source.id)
                    }
                    ForEach(settings.sources) { source in
                        Text(source.name).font(typography.font(.body)).tag(source.id)
                    }
                }
                .font(typography.font(.body))
                .accessibilityLabel("OpenAI API key source")
            }
            if sourceId.isEmpty || settings.record.ownsKey && sourceId == settings.source?.id {
                VStack(alignment: .leading, spacing: 10) {
                    Text("API KEY").font(typography.font(.caption2, weight: .semibold)).foregroundStyle(theme.inkFaint)
                    SecureField("OpenAI API key", text: $keyDraft.value,
                                prompt: Text(settings.record.ownsKey && sourceId == settings.source?.id ? "•••• (tap to change)" : "Paste your OpenAI API key")
                                    .font(typography.font(.body)).foregroundStyle(theme.inkSoft))
                        .font(typography.font(.body))
                        .textContentType(.password)
                        .focused($keyFieldFocused)
                        .onChange(of: keyFieldFocused) { _, focused in
                            if focused { keyDraft.beginEditing() }
                        }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityLabel("OpenAI API key")
                }
            }
        }
        .padding(18)
        .background(theme.backgroundRaised, in: RoundedRectangle(cornerRadius: 14))
    }

    private var billingDisclosure: some View {
        VStack(alignment: .leading, spacing: 14) {
            disclosure("Billed by OpenAI", detail: "Audio generation uses your API account's balance. A ChatGPT subscription does not include API usage.")
            disclosure("Generated in the cloud", detail: "Passage text is sent directly to OpenAI to create an AI-generated voice. An internet connection is needed for new audio.")
            Text("Saving connects this key and enables OpenAI narration. Audio is generated only when you press Play.")
                .font(typography.font(.footnote)).foregroundStyle(theme.inkFaint)
        }
    }

    private func disclosure(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(typography.font(.subheadline, weight: .medium))
            Text(detail).font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
        }
    }

    private var connectionActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            Button("Clear downloaded narration", role: .destructive) {
                showsClearConfirmation = true
            }
            .font(typography.font(.body)).foregroundStyle(theme.errorAccent)
            .accessibilityLabel("Clear downloaded OpenAI narration")
            .confirmationDialog("Clear downloaded narration?", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
                Button("Clear downloads", role: .destructive, action: clearDownloads)
                    .font(typography.font(.body))
                Button("Cancel", role: .cancel) {}
                    .font(typography.font(.body))
            } message: {
                Text("This will stop narration and delete downloaded audio. Playing it again requires an internet connection and may incur OpenAI API charges.")
                    .font(typography.font(.body))
            }
        }
    }

    private func clearDownloads() {
        message = nil
        Task {
            do { try await controller.clearCachedAudio() } catch {
                message = "Downloaded narration could not be cleared. Try again."
            }
        }
    }

    private func close() {
        guard !saving else { return }
        keyDraft.clear()
        dismiss()
    }

    private func save() {
        guard !saveDisabled else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                guard revision == settings.record.revision else { throw NarrationSettingsError.staleDraft }
                if !keyDraft.replacement.isEmpty {
                    try await settings.saveDedicatedKey(keyDraft.replacement, enabled: true, expecting: revision)
                } else if let source = settings.sources.first(where: { $0.id == sourceId }) {
                    try await settings.configure(credential: source, enabled: true, useThisKey: true, expecting: revision)
                } else {
                    try await settings.setEnabled(true)
                }
                keyDraft.clear()
                sourceId = settings.source?.id ?? ""
                revision = settings.record.revision
                dismiss()
            } catch NarrationSettingsError.staleDraft {
                revision = settings.record.revision
                message = "Settings changed while this draft was open. Review the saved key before saving again."
            } catch NarrationSettingsError.secureStorage {
                message = "Could not save your key securely on this device. The connection was not updated."
            } catch {
                message = "Could not save narration. Check that an OpenAI API key is selected or entered, then try again."
            }
        }
    }
}
