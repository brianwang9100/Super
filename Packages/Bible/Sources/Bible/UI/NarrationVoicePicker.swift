import Core
import SwiftUI

/// A wide, scrollable voice chooser with a stable company order and a visible selection mark.
struct NarrationVoicePicker: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: NarrationController
    let appleVoices: [NarrationTransportSheet.VoiceOption]
    let onSelect: (NarrationVoice) -> Void
    let onInstallAppleVoices: () -> Void
    @State private var showsSettings = false
    @ScaledMetric(relativeTo: .body) private var voiceSize: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            SheetNavBar(title: "Voices", onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.settings?.openAIAvailable == true {
                        VStack(alignment: .leading, spacing: 0) {
                            companyHeading("OpenAI")
                            ForEach(OpenAISpeechVoice.allCases, id: \.self) { voice in
                                voiceRow(NarrationVoice(company: .openAI, identifier: voice.rawValue), name: voice.name)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        companyHeading("Apple")
                        voiceRow(.appleDefault, name: "System Default")
                        ForEach(appleVoices) { option in
                            voiceRow(NarrationVoice(company: .apple, identifier: option.id), name: option.displayName)
                        }
                        Button("Install Apple voices…", action: onInstallAppleVoices)
                            .font(typography.font(.subheadline))
                            .foregroundStyle(Color.blue)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .accessibilityLabel("Install Apple voices")
                    }
                    if controller.settings != nil {
                        Divider()
                        Button("Narration settings…") { showsSettings = true }
                            .font(typography.font(.subheadline))
                            .foregroundStyle(Color.blue)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .accessibilityLabel("Narration settings")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.background)
        .sheet(isPresented: $showsSettings) {
            if let settings = controller.settings {
                NarrationSettingsPane(settings: settings, controller: controller, includesHeader: true)
            }
        }
    }

    private func companyHeading(_ company: String) -> some View {
        Text(company)
            .font(typography.font(.caption, weight: .semibold))
            .foregroundStyle(theme.inkSoft)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 4)
    }

    private func voiceRow(_ voice: NarrationVoice, name: String) -> some View {
        let selected = voice == (controller.voice ?? .appleDefault)
        return Button { onSelect(voice) } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(typography.font(size: voiceSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(typography.font(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("\(name), \(voice.companyName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
