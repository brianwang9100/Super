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
        HStack(spacing: 10) {
            // Card body: tap pushes the edit pane. Wrapping just the body
            // (not the toggle) in a Button keeps the toggle's tap region
            // independent so flipping the switch doesn't also navigate.
            Button(action: { viewModel.openPane(.modelDetail(id: model.id)) }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accentSoft)
                        Text(model.monogram.uppercased())
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.system(.subheadline).weight(.medium))
                            .foregroundStyle(theme.ink)
                        Text("\(model.maxContextTokens / 1000)K ctx · \(model.endpoint)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(theme.inkFaint)
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
                    get: { model.isEnabled },
                    set: { newValue in
                        Task { await viewModel.setModelEnabled(id: model.id, enabled: newValue) }
                    }
                ),
                accessibilityLabel: model.name
            )
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

    private var addModelButton: some View {
        Button(action: { viewModel.openPane(.modelDetail(id: nil)) }) {
            HStack(spacing: 6) {
                PlusIcon(size: 14)
                Text("Add model endpoint")
                    .font(.system(.subheadline))
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
