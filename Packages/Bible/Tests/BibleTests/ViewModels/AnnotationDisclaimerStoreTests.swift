import Foundation
import Testing
@testable import Bible

/// Tests for `UserDefaultsAnnotationDisclaimerStore` — the injectable
/// flag wrapper that gates the first-run liability sheet. Each test
/// uses a freshly-suited `UserDefaults` so the production
/// `bible.annotations.disclaimerAcknowledged` key on `.standard` is
/// never touched.
@Suite("UserDefaultsAnnotationDisclaimerStore")
struct UserDefaultsAnnotationDisclaimerStoreTests {
    private func makeStore(_ id: String = UUID().uuidString)
        -> (UserDefaultsAnnotationDisclaimerStore, UserDefaults) {
        let suiteName = "BibleAnnotationsTests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (UserDefaultsAnnotationDisclaimerStore(defaults: defaults), defaults)
    }

    @Test("a fresh defaults reports the disclaimer as unacknowledged")
    func defaultIsUnacknowledged() {
        let (store, _) = makeStore()
        #expect(store.isAcknowledged == false)
    }

    @Test("setAcknowledged(true) persists across a fresh wrapper over the same defaults")
    func roundTripTrue() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.setAcknowledged(true)
        #expect(store.isAcknowledged == true)

        let revived = UserDefaultsAnnotationDisclaimerStore(defaults: defaults)
        #expect(revived.isAcknowledged == true)
    }

    @Test("setAcknowledged(false) clears a prior true")
    func clearsBackToFalse() {
        let (store, _) = makeStore()
        store.setAcknowledged(true)
        store.setAcknowledged(false)
        #expect(store.isAcknowledged == false)
    }
}
