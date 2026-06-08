import Core
import SwiftUI

/// App-level shell content for the SuperOS target. Renders `AppShell`
/// once the bootstrap dependency graph is `.ready`, a `SplashView`
/// during `.loading`, and a `FailureScreen` when the bootstrap fails.
///
/// `AppShell` lives in `App/Shell/AppShell.swift` and is bundled into
/// both the SuperOS *and* SuperBible targets via `project.yml` file
/// inclusion. SuperBible has its own equivalent `SuperBibleContentView`
/// that hands it a `SuperBibleAppDependencies.shellDependencies` slice.
struct SuperOSContentView: View {
    let state: SuperOSBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Per-branch .transition + parent .animation = real cross-fade.
        Group {
            switch state {
            case .loading:
                // Pin Light: matches the Info.plist SplashBackground colorset.
                SplashView()
                    .superTheme(.make(.vellumLight))
                    .transition(.opacity)
            case .failed(let message):
                FailureScreen(message: message)
                    .transition(.opacity)
            case .ready(let dependencies):
                AppShell(dependencies: dependencies.shellDependencies)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: state.discriminant
        )
    }
}

// MARK: - Previews

#Preview("loading") {
    SuperOSContentView(state: .loading)
}

#Preview("failed") {
    SuperOSContentView(state: .failed("could not open chat.sqlite"))
}
