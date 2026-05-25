import Core
import SwiftUI

/// SuperBible shell entry view. Switches on the launch state and renders
/// the shared `AppShell` (lifted out of `App/Shell/AppShell.swift`,
/// compiled into both targets via the explicit project.yml file-inclusion
/// list) once the bootstrap is `.ready`. Loading and failure cases use
/// the same `SplashView` + `FailureScreen` SuperOS does so the two apps'
/// launch sequences feel identical.
struct SuperBibleContentView: View {
    let state: SuperBibleBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .loading:
                SplashView()
                    .superTheme(.make(.light))
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
