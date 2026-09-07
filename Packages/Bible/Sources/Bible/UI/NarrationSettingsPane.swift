import Core
import SwiftUI

/// Narration connections, styled like the model registration list, with provider-specific setup sheets.
struct NarrationSettingsPane: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var settings: NarrationSettingsController
    let controller: NarrationController
    var includesHeader = false
    @State private var setup: Connection?

    private enum Connection: String, Identifiable {
        case apple, openAI
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if includesHeader {
                SheetNavBar(title: "Narration", sizing: .fitsContent, onClose: { dismiss() })
                ScrollView { connections }
            } else {
                connections
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.background)
        .sheet(item: $setup, onDismiss: { Task { await settings.refreshAppleVoices() } }) { connection in
            switch connection {
            case .apple: AppleNarrationSetupSheet(settings: settings)
            case .openAI: OpenAINarrationSetupSheet(settings: settings, controller: controller)
            }
        }
        .task { await settings.refreshAppleVoices() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await settings.refreshAppleVoices() } }
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONNECTIONS")
                .font(typography.font(.caption2, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            connectionCard(
                title: "Apple enhanced voices",
                subtitle: "Natural voices that work offline. Free with your device.",
                symbol: "apple.logo",
                configured: settings.appleEnhancedVoicesAvailable,
                connection: .apple
            )
            connectionCard(
                title: "OpenAI",
                subtitle: settings.hasKey && settings.record.enabled == false
                    ? "Your API key is saved. Narration is turned off."
                    : "Expressive AI narration with your own API key.",
                symbol: "waveform",
                configured: settings.hasKey,
                connection: .openAI
            )

            Text("Choose a voice in the narration player. Tap a connection to set it up or manage it.")
                .font(typography.font(.footnote))
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private func connectionCard(
        title: String, subtitle: String, symbol: String, configured: Bool?, connection: Connection
    ) -> some View {
        HStack(spacing: 12) {
            Button { setup = connection } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(typography.font(size: 18, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(typography.font(.subheadline, weight: .medium))
                            .foregroundStyle(theme.ink)
                        Text(subtitle).font(typography.font(.caption))
                            .foregroundStyle(theme.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(configured == true ? "Manage connection" : "Set up connection")

            if configured == false {
                Button("Set up") { setup = connection }
                    .font(typography.font(.subheadline, weight: .medium))
                    .foregroundStyle(Color.blue)
                    .frame(minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set up \(title)")
            } else {
                Text(configured == true ? "Configured" : "Checking…")
                    .font(typography.font(.caption))
                    .foregroundStyle(theme.inkFaint)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(14)
        .superGlassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
