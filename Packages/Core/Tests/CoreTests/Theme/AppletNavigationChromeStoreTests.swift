import SwiftUI
import Testing
@testable import Core

@Suite("Applet navigation chrome")
@MainActor
struct AppletNavigationChromeStoreTests {
    @Test func startsWithoutChromeOrReservation() {
        let store = AppletNavigationChromeStore()
        #expect(store.ownerID == nil)
        #expect(store.content == nil)
        #expect(store.measuredHeight == 0)
    }

    @Test func outgoingOwnerCannotClearReplacement() {
        let store = AppletNavigationChromeStore()
        let outgoing = UUID()
        let current = UUID()
        store.install(ownerID: outgoing, content: AnyView(Text("Old")))
        store.install(ownerID: current, content: AnyView(Text("Current")))
        store.measure(height: 112, ownerID: current)
        store.remove(ownerID: outgoing)
        #expect(store.ownerID == current)
        #expect(store.content != nil)
        #expect(store.measuredHeight == 112)
    }

    @Test func outgoingUpdatesCannotReplaceCurrentContentOrMeasurement() {
        let store = AppletNavigationChromeStore()
        let outgoing = UUID()
        let current = UUID()
        store.install(ownerID: outgoing, content: AnyView(Text("Old")))
        store.install(ownerID: current, content: AnyView(Text("Current")))
        store.measure(height: 60, ownerID: current)
        #expect(!store.update(ownerID: outgoing, content: AnyView(Text("Stale"))))
        store.measure(height: 180, ownerID: outgoing)
        #expect(store.ownerID == current)
        #expect(store.measuredHeight == 60)
    }

    @Test func currentContentRefreshKeepsMeasuredReservation() {
        let store = AppletNavigationChromeStore()
        let owner = UUID()
        store.install(ownerID: owner, content: AnyView(Text("Book")))
        store.measure(height: 112, ownerID: owner)
        #expect(store.update(ownerID: owner, content: AnyView(Text("Study"))))
        #expect(store.measuredHeight == 112)
        store.measure(height: 164, ownerID: owner)
        #expect(store.measuredHeight == 164)
    }

    @Test func removingCurrentOwnerReleasesContentAndReservation() {
        let store = AppletNavigationChromeStore()
        let owner = UUID()
        store.install(ownerID: owner, content: AnyView(Text("Navigation")))
        store.measure(height: 112, ownerID: owner)
        store.remove(ownerID: owner)
        #expect(store.ownerID == nil)
        #expect(store.content == nil)
        #expect(store.measuredHeight == 0)
        #expect(!store.update(ownerID: owner, content: AnyView(Text("Late"))))
    }
}
