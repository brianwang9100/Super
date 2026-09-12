import Core
import SwiftUI

struct BibleReadingLayout: Equatable {
    var isPadWorkspace = false
    static let legacy = Self()
    var bodySize: CGFloat { isPadWorkspace ? 24 : 19 }
    var scriptureScale: CGFloat { bodySize / 19 }
    var maximumWidth: CGFloat { isPadWorkspace ? .infinity : SuperContentLayout.maximumColumnWidth }

    func contentWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, min(availableWidth, maximumWidth) - 52)
    }

    static func bottomClearance(measuredBarHeight: CGFloat, safeAreaReserved: Bool) -> CGFloat {
        safeAreaReserved ? 0 : max(0, measuredBarHeight)
    }
}

private struct BibleReadingLayoutKey: EnvironmentKey {
    static let defaultValue = BibleReadingLayout.legacy
}

extension EnvironmentValues {
    var bibleReadingLayout: BibleReadingLayout {
        get { self[BibleReadingLayoutKey.self] }
        set { self[BibleReadingLayoutKey.self] = newValue }
    }
}
