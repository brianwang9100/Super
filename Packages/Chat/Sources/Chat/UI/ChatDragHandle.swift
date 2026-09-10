import SwiftUI

public struct ChatDragHandle: View {
    static let barWidth: CGFloat = 36
    static let barHeight: CGFloat = 4.5

    static var barShape: Capsule { Capsule(style: .continuous) }

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
            Self.barShape
                .fill(fillColor)
                .frame(width: Self.barWidth, height: Self.barHeight)
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

    private var dragGesture: some Gesture {
        Self.resizeGesture()
            .onChanged { value in
                if !isDragging { isDragging = true }
                onDragChanged?(value.translation)
            }
            .onEnded { value in
                isDragging = false
                onDragEnded?(value.translation, value.predictedEndTranslation)
            }
    }

    /// Local coordinates feed back through the moving handle and halve finger tracking speed.
    /// Both handles therefore report screen-space displacement.
    static func resizeGesture(minimumDistance: CGFloat = 0) -> DragGesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
    }
}
