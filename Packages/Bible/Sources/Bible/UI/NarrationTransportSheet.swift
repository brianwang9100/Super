import AVFoundation
import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Inline overlay card hosting the Narrate transport. Sits above the
/// shell's chat pill while narration is running and rides under the
/// nav-bar speaker button as the "now playing" surface.
///
/// Layout (top → bottom): a draggable handle; a header row with a
/// decorative speaker badge on the left, a `NOW NARRATING` / citation
/// pair in the centre, and a stop button on the right; a transport row
/// with restart-verse / play-pause / next-verse circles; a divider;
/// and a row of two dropdowns for voice and speed.
///
/// Dismissal model:
///   - **Stop** halts playback only — the card stays so the play button
///     can re-run the same Narrate flow (via `onRestart`) without
///     reopening the spark menu.
///   - **Drag the handle down** is the only way to actually hide the
///     card. Dismissing is animated (the caller wraps `onDismiss` in
///     `withAnimation`).
///   - Tapping outside the card does NOT dismiss it — the card is an
///     inline overlay, not a UIKit sheet, so there's no system scrim.
///
/// The restart-verse glyph is a single button that, at the controller
/// level, behaves like a 2000s music player: one tap restarts the
/// current verse, a second tap inside one second jumps to the previous
/// verse. The card has no UI affordance for the double-tap — it's
/// discoverable by feel, same as on those devices.
struct NarrationTransportSheet: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: NarrationController
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
    /// Invoked when the user drags the handle past the dismiss
    /// threshold. Callers wrap this in `withAnimation` so the card
    /// slides out with the screen's `BibleSheetMotion` rather than
    /// snapping off.
    let onDismiss: () -> Void

    /// Cached, locale-filtered voice list so the picker doesn't re-call
    /// `AVSpeechSynthesisVoice.speechVoices()` on every body re-evaluation
    /// — it's a ~100-300 ms synchronous file scan.
    @State private var voices: [VoiceOption] = []
    /// Live drag offset for the handle gesture. Reset to zero on a
    /// short drag (spring-back); on a drag past the dismiss threshold
    /// the offset is left at its end position so the card's slide-out
    /// transition continues from where the finger left it instead of
    /// snapping back to centre first.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dragHandle
            header
            transportRow
            Divider().background(theme.borderFaint)
            controlsRow
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(theme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.borderFaint, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 6)
        .offset(y: dragOffset)
        // Suppresses SwiftUI's implicit transaction animation on
        // gesture-driven offset changes. Without this, parent
        // animation contexts (from the screen's `withAnimation`
        // wrappers around presentation flips) can leak into the per-
        // frame offset updates, producing a visible jitter as the
        // animation interpolator fights the gesture's discrete writes.
        .animation(nil, value: dragOffset)
        .task {
            if voices.isEmpty {
                voices = Self.loadLocaleVoices()
            }
        }
    }

    // MARK: Drag handle

    /// Horizontal pill at the top of the card that the user grabs to
    /// dismiss. The visible capsule is small; the surrounding container
    /// is intentionally taller (and uses `contentShape(Rectangle())`) so
    /// the touch target matches a system sheet's drag affordance rather
    /// than just the 4pt-tall pill. The card follows the finger in real
    /// time via `dragOffset`; a drag past
    /// ``Self.dismissTranslationThreshold`` (or with enough downward
    /// flick velocity) triggers `onDismiss`. Anything shorter springs
    /// back to centre.
    private var dragHandle: some View {
        Capsule()
            .fill(theme.borderFaint)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            // `.global` (not `.local`) is load-bearing: the offset
            // modifier moves the handle's local origin every frame, so
            // a `.local`-space gesture would measure each `onChanged`
            // value against a moved coordinate system and produce a
            // self-feedback loop that reads as jitter on screen.
            // Measuring in global space keeps the gesture coordinate
            // stable while the card visually follows the finger.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Upward drags are clamped to zero so the card
                        // doesn't peel off the top — only downward
                        // motion counts toward dismissal.
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        let dragged = value.translation.height
                        let predicted = value.predictedEndTranslation.height
                        if dragged > Self.dismissTranslationThreshold ||
                           predicted > Self.dismissPredictedThreshold {
                            // Leave dragOffset where the finger left
                            // it so the slide-out transition continues
                            // from the same position instead of
                            // snapping back to centre first.
                            onDismiss()
                        } else {
                            // Match the rest of the Bible screen's
                            // Reduce Motion handling (see
                            // `BibleChapterReader`'s narration auto-
                            // scroll, which also opts out of animation
                            // when the user has reduced motion on).
                            let springBack: Animation? = reduceMotion
                                ? nil
                                : .spring(response: 0.32, dampingFraction: 0.85)
                            withAnimation(springBack) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    /// Downward drag distance past which the card commits to dismiss.
    /// 80pt is roughly the depth of one of the transport rows — small
    /// enough that a deliberate drag never has to cross the whole card,
    /// large enough that a stray finger movement on a button doesn't
    /// trip it.
    private static let dismissTranslationThreshold: CGFloat = 80
    /// Predicted end translation past which a quick flick (even if its
    /// current displacement is small) commits to dismiss — mirrors how
    /// system sheets honour velocity.
    private static let dismissPredictedThreshold: CGFloat = 160

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            decorativeBadge
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW NARRATING")
                    // Relative text style so Dynamic Type scales the
                    // eyebrow with the citation underneath rather than
                    // freezing it at 10pt regardless of user setting.
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.inkSoft)
                Text(citation)
                    // `.headline` is the same nominal 17pt + semibold
                    // as the prior absolute, but scales with Dynamic
                    // Type so accessibility users see a larger title.
                    .font(.headline)
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
            .font(.system(size: 18, weight: .semibold))
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
                .font(.system(size: 13, weight: .bold))
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
                .font(.system(size: 22, weight: .bold))
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
                .font(.system(size: 16, weight: .semibold))
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
                .font(.footnote)
                .foregroundStyle(theme.inkSoft)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
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

    private static func loadLocaleVoices() -> [VoiceOption] {
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
        let url = URL(string: "App-Prefs:ACCESSIBILITY&path=SETTINGS_SPOKEN_CONTENT")
            ?? URL(string: "App-Prefs:ACCESSIBILITY")
        guard let url else { return }
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
