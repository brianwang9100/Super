import Testing
@testable import Core

@Suite("Applet workspace presentation")
@MainActor
struct AppletWorkspaceStoreTests {
    @Test func defaultsToSingleSurface() {
        let store = AppletWorkspaceStore()
        store.updateAvailableWidth(1400, textScale: 1)
        #expect(!store.isCompanionPresented)
    }

    @Test func compactWindowRetainsRequestAndRestoresCompanion() {
        let store = AppletWorkspaceStore()
        store.requestedPresentation = .companion
        store.updateAvailableWidth(812, textScale: 1)
        #expect(store.isCompanionPresented)
        store.updateAvailableWidth(811, textScale: 1)
        #expect(!store.isCompanionPresented)
        #expect(store.requestedPresentation == .companion)
        store.updateAvailableWidth(1000, textScale: 1)
        #expect(store.isCompanionPresented)
    }

    @Test func largerTextRequiresReadablePaneWidths() {
        #expect(!AppletWorkspaceStore.supportsCompanion(width: 1000, textScale: 1.5))
        #expect(AppletWorkspaceStore.supportsCompanion(width: 1182, textScale: 1.5))
        #expect(!AppletWorkspaceStore.supportsCompanion(width: 811, textScale: 0.8))
    }
}
