import SwiftUI

/// Branded launch surface: pale-green field with the centered Super wordmark
/// lockup (spark + italic-serif text) and a pulsing footer (loading dot +
/// version mark). Shown while the app's bootstrap is in flight; replaced by
/// the shell once dependencies are ready.
///
/// Reads colors from the ambient `SuperTheme`. Per SPEC: 393×852 pt
/// reference canvas, lockup vertically centered on the *screen* (not the
/// safe area), footer 58 pt above the bottom safe-area inset.
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
    /// `skipEntranceAnimation: true` seeds both `@State` flags at their
    /// resting values so the captured frame is fully revealed at pulse peak,
    /// independent of `onAppear` ordering under the snapshot host window.
    init(version: String, skipEntranceAnimation: Bool) {
        self.version = version
        _pulse = State(initialValue: skipEntranceAnimation)
        _revealed = State(initialValue: skipEntranceAnimation)
    }

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            // Lockup: VStack ignores the safe area so its Spacers split the
            // full screen height (not the safe area) — yields screen-centered.
            VStack(spacing: 0) {
                Spacer()
                lockup
                Spacer()
            }
            .ignoresSafeArea()

            // Footer: VStack respects the safe area, so .padding(.bottom, 58)
            // lifts the footer 58pt above the safe-area bottom (SPEC).
            VStack(spacing: 0) {
                Spacer()
                footer
            }
            .padding(.bottom, 58)
        }
    }

    private var lockup: some View {
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
        // Scoped here so a future parent state change can't retime through this curve.
        .animation(
            reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.6),
            value: revealed
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Super, loading")
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { revealed = true }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(theme.accent)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 1.0 : 0.35)
                .scaleEffect(pulse ? 1.05 : 0.85)
                // Scoped to the Circle so .repeatForever doesn't leak.
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulse
                )
            Text("V \(version) · EST. MMXXV")
                .font(.custom("JetBrainsMono-Regular", size: 10.5))
                .tracking(1.4)
                .foregroundStyle(theme.inkFaint)
        }
        .accessibilityHidden(true)
        .onAppear { pulse = true }
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
