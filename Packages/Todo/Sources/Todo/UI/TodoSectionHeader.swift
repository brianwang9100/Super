import Core
import SwiftUI

/// Small uppercase group header with a monospace count chip. Rendered above
/// each grouped section of the task list. Mirrors `SectionHeader` in the
/// Todo design source's `components.jsx`.
public struct TodoSectionHeader: View {
    public let title: String
    public let count: Int

    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 10
    @Environment(\.superTheme) private var theme

    public init(title: String, count: Int) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(theme.inkFaint)
            Text("\(count)")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(theme.inkMute)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}
