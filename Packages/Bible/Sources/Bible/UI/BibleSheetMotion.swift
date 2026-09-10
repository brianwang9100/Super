import SwiftUI

enum BibleSheetMotion: Equatable {
    case full
    case reduced

    init(reduceMotion: Bool) {
        self = reduceMotion ? .reduced : .full
    }

    var animation: Animation {
        switch self {
        case .full: .snappy(duration: 0.34)
        case .reduced: .easeInOut(duration: 0.2)
        }
    }

    var transition: AnyTransition {
        switch self {
        case .full: .move(edge: .bottom).combined(with: .opacity)
        case .reduced: .opacity
        }
    }
}
