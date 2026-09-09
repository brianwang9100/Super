import SwiftUI

/// The host must register Core's bundled fonts before rendering to avoid system fallback.
public struct SplashView: View {
    private let name: String
    private let version: String

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulse: Bool
    @State private var revealed: Bool

    public init() {
        let info = SuperAppInfo.fromBundle()
        self.init(name: info.bundleName, version: info.version, skipEntranceAnimation: false)
    }

    // Pin bundle metadata and seed resting animation state independently of onAppear timing.
    init(name: String, version: String, skipEntranceAnimation: Bool) {
        self.name = name
        self.version = version
        _pulse = State(initialValue: skipEntranceAnimation)
        _revealed = State(initialValue: skipEntranceAnimation)
    }

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            // Center the lockup on the screen, not the safe area.
            VStack(spacing: 0) {
                Spacer()
                lockup
                Spacer()
            }
            .ignoresSafeArea()

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
            Text(name)
                // The launch wordmark uses a fixed size.
                .font(typography.display(38, relativeTo: nil, tracksFontScale: false))
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
        .accessibilityLabel("\(name), loading")
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
                .font(typography.mono(10.5, relativeTo: nil, tracksFontScale: false))
                .tracking(1.4)
                .foregroundStyle(theme.inkFaint)
        }
        .accessibilityHidden(true)
        .onAppear { pulse = true }
    }
}

#Preview("Vellum Light") {
    SplashView()
        .superTheme(.make(.vellumLight))
}

#Preview("Vellum Dark") {
    SplashView()
        .superTheme(.make(.vellumDark))
}

#Preview("Lapis Light") {
    SplashView()
        .superTheme(.make(.lapisLight))
}
