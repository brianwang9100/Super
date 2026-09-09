import AVFoundation
import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Stop keeps this sheet open for replay; the caller handles dismissal through onClose.
struct NarrationTransportSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private let sizing = SheetSizing.fitsContent

    @Bindable var controller: NarrationController
    @ScaledMetric(relativeTo: .footnote) private var chipSize: CGFloat = 13
    let citation: String
    /// Halts playback without dismissing the sheet.
    let onStop: () -> Void
    /// Restarts the current selection-aware narration flow from idle.
    let onRestart: () -> Void
    let onClose: () -> Void

    @State private var showsVoicePicker = false
    @State private var voicePickerWidth: CGFloat = 360
    // Seed from the last scan while refreshing newly installed voices off-main.
    @State private var voices: [VoiceOption] = NarrationTransportSheet.cachedVoices

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                transportRow
                Divider().background(theme.borderFaint)
                controlsRow
                if let error = controller.lastError {
                    Text(error.message).font(typography.font(.footnote)).foregroundStyle(theme.errorAccent)
                    HStack {
                        if controller.voice?.company == .openAI {
                            Button("Use Apple voice") { controller.useAppleVoice() }
                        }
                        Button("Retry") { controller.retry() }
                    }.font(typography.font(.footnote))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        .padding(.bottom, 16)
        // Share the first-paint estimate with the reader's scroll reserve.
        .sheetPresentation(
            sizing,
            readableBackground: true,
            estimatedHeight: BibleBottomOverlayKind.narration.estimatedSheetHeight
        )
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            voicePickerWidth = min(360, max(280, width - 32))
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshVoices() }
        }
    }

    private func refreshVoices() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadLocaleVoices()
        }.value
        guard !Task.isCancelled else { return }
        Self.cachedVoices = loaded
        voices = loaded
    }

    // MARK: Header

    private var header: some View {
        SheetNavBar(title: citation, sizing: sizing, onClose: onClose) {
            stopButton
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(typography.font(size: 14, weight: .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .disabled(controller.state == .idle)
        .opacity(controller.state == .idle ? 0.35 : 1)
        .accessibilityLabel("Stop narration")
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: 28) {
            Spacer(minLength: 0)
            verseSkipButton(
                systemImage: "backward.end.fill",
                accessibilityLabel:
                    "Restart current verse. Double-tap to skip to the previous verse."
            ) { controller.skipPrevious() }

            playPauseButton

            verseSkipButton(
                systemImage: "forward.end.fill",
                accessibilityLabel: "Skip to next verse"
            ) { controller.skipNext() }
            Spacer(minLength: 0)
        }
    }

    private var playPauseButton: some View {
        let glyph: String = {
            switch controller.state {
            case .idle, .paused: return "play.fill"
            case .speaking, .preparing: return "pause.fill"
            }
        }()
        let label: String = {
            switch controller.state {
            case .idle: return "Restart narration"
            case .speaking, .preparing: return "Pause narration"
            case .paused: return "Resume narration"
            }
        }()
        return Button {
            switch controller.state {
            case .idle: onRestart()
            case .speaking, .preparing: controller.pause()
            case .paused: controller.resume()
            }
        } label: {
            Group {
                if controller.state == .preparing {
                    ProgressView()
                        .tint(theme.accentInk)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: glyph)
                        .font(typography.font(size: 22, weight: .bold))
                }
            }
                .foregroundStyle(theme.accentInk)
                .frame(width: 56, height: 56)
                .superGlassButton(in: Circle(), tint: theme.accent)
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel(label)
        .accessibilityValue(controller.state == .preparing ? "Preparing audio" : "")
    }

    private func verseSkipButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(typography.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 44, height: 44)
                .superGlassButton(in: Circle())
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .disabled(controller.state == .idle)
        .opacity(controller.state == .idle ? 0.35 : 1)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Controls row (voice + speed dropdowns)

    private var controlsRow: some View {
        HStack(spacing: 10) {
            voiceDropdown
                .frame(maxWidth: .infinity)
            speedDropdown
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Voice dropdown

    private var voiceDropdown: some View {
        Button { showsVoicePicker = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentVoiceShortName).font(typography.font(size: chipSize, weight: .semibold))
                        .lineLimit(1)
                    Text(controller.voice?.companyName ?? "Apple")
                        .font(typography.font(size: chipSize)).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(theme.inkSoft)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(typography.font(size: 9))
            }
            .foregroundStyle(theme.ink).padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .superGlassButton(in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(GlassHapticButtonStyle(.selection))
        .accessibilityLabel("Voice, \(currentVoiceShortName), \(controller.voice?.companyName ?? "Apple")")
        .popover(isPresented: $showsVoicePicker, arrowEdge: .bottom) {
            NarrationVoicePicker(
                controller: controller, appleVoices: voices,
                onSelect: { choice in
                    showsVoicePicker = false
                    Task { await controller.selectVoice(choice) }
                },
                onInstallAppleVoices: {
                    showsVoicePicker = false
                    openSpokenContentSettings()
                }
            )
            .frame(width: voicePickerWidth, height: 520)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(theme.background)
        }
    }

    // MARK: Speed dropdown

    private var speedDropdown: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { rate in
                Button {
                    Task { await controller.selectRate(rate) }
                } label: {
                    if abs(rate - controller.rate) < 0.001 {
                        Label(Self.format(rate: rate), systemImage: "checkmark")
                    } else {
                        Text(Self.format(rate: rate))
                    }
                }
            }
        } label: {
            dropdownChip(label: "Speed", value: Self.format(rate: controller.rate))
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Speed, current \(Self.format(rate: controller.rate))")
    }

    // Use a minimum height so larger text can grow beyond the 44pt tap target.
    private func dropdownChip(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(typography.font(size: chipSize))
                .foregroundStyle(theme.inkSoft)
            Spacer(minLength: 8)
            Text(value)
                .font(typography.font(size: chipSize, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(typography.font(size: 9, weight: .semibold))
                .foregroundStyle(theme.inkSoft)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .superGlassButton(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Derived strings

    private var currentVoiceShortName: String {
        if let voice = controller.voice?.openAI { return voice.name }
        guard let identifier = controller.voice?.identifier,
              let option = voices.first(where: { $0.id == identifier }) else {
            return "Default"
        }
        if let dash = option.displayName.firstIndex(of: "—") {
            return option.displayName[..<dash]
                .trimmingCharacters(in: .whitespaces)
        }
        return option.displayName
    }

    private static func format(rate: Float) -> String {
        if abs(rate.rounded() - rate) < 0.001 {
            return "\(Int(rate))×"
        }
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }

    // MARK: Voice loading

    nonisolated private static var localeLanguagePrefix: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    // Voice discovery can block; stay nonisolated so detached scans do not re-enter the UI actor.
    nonisolated private static func loadLocaleVoices() -> [VoiceOption] {
        let prefix = localeLanguagePrefix
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            // Only downloaded Enhanced/Premium voices belong in this picker; otherwise offer installation.
            .filter { $0.quality == .enhanced || $0.quality == .premium }
            .map {
                VoiceOption(id: $0.identifier, displayName: voiceDisplayName($0))
            }
            .sorted { $0.displayName < $1.displayName }
    }

    nonisolated private static func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        let tier: String
        switch voice.quality {
        case .premium: tier = "Premium"
        case .enhanced: tier = "Enhanced"
        default: tier = ""
        }
        return tier.isEmpty
            ? "\(voice.name) (\(voice.language))"
            : "\(voice.name) — \(tier)"
    }

    @MainActor
    private static var cachedVoices: [VoiceOption] = []

    static let rateOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    // App-Prefs is unofficial. If the system rejects it, open the app's settings instead.
    private func openSpokenContentSettings() {
        guard let url = URL(string: "App-Prefs:ACCESSIBILITY&path=SETTINGS_SPOKEN_CONTENT") else { return }
        #if canImport(UIKit)
        openURL(url) { accepted in
            if !accepted, let fallback = URL(string: UIApplication.openSettingsURLString) {
                openURL(fallback)
            }
        }
        #else
        openURL(url)
        #endif
    }

    struct VoiceOption: Identifiable, Hashable {
        let id: String
        let displayName: String
    }
}
