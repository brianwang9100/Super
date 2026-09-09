import Testing
@testable import Core

struct ComposerAccessoryTests {
    @Test func emptyRowHasNoControls() {
        #expect(ComposerAccessoryButtons.none.isEmpty)
    }

    @Test func selectionKeepsRowPresentWithoutEdgeButtons() {
        let selection = ComposerAccessorySelection(
            title: "Selected items",
            accessibilityLabel: "Show selection actions",
            onExpand: {},
            onClear: {}
        )
        #expect(!ComposerAccessoryButtons(selection: selection).isEmpty)
    }
}
