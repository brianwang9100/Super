import Testing
import Todo

/// Smoke test for the Todo module identifier.
@Suite("Todo module")
struct TodoTests {
    @Test func appletIDIsStable() {
        #expect(TodoModule.appletID == "todo")
    }
}
