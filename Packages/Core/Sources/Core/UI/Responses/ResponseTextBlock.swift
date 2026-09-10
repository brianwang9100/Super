import SwiftUI

public struct ResponseTextBlock: View {
    private let text: String
    private let treatAsPartial: Bool
    private let isWorking: Bool

    /// Hosts supply Markdown metrics and link routing through the environment.
    public init(text: String, treatAsPartial: Bool = false, isWorking: Bool = false) {
        self.text = text
        self.treatAsPartial = treatAsPartial
        self.isWorking = isWorking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !text.isEmpty {
                MarkdownText(text, treatAsPartial: treatAsPartial)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isWorking {
                WaitingSpark()
            }
        }
    }
}
