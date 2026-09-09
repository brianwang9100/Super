import SwiftUI

public struct ChatDragHandle: View {
    public enum Tone: Sendable, Equatable {
        case resting
        case active
    }

    public let restingTone: Tone

    /// Nil disables drag-change handling.
    public let onDragChanged: ((_ translation: CGSize) -> Void)?

    /// Predicted translation is SwiftUI's velocity proxy; nil disables drag-end handling.
    public let onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)?

    public init(
        restingTone: Tone = .resting,
        onDragChanged: ((_ translation: CGSize) -> Void)? = nil,
        onDragEnded: ((_ translation: CGSize, _ predictedEndTranslation: CGSize) -> Void)? = nil
    ) {
        self.restingTone = restingTone
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    @Environment(\.superTheme) private var theme

    @State private var isDragging: Bool = false

    public var body: some View {
        VStack {
            Capsule(style: .continuous)
                .fill(fillColor)
                .frame(width: 36, height: 4.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // Extend the hit target across the strip beyond the visible pill.
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Chat drag handle")
        .accessibilityHint("Drag to expand or collapse the chat")
    }

    private var fillColor: Color {
        let effective: Tone = isDragging ? .active : restingTone
        switch effective {
        case .resting:
            return theme.inkSoft.opacity(0.55)
        case .active:
            return theme.inkFaint.opacity(0.70)
        }
    }

    /// Use global coordinates: local translation feeds back through the moving handle
    /// and makes the surface track at half finger speed. The parent resolves taps and drags.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging { isDragging = true }
                onDragChanged?(value.translation)
            }
            .onEnded { value in
                isDragging = false
                onDragEnded?(value.translation, value.predictedEndTranslation)
            }
    }
}
