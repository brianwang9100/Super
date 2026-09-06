import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Guides the user through installing Apple's enhanced voices and links to the system voice settings.
struct AppleNarrationSetupSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var settings: NarrationSettingsController
    @State private var couldNotOpenSettings = false

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "Apple voices", onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A more natural reading voice")
                            .font(typography.font(.title3, weight: .semibold))
                        Text("Apple's Enhanced and Premium voices are free downloads. Once installed, they work offline without an API key.")
                            .font(typography.font(.body)).foregroundStyle(theme.inkSoft)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        step(1, title: "Open Accessibility", detail: "In Settings, open Accessibility, then Read & Speak (or Spoken Content).")
                        step(2, title: "Choose a voice", detail: "Tap Voices, then choose your language and a voice you like.")
                        step(3, title: "Download Enhanced or Premium", detail: "Download the higher-quality version over Wi-Fi, then return to SuperBible.")
                    }
                    .padding(18)
                    .background(theme.backgroundRaised, in: RoundedRectangle(cornerRadius: 14))

                    Button(action: openVoiceSettings) {
                        Label("Open Settings", systemImage: "arrow.up.forward")
                            .font(typography.font(.body, weight: .semibold))
                            .foregroundStyle(Color.blue)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .superGlassButton(in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Settings for Apple voices")

                    Text("If Settings opens on its main page, follow the steps above.")
                        .font(typography.font(.footnote)).foregroundStyle(theme.inkFaint)
                    if settings.appleEnhancedVoicesAvailable == true {
                        Label("Configured — an enhanced voice is installed.", systemImage: "checkmark.circle")
                            .font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
                    } else {
                        Text("We'll check for downloaded voices when you return. You can keep using Apple's standard voice in the meantime.")
                            .font(typography.font(.footnote)).foregroundStyle(theme.inkFaint)
                    }
                    if couldNotOpenSettings {
                        Text("Open the Settings app manually and follow the steps above.")
                            .font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
                    }
                }
                .padding(20)
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await settings.refreshAppleVoices() } }
        }
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(typography.font(.subheadline, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(typography.font(.subheadline, weight: .medium))
                Text(detail).font(typography.font(.footnote)).foregroundStyle(theme.inkSoft)
            }
        }
    }

    private func openVoiceSettings() {
        guard let url = URL(string: "App-Prefs:ACCESSIBILITY&path=SETTINGS_SPOKEN_CONTENT") else { return }
        openURL(url) { accepted in
            guard !accepted else { return }
            couldNotOpenSettings = true
            #if canImport(UIKit)
            if let fallback = URL(string: UIApplication.openSettingsURLString) { openURL(fallback) }
            #endif
        }
    }
}
