import Core
import SwiftUI

/// Brief confirmation pill shown after a mutation (the design's `flash()`).
/// `TodoScreen` schedules its own dismissal; this view is purely visual.
struct TodoToast: View {
    let text: String

    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15
    @Environment(\.superTypography) private var typography

    var body: some View {
        Text(text)
            .font(typography.font(size: fontSize))
            // Intentionally theme-independent: like a system HUD toast, the
            // confirmation pill is a fixed near-black capsule with white text
            // in every theme, so it reads identically as a transient overlay
            // over any backdrop. Not routed through `SuperTheme` by design.
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.92))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}
