import Core
import SwiftUI

/// SuperBible shell entry view.
///
/// SB-M0 stub: switches on the launch state and renders the active applet's
/// `rootView()` directly in the ready case. SB-M1 replaces this with a
/// proper shell (sidebar + chat overlay + settings sheet) modeled on
/// SuperOS's `AppShell`.
struct SuperBibleContentView: View {
    let state: SuperBibleBootstrapState

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let dependencies):
            if let active = dependencies.appletRegistry.activeApplet {
                active.rootView()
            } else {
                emptyState
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text("SuperBible failed to launch")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("SuperBible")
                .font(.largeTitle)
            Text("No applets registered.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
