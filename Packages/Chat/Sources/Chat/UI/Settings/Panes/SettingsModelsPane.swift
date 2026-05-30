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
            ForEach(viewModel.models) { model in
                modelCard(model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            addModelButton
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 20)
        }
        .padding(.top, 8)
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
                            .font(typography.mono(13, weight: .semibold))
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 1)
        )
    }

    /// Whether the row is usable right now. `.openAICompatible` rows are
    /// always usable from the UI's perspective — wire-level errors
    /// surface as runtime banners, not toggle gating. `.appleFoundation`
    /// rows are usable only when the OS reports AFM as available.
    private func isModelAvailable(_ model: SettingsViewModel.ModelRow) -> Bool {
        switch model.kind {
        case .openAICompatible, .anthropicNative, .geminiNative, .openAIResponses:
            // Remote rows (compat shim or a native-search adapter) are
            // always usable from the UI's perspective; wire-level errors
            // surface as runtime banners, not toggle gating.
            return true
        case .appleFoundation:
            return viewModel.appleFoundationAvailability.isAvailable
        #if DEBUG
        case .debug:
            return true
        #endif
        }
    }

    /// `.openAICompatible` rows show context + endpoint (the existing
    /// monospaced "4K ctx · api.openai.com" line). `.appleFoundation`
    /// rows show the model id when available, and the unavailability
    /// reason otherwise — the AFM equivalent of an endpoint subtitle.
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

    private var addModelButton: some View {
        Button(action: { viewModel.openPane(.modelDetail(id: nil)) }) {
            HStack(spacing: 6) {
                PlusIcon(size: 14)
                Text("Add model endpoint")
                    .font(typography.font(.subheadline))
            }
            .foregroundStyle(theme.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(14)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        theme.border,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
