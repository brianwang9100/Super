import Foundation
import SwiftUI
import Testing
@testable import Chat

// Accessibility actions must respect the disabled state just like button taps.
@MainActor
@Suite("SettingsToggle commit guard")
struct SettingsToggleTests {
    private final class BoolRef {
        var value: Bool

        init(_ initial: Bool) { self.value = initial }
    }

    @Test("commit no-ops when isEnabled is false")
    func commitNoOpsWhenDisabled() {
        let ref = BoolRef(false)
        let binding = Binding<Bool>(get: { ref.value }, set: { ref.value = $0 })

        SettingsToggle.commit(isOn: binding, isEnabled: false)

        #expect(ref.value == false)
    }

    @Test("commit no-ops when isEnabled is false even if currently on")
    func commitNoOpsWhenDisabledFromOnState() {
        let ref = BoolRef(true)
        let binding = Binding<Bool>(get: { ref.value }, set: { ref.value = $0 })

        SettingsToggle.commit(isOn: binding, isEnabled: false)

        #expect(ref.value == true)
    }

    @Test("commit flips the binding when isEnabled is true")
    func commitFlipsWhenEnabled() {
        let ref = BoolRef(false)
        let binding = Binding<Bool>(get: { ref.value }, set: { ref.value = $0 })

        SettingsToggle.commit(isOn: binding, isEnabled: true)

        #expect(ref.value == true)
    }

    @Test("commit flips back from on to off when isEnabled is true")
    func commitFlipsFromOnWhenEnabled() {
        let ref = BoolRef(true)
        let binding = Binding<Bool>(get: { ref.value }, set: { ref.value = $0 })

        SettingsToggle.commit(isOn: binding, isEnabled: true)

        #expect(ref.value == false)
    }
}
