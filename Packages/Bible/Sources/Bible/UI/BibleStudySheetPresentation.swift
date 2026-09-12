import Core
import SwiftUI

struct BibleStudySheetPresentation: ViewModifier {
    let inline: Bool
    let estimatedHeight: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if inline {
            content
        } else {
            content.sheetPresentation(.fitsContent, readableBackground: true, estimatedHeight: estimatedHeight)
        }
    }
}
