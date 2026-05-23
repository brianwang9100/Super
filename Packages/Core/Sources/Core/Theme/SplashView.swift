import SwiftUI

/// Branded launch surface: pale-green field with the centered Super wordmark
/// lockup (spark + italic-serif text) and a pulsing footer (loading dot +
/// version mark). Shown while the app's bootstrap is in flight; replaced by
/// the shell once dependencies are ready.
///
/// Reads colors from the ambient `SuperTheme` so theme switching at runtime
/// (Settings → theme) carries through if the splash is reused as a "thinking"
/// or "reset" surface later. The composition follows the SPEC: 393×852 pt
/// reference canvas, lockup centered on the *screen* (not the safe area),
/// footer 58 pt from the bottom safe area.
///
/// Fonts required: `InstrumentSerif-Italic` and `JetBrainsMono-Regular`. The
/// host must call `Core.registerBundledFonts()` before the first render or
/// SwiftUI will fall back to system faces.
public struct SplashView: View {
    private let version: String

    @Environment(\.superTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulse: Bool
    @State private var revealed: Bool

    public init() {
        self.init(version: SuperAppInfo.fromBundle().version, skipEntranceAnimation: false)
    }

    /// Test-only initializer. `version` lets snapshot tests pin the version
    /// string without depending on the host bundle's Info.plist;
    /// `skipEntranceAnimation: true` seeds the lockup + pulse states at
    /// their resting poses so the captured frame is already revealed and
    /// at the pulse peak. The resting pose is encoded entirely in the
    /// initial `@State` values — `.onAppear` only transitions from the
    /// start pose, so a state seeded to resting renders rest immediately
    /// and the snapshot doesn't depend on `onAppear` ordering.
    init(version: String, skipEntranceAnimation: Bool) {
        self.version = version
        _pulse = State(initialValue: skipEntranceAnimation)
        _revealed = State(initialValue: skipEntranceAnimation)
    }

    public var body: some View {
        ZStack {
            theme.background

            // Lockup — centered on the screen (the ZStack ignores the safe
            // area below, so the VStack's center aligns with the screen's
            // geometric center, not the safe-area's). Per SPEC.
            VStack(spacing: 18) {
                SplashSpark()
                    .stroke(theme.accentDark, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .frame(width: 44, height: 44)
                Text("Super")
                    .font(.custom("InstrumentSerif-Italic", size: 38))
                    .foregroundStyle(theme.ink)
                    .tracking(-0.57)
            }
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 4)
            // SPEC: lockup fade-up 4pt over 600ms with the design-system
            // "ease" curve. Scoped here so a future parent state change
            // (e.g. cross-fade to AppShell) doesn't get retimed through
            // this curve.
            .animation(
                reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.6),
                value: revealed
            )
            // VoiceOver: replace the deleted `ProgressView`'s implicit
            // "loading" semantic with an explicit combined element. The
            // wordmark Text is decorative once the label says it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Super, loading")
            .accessibilityAddTraits(.updatesFrequently)

            // Footer — pinned to the bottom safe area, 58pt above it. Marked
            // as decorative chrome so VoiceOver doesn't read "V 1.0 · EST.
            // MMXXV" as content.
            VStack(spacing: 14) {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 1.0 : 0.35)
                    .scaleEffect(pulse ? 1.05 : 0.85)
                    // SPEC: 1.6s round-trip pulse (0.8s autoreverse). Scoped
                    // to the Circle so the `.repeatForever` modifier
                    // doesn't sit in the parent ZStack's diff and retime
                    // unrelated descendant writes.
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulse
                    )
                Text("V \(version) · EST. MMXXV")
                    .font(.custom("JetBrainsMono-Regular", size: 10.5))
                    .tracking(1.4)
                    .foregroundStyle(theme.inkFaint)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 58)
            .accessibilityHidden(true)
        }
        // The ZStack itself must ignore the safe area or the lockup centers
        // inside the safe-area rect, not the screen. SPEC: screen-centered.
        .ignoresSafeArea()
        .onAppear {
            revealed = true
            pulse = true
        }
    }
}

#Preview("Light") {
    SplashView()
        .superTheme(.make(.light))
}

#Preview("Dark") {
    SplashView()
        .superTheme(.make(.dark))
}

#Preview("Sepia") {
    SplashView()
        .superTheme(.make(.sepia))
}
