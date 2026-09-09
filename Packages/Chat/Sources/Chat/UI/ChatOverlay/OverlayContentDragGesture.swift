import SwiftUI

/// Latches the scroll edge at gesture start. Once resizing engages, it owns the
/// gesture through release, including reversals across the starting anchor.
struct OverlayDragArbiter {
    enum ScrollEdge: Equatable {
        case top
        case bottom
    }

    /// Live scroll geometry sampled at the current tick.
    struct ScrollState: Equatable {
        let offsetY: CGFloat
        let topOffsetY: CGFloat
        let bottomOffsetY: CGFloat
        let isScrollable: Bool

        /// Absorbs subpixel resting offsets.
        static let edgeEpsilon: CGFloat = 0.5
        /// Prevents a large rubber-band overscroll from arming an overlay resize.
        static let strandTolerance: CGFloat = 12

        var atTop: Bool {
            offsetY <= topOffsetY + Self.edgeEpsilon
                && offsetY >= topOffsetY - Self.strandTolerance
        }
        var atBottom: Bool {
            offsetY >= bottomOffsetY - Self.edgeEpsilon
                && offsetY <= bottomOffsetY + Self.strandTolerance
        }
    }

    struct Step: Equatable {
        /// Positive collapses, negative expands, and zero leaves control with scrolling.
        let overlayDisplacement: CGFloat
        let pinScroll: Bool
        let pinnedOffsetY: CGFloat
    }

    func step(
        scroll: ScrollState,
        deltaY: CGFloat,
        previousDisplacement: CGFloat,
        engagedEdge: ScrollEdge?,
        armedCollapse: Bool,
        armedExpand: Bool
    ) -> Step {
        // Once engaged, resizing owns reversals through the anchor until release.
        if let engagedEdge {
            let pinnedOffsetY = engagedEdge == .top ? scroll.topOffsetY : scroll.bottomOffsetY
            return Step(
                overlayDisplacement: previousDisplacement + deltaY,
                pinScroll: true,
                pinnedOffsetY: pinnedOffsetY
            )
        }

        // Entering an edge mid-gesture must not steal an active scroll.
        let draggingDown = deltaY > 0
        let draggingUp = deltaY < 0
        if draggingDown && armedCollapse {
            return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: scroll.topOffsetY)
        }
        if draggingUp && armedExpand {
            return Step(overlayDisplacement: deltaY, pinScroll: true, pinnedOffsetY: scroll.bottomOffsetY)
        }
        return Step(overlayDisplacement: 0, pinScroll: false, pinnedOffsetY: scroll.offsetY)
    }
}

/// Projects UIKit's points-per-second velocity onto SwiftUI's end-translation scale.
func overlayDragProjection(velocityY: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
    (velocityY / 1000) * decelerationRate / (1 - decelerationRate)
}

/// Picks the frontmost containing inset frame from top-level frames in back-to-front order.
func frontmostInsetScrollIndex(
    frames: [CGRect],
    containing point: CGPoint,
    windowHeight: CGFloat
) -> Int? {
    for index in frames.indices.reversed() {
        let frame = frames[index]
        if !coversWindowVertically(frame, windowHeight: windowHeight),
           frame.contains(point) {
            return index
        }
    }
    return nil
}

/// Picks the outermost inset frame so nested horizontal panels do not masquerade as the transcript.
func outermostInsetScrollIndex(chainFrames: [CGRect], windowHeight: CGFloat) -> Int? {
    chainFrames.lastIndex { !coversWindowVertically($0, windowHeight: windowHeight) }
}

/// The one-point tolerance absorbs safe-area rounding on the backdrop.
func coversWindowVertically(_ frame: CGRect, windowHeight: CGFloat) -> Bool {
    frame.minY <= 1 && frame.maxY >= windowHeight - 1
}

