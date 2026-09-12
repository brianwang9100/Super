import Core
import SwiftUI

struct BibleNavigationPill<Content: View>: View {
    let morph: GlassMorphID
    @ViewBuilder let content: Content

    var body: some View {
        NavigationPillLayout {
            // Measure without registering a second glass identity or interactive surface.
            content
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            GeometryReader { geometry in
                let scale = min(1, 44 / geometry.size.height)
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geometry.size.width * scale, height: geometry.size.height * scale,
                           alignment: .topLeading)
                    // Glass must receive the fitted bounds; scaling its compositor shifts the inner controls.
                    .superGlassSurface(in: RoundedRectangle(cornerRadius: 22 * scale), morph: morph)
            }
        }
    }
}

private struct NavigationPillLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let scale = min(1, 44 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}
