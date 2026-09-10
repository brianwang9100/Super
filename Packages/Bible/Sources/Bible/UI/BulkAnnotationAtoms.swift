import Core
import SwiftUI

struct BulkProgressRing<Label: View>: View {
    @Environment(\.superTheme) private var theme

    let value: Double
    let size: CGFloat
    let stroke: CGFloat
    let color: Color?
    @ViewBuilder let label: () -> Label

    init(
        value: Double,
        size: CGFloat = 46,
        stroke: CGFloat = 4,
        color: Color? = nil,
        @ViewBuilder label: @escaping () -> Label = { EmptyView() }
    ) {
        self.value = value
        self.size = size
        self.stroke = stroke
        self.color = color
        self.label = label
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.backgroundSunken, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(color ?? theme.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            label()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// value is 0...1; nil selects indeterminate progress.
struct BulkProgressBar: View {
    @Environment(\.superTheme) private var theme

    let value: Double?
    let height: CGFloat
    let color: Color?

    init(value: Double?, height: CGFloat = 6, color: Color? = nil) {
        self.value = value
        self.height = height
        self.color = color
    }

    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let col = color ?? theme.accent
            ZStack(alignment: .leading) {
                Capsule().fill(theme.backgroundSunken)
                if let value {
                    Capsule()
                        .fill(col)
                        .frame(width: geo.size.width * max(0, min(1, value)))
                        .animation(.easeOut(duration: 0.4), value: value)
                } else {
                    Capsule()
                        .fill(col)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: sweep ? geo.size.width * 1.0 : -geo.size.width * 0.4)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

struct BulkSpinner: View {
    @Environment(\.superTheme) private var theme

    let size: CGFloat
    let stroke: CGFloat

    init(size: CGFloat = 22, stroke: CGFloat = 2.6) {
        self.size = size
        self.stroke = stroke
    }

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(theme.backgroundSunken, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}

struct BulkStatusLeaf: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let state: BulkUnitState
    let size: CGFloat

    init(state: BulkUnitState, size: CGFloat = 22) {
        self.state = state
        self.size = size
    }

    var body: some View {
        switch state {
        case .done:
            AnnotationBubble(state: .filled, size: size)
        case .queued:
            AnnotationBubble(state: .empty, size: size)
        case .generating:
            BulkSpinner(size: size)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(typography.font(size: size - 6, weight: .semibold))
                .foregroundStyle(theme.inkFaint)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(typography.font(size: size - 6, weight: .semibold))
                .foregroundStyle(theme.errorInk)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

struct BulkCheckBox: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    let checked: Bool
    let partial: Bool

    init(checked: Bool, partial: Bool = false) {
        self.checked = checked
        self.partial = partial
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(checked ? theme.accent : .clear)
                .overlay {
                    if !checked {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.inkMute, lineWidth: 1.5)
                    }
                }
                .frame(width: 21, height: 21)
            if checked {
                Image(systemName: "checkmark")
                    .font(typography.font(size: 12, weight: .bold))
                    .foregroundStyle(theme.accentInk)
            } else if partial {
                Capsule().fill(theme.inkMute).frame(width: 9, height: 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AnnotationDoneBadge: View {
    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        HStack(spacing: 4) {
            AnnotationBubble(state: .filled, size: 11)
            Text("DONE")
                .font(typography.mono(9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.accent)
        }
        .accessibilityLabel("Done")
    }
}
