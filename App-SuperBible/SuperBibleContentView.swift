import Core
import SwiftUI

/// SuperBible shell entry view. Switches on the launch state and renders
/// the shared `AppShell` (lifted out of `App/Shell/AppShell.swift`,
/// compiled into both targets via the explicit project.yml file-inclusion
/// list) once the bootstrap is `.ready`.
///
/// `.loading` redraws the `LaunchImage` asset (Star of Bethlehem mark +
/// wordmark) over the same `SplashBackground` field that the system
/// `UILaunchScreen` paints, so the user doesn't see the lockup vanish
/// the instant SwiftUI mounts. `GeometryReader` + `.position` pins the
/// image to the geometric center of the full window — applying
/// `.ignoresSafeArea()` to the overlay alone leaves the image centered
/// inside the safe area instead, which produces a visible vertical jump
/// during the system cross-fade from `UILaunchScreen` to SwiftUI's
/// first frame. Reusing the asset (rather than reconstructing the
/// lockup from `SplashSpark` + `Text`) keeps both surfaces in lockstep
/// when the artwork changes. SuperOS uses the cream-themed `SplashView`
/// instead; the targets diverge here on purpose.
struct SuperBibleContentView: View {
    let state: SuperBibleBootstrapState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch state {
            case .loading:
                GeometryReader { geo in
                    Color("SplashBackground")
                        .overlay(
                            Image("LaunchImage")
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        )
                }
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
