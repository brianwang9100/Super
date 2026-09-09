import SwiftUI

enum BibleHighlightWashMotion: Equatable {
    case full
    case reduced

    init(reduceMotion: Bool) {
        self = reduceMotion ? .reduced : .full
    }

    var animation: Animation? {
        switch self {
        case .full: .easeInOut(duration: 0.25)
        case .reduced: nil
        }
    }
}
