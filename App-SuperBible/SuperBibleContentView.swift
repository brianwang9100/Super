import Core
import SwiftUI

/// SuperBible shell entry view. Switches on the launch state and renders
/// the shared `AppShell` (lifted out of `App/Shell/AppShell.swift`,
/// compiled into both targets via the explicit project.yml file-inclusion
/// list) once the bootstrap is `.ready`.
///
/// `.loading` deliberately paints a flat `SplashBackground` field rather
/// than the shared `SplashView` SuperOS uses. The system launch screen
/// (`UILaunchScreen` in `project.yml`) already shows the Star of
/// Bethlehem mark + wordmark over the same `#3f774d` field; using the
/// cream-themed `SplashView` here would hard-cut from dark green to
/// cream at the moment SwiftUI mounts. A flat color extends the launch
/// image's background through bootstrap so the user sees a single
/// continuous green surface until `AppShell` fades in.
struct SuperBibleContentView: View {
    let state: SuperBibleBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .loading:
                Color("SplashBackground")
                    .ignoresSafeArea()
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
