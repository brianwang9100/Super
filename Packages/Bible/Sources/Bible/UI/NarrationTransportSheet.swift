import AVFoundation
import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Narrate transport, hosted in a native `.sheet`. Presents as the
/// "now playing" surface under the nav-bar speaker button; the page stays
/// readable behind it (`presentationBackgroundInteraction`), so it sits over
/// the reader without a scrim.
///
/// Layout (top → bottom): a header row with a decorative speaker badge on the
/// left, a `NOW NARRATING` / citation pair in the centre, and a stop button on
/// the right; a transport row with restart-verse / play-pause / next-verse
/// circles; a divider; and a row of two dropdowns for voice and speed. The
/// system supplies the drag bar above the header.
///
/// Dismissal model:
///   - **Stop** halts playback only — the card stays so the play button
///     can re-run the same Narrate flow (via `onRestart`) without
///     reopening the spark menu. Nothing flips the presentation state on
///     Stop, so the native sheet stays up.
///   - **Drag the sheet down** (or tap the nav-bar speaker again) hides it;
///     the system animates the dismissal.
///
/// The restart-verse glyph is a single button that, at the controller
/// level, behaves like a 2000s music player: one tap restarts the
/// current verse, a second tap inside one second jumps to the previous
/// verse. The card has no UI affordance for the double-tap — it's
/// discoverable by feel, same as on those devices.
struct NarrationTransportSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.openURL) private var openURL
    @Bindable var controller: NarrationController
    // Base point sizes for the card's text styles, carried as scaled metrics
    // so each composes OS Dynamic Type (via the metric) on top of the app
    // font-scale slider (folded in by `SuperTypography`). Bases match the
    // semantic styles they replace: .caption2 == 11, .headline == 17,
    // .footnote == 13 at the default content-size category.
    @ScaledMetric(relativeTo: .caption2) private var eyebrowSize: CGFloat = 11
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var chipSize: CGFloat = 13
    /// Short citation of what's being narrated — shown as the card's
    /// title line under the `NOW NARRATING` label (e.g.
    /// `"1 Peter 2:5"`). Updates as narration advances; the caller
    /// derives it from `BibleScreenViewModel.narrationCitation`.
    let citation: String
    /// Invoked when the user taps Stop. The card does NOT auto-dismiss
    /// — typical wiring is `controller.stop()` and nothing else.
    let onStop: () -> Void
    /// Invoked when the big play button is tapped from `.idle` state
    /// (post-Stop) — the caller re-runs the same selection-aware
    /// Narrate flow the spark menu's `Narrate` entry triggers, so the
    /// user doesn't have to reopen the menu just to retry.
    let onRestart: () -> Void

    /// Locale-filtered voice list backed by the process-wide
    /// ``cachedVoices`` so the 100-300 ms
    /// `AVSpeechSynthesisVoice.speechVoices()` scan runs at most once
    /// per process. `@State` would survive a single presentation but
    /// resets when the card is removed from the hierarchy; under the
    /// Stop-keeps-the-card flow the user dismisses + re-presents the
    /// card freely, and a per-presentation rescan would jank each
    /// re-open.
    @State private var voices: [VoiceOption] = NarrationTransportSheet.cachedVoices

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            transportRow
            Divider().background(theme.borderFaint)
            controlsRow
        }
        // The card is now a native `.sheet` (the system supplies the drag bar,
        // rounded surface, and drag-to-dismiss). These insets are the content
        // padding the retired `BibleSheetChromeModifier` used to provide; the
        // extra top room clears the system drag indicator.
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .task {
            // First-open path only: `cachedVoices` was empty at view
            // construction, so do the 100-300 ms
            // `AVSpeechSynthesisVoice.speechVoices()` scan on a
            // detached background task (running it on `@MainActor`
            // here would freeze the main thread the instant the card
            // slides in) and persist the result to the process-wide
            // cache so subsequent presentations skip the scan.
            if voices.isEmpty {
                let loaded = await Task.detached(priority: .userInitiated) {
                    Self.loadLocaleVoices()
                }.value
                Self.cachedVoices = loaded
                voices = loaded
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            decorativeBadge
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW NARRATING")
                    // Scaled-metric base so Dynamic Type scales the eyebrow
                    // with the citation underneath rather than freezing it,
                    // and the app font-scale slider moves it too.
                    .font(typography.font(size: eyebrowSize, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.inkSoft)
                Text(citation)
                    // 17pt semibold (== `.headline`) over a scaled-metric
                    // base, so it scales with both Dynamic Type and the app
                    // font-scale slider.
                    .font(typography.font(size: titleSize, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stopButton
        }
        .accessibilityElement(children: .contain)
    }

    /// Pure decoration matching the mock — a soft-tinted rounded
    /// square holding the speaker glyph. Mirrors the nav-bar speaker
    /// button visually so the card reads as the same surface "expanded
    /// down" from the nav.
    private var decorativeBadge: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(typography.font(size: 18, weight: .semibold))
            .foregroundStyle(theme.accent)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accent.opacity(0.14))
            )
            .accessibilityHidden(true)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(typography.font(size: 13, weight: .bold))
                .foregroundStyle(theme.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.backgroundSunken))
        }
        .buttonStyle(.plain)
        // Disabled (and dimmed) when there's no active session to
        // stop. Drag the handle to dismiss the card in that state.
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
            case .speaking: return "pause.fill"
            }
        }()
        let label: String = {
            switch controller.state {
            case .idle: return "Restart narration"
            case .speaking: return "Pause narration"
            case .paused: return "Resume narration"
            }
        }()
        return Button {
            switch controller.state {
            // Post-Stop, the card stays up so this play button can re-
            // run the same selection-aware Narrate flow the spark
            // menu's `Narrate` entry triggers — no need to reopen the
            // menu just to retry.
            case .idle: onRestart()
            case .speaking: controller.pause()
            case .paused: controller.resume()
            }
        } label: {
            Image(systemName: glyph)
                .font(typography.font(size: 22, weight: .bold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 56, height: 56)
                .background(Circle().fill(theme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
                .background(Circle().fill(theme.backgroundSunken))
        }
        .buttonStyle(.plain)
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

    @ViewBuilder
    private var voiceDropdown: some View {
        if voices.isEmpty {
            // No Enhanced or Premium voice installed — surface a tap
            // target into iOS Settings rather than an empty menu. The
            // chip stays the same shape so the row doesn't reflow.
            Button {
                openSpokenContentSettings()
            } label: {
                dropdownChip(label: "Voice", value: "Install →")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice. Open iOS Settings to install Enhanced voices.")
        } else {
            Menu {
                ForEach(voices) { option in
                    Button {
                        controller.voice = AVSpeechSynthesisVoice(identifier: option.id)
                    } label: {
                        if option.id == controller.voice?.identifier {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                dropdownChip(label: "Voice", value: currentVoiceShortName)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Voice, current \(currentVoiceShortName)")
        }
    }

    // MARK: Speed dropdown

    private var speedDropdown: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { rate in
                Button {
                    controller.rate = rate
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

    /// Pill-shaped dropdown trigger used by both Voice and Speed —
    /// keeps the two chips visually identical so the row reads as
    /// a single control pair. Text uses `.footnote` so Dynamic Type
    /// scales the labels and values together with the rest of the
    /// card; the chip is `minHeight: 44` (Apple's minimum tap target)
    /// rather than a fixed height so taller text doesn't clip.
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.backgroundSunken)
        )
    }

    // MARK: Derived strings

    /// Strip the `— Enhanced` / `— Premium` suffix from the chip so the
    /// pill stays short; the full label still appears in the open menu.
    private var currentVoiceShortName: String {
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
        // Whole numbers render without a decimal — `1×` not `1.00×`.
        if abs(rate.rounded() - rate) < 0.001 {
            return "\(Int(rate))×"
        }
        // Trim trailing zeros so `1.25` stays `1.25×` but `1.50` shows
        // as `1.5×` — matches the dropdown options exactly.
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }

    // MARK: Voice loading

    /// User's primary language code, used to filter the voice list down
    /// to voices that can pronounce English (or whatever the OS locale
    /// is) intelligibly. Falls back to `"en"` when the locale lacks a
    /// language code.
    private static var localeLanguagePrefix: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Marked `nonisolated` so the detached background `Task` in
    /// `body.task` can invoke it without re-entering `@MainActor` and
    /// blocking the main thread on the ~100-300 ms voice scan.
    nonisolated private static func loadLocaleVoices() -> [VoiceOption] {
        let prefix = localeLanguagePrefix
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            // Compact voices are intentionally excluded — they sound
            // robotic and the picker's job is to surface natural voices
            // only. Users with no Enhanced/Premium installed get the
            // "Install →" chip that deep-links to iOS Settings.
            .filter { $0.quality == .enhanced || $0.quality == .premium }
            .map { VoiceOption(
                id: $0.identifier,
                displayName: voiceDisplayName($0)
            )}
            .sorted { $0.displayName < $1.displayName }
    }

    private static func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
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

    /// Process-wide cache of locale-filtered voices, populated the
    /// first time the card opens. Subsequent presentations seed their
    /// `@State` from this so the scan doesn't run on every card open.
    /// `@MainActor` (implicit from the view) so the assignment in
    /// `.task` is safe. The cache is per-process — voices installed
    /// while the app is running won't appear until next launch, which
    /// matches the OS's own voice-install behaviour anyway.
    @MainActor
    private static var cachedVoices: [VoiceOption] = []

    /// Discrete speed multiples the dropdown offers. 0.5× was dropped
    /// from the prior slider design — the spec wants the round-number
    /// stops a media-player menu typically surfaces, and skipping the
    /// half-speed makes room for 2× without crowding the menu.
    static let rateOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// Deep-link the user into iOS Settings → Accessibility → Spoken
    /// Content, which is where Enhanced / Premium voices download.
    /// Uses the unofficial `App-Prefs:` URL scheme that Apple has
    /// tolerated for years — if a future iOS rejects it we fall back
    /// to opening the app's own Settings page (still useful: the user
    /// can navigate from there).
    private func openSpokenContentSettings() {
        // `URL(string:)` always returns non-nil for a syntactically-
        // valid string, so the `guard` is defensive against a future
        // typo, not a fallback for parse failure. The real
        // "scheme rejected" fallback is the `accepted` callback below.
        guard let url = URL(string: "App-Prefs:ACCESSIBILITY&path=SETTINGS_SPOKEN_CONTENT") else { return }
        #if canImport(UIKit)
        openURL(url) { accepted in
            // Fallback: if the system refused the deep link, drop the
            // user into the app's own settings page rather than nothing.
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