extension View {
    /// Hands transcript-edge drags to the overlay on UIKit; a reset clears gesture latches.
    func overlayContentDrag(
        canExpand: Bool,
        canCollapse: Bool,
        resetToken: Int,
        onChanged: @escaping (CGSize) -> Void,
        onEnded: @escaping (CGSize, CGSize) -> Void
    ) -> some View {
        #if canImport(UIKit)
        gesture(
            OverlayContentDragGesture(
                onChanged: onChanged,
                onEnded: onEnded,
                canExpand: canExpand,
                canCollapse: canCollapse,
                resetToken: resetToken
            )
        )
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// Arbitrates simultaneous transcript scrolling and overlay resizing from the gesture's starting edge.
struct OverlayContentDragGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize, CGSize) -> Void
    let canExpand: Bool
    let canCollapse: Bool
    let resetToken: Int

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        let coordinator = Coordinator(onChanged: onChanged, onEnded: onEnded)
        coordinator.canExpand = canExpand
        coordinator.canCollapse = canCollapse
        coordinator.resetToken = resetToken
        return coordinator
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // The coordinator persists while these closures capture per-render geometry.
        context.coordinator.canExpand = canExpand
        context.coordinator.canCollapse = canCollapse
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            context.coordinator.reset()
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize, CGSize) -> Void
        private let arbiter = OverlayDragArbiter()

        private weak var scrollView: UIScrollView?
        var canExpand = true
        var canCollapse = true
        var resetToken = 0

        private var displacement: CGFloat = 0
        private var lastTranslationY: CGFloat = 0
        private var didDrive = false
        private var armedCollapse = false
        private var armedExpand = false
        private var engagedEdge: OverlayDragArbiter.ScrollEdge?

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize, CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func reset() {
            displacement = 0
            lastTranslationY = 0
            didDrive = false
            engagedEdge = nil
            armedCollapse = false
            armedExpand = false
        }

        func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                reset()
                scrollView = Self.transcriptScrollView(in: view, at: recognizer.location(in: view))
                // Latch at start so reaching an edge later cannot steal the scroll.
                let start = scrollState()
                armedCollapse = (start.atTop || !start.isScrollable) && canCollapse
                armedExpand = (start.atBottom || !start.isScrollable) && canExpand

            case .changed:
                let translationY = recognizer.translation(in: view).y
                let deltaY = translationY - lastTranslationY
                lastTranslationY = translationY
                let step = arbiter.step(
                    scroll: scrollState(),
                    deltaY: deltaY,
                    previousDisplacement: displacement,
                    engagedEdge: engagedEdge,
                    armedCollapse: armedCollapse,
                    armedExpand: armedExpand
                )
                displacement = step.overlayDisplacement
                if step.pinScroll {
                    if engagedEdge == nil {
                        engagedEdge = displacement > 0 ? .top : .bottom
                    }
                    scrollView?.contentOffset.y = step.pinnedOffsetY
                    didDrive = true
                }
                if didDrive {
                    onChanged(CGSize(width: 0, height: displacement))
                }

            case .ended, .cancelled, .failed:
                if didDrive {
                    let velocityY = recognizer.velocity(in: view).y
                    // A zero displacement leaves momentum with the scroll view.
                    let projected = displacement != 0
                        ? displacement + overlayDragProjection(velocityY: velocityY)
                        : 0
                    onEnded(
                        CGSize(width: 0, height: displacement),
                        CGSize(width: 0, height: projected)
                    )
                }
                reset()

            default:
                break
            }
        }

        /// A missing scroll view is valid for empty chat and makes the overlay drive immediately.
        private func scrollState() -> OverlayDragArbiter.ScrollState {
            guard let scrollView else {
                return .init(offsetY: 0, topOffsetY: 0, bottomOffsetY: 0, isScrollable: false)
            }
            let inset = scrollView.adjustedContentInset
            let topOffsetY = -inset.top
            let bottomOffsetY = max(
                topOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
            )
            return .init(
                offsetY: scrollView.contentOffset.y,
                topOffsetY: topOffsetY,
                bottomOffsetY: bottomOffsetY,
                isScrollable: bottomOffsetY > topOffsetY + OverlayDragArbiter.ScrollState.edgeEpsilon
            )
        }

        /// Resolves by touch location because the root also contains the applet's full-screen scroll view.
        /// The outermost inset ancestor wins; a geometric fallback handles keyboard chrome while
        /// excluding the backdrop and nested panels. Empty chat intentionally returns `nil`.
        static func transcriptScrollView(in view: UIView, at location: CGPoint) -> UIScrollView? {
            let point = view.convert(location, to: nil)
            let windowHeight = view.convert(view.bounds, to: nil).height
            if let hit = view.hitTest(location, with: nil) {
                let chain = enclosingScrollViews(of: hit, stoppingAt: view)
                let chainFrames = chain.map { $0.superview?.convert($0.frame, to: nil) ?? $0.frame }
                if let index = outermostInsetScrollIndex(
                    chainFrames: chainFrames, windowHeight: windowHeight
                ) {
                    return chain[index]
                }
            }
            // Do not descend into scroll views; a nested panel must not outrank its transcript.
            var scrollViews: [UIScrollView] = []
            var frames: [CGRect] = []
            func walk(_ node: UIView) {
                for subview in node.subviews {
                    if let scrollView = subview as? UIScrollView {
                        scrollViews.append(scrollView)
                        frames.append(scrollView.superview?.convert(scrollView.frame, to: nil) ?? scrollView.frame)
                    } else {
                        walk(subview)
                    }
                }
            }
            walk(view)
            guard let index = frontmostInsetScrollIndex(
                frames: frames, containing: point, windowHeight: windowHeight
            ) else { return nil }
            return scrollViews[index]
        }

        private static func enclosingScrollViews(
            of view: UIView, stoppingAt root: UIView
        ) -> [UIScrollView] {
            var found: [UIScrollView] = []
            var node: UIView? = view
            while let current = node {
                if let scrollView = current as? UIScrollView { found.append(scrollView) }
                if current === root { break }
                node = current.superview
            }
            return found
        }

        // MARK: UIGestureRecognizerDelegate

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
