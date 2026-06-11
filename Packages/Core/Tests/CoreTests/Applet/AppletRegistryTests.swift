import Foundation
import SwiftUI
import Testing
@testable import Core

/// Tests for `AppletRegistry.resolvedBriefings()` — applet-prompt fan-in
/// for the Chat leading-system-message stack.
@Suite("AppletRegistry")
@MainActor
struct AppletRegistryTests {
    @Test("resolvedBriefings sorts by appletID, not display name or input order")
    func sortsByAppletID() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "todo", displayName: "Todo", prompt: "todo rules"),
            FakeApplet(appletID: "bible", displayName: "Bible", prompt: "bible rules"),
            FakeApplet(appletID: "finance", displayName: "Finance", prompt: "finance rules"),
        ])
        let briefings = registry.resolvedBriefings()
        #expect(briefings.map(\.label) == [
            "Bible applet",
            "Finance applet",
            "Todo applet",
        ])
    }

    @Test("Empty or whitespace-only prompts are skipped")
    func skipsEmptyBodies() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "a", displayName: "A", prompt: "real"),
            FakeApplet(appletID: "b", displayName: "B", prompt: ""),
            FakeApplet(appletID: "c", displayName: "C", prompt: "   \n  "),
        ])
        let labels = registry.resolvedBriefings().map(\.label)
        #expect(labels == ["A applet"])
    }

    @Test("Bodies are trimmed of surrounding whitespace")
    func trimsBody() {
        let registry = AppletRegistry(applets: [
            FakeApplet(
                appletID: "todo",
                displayName: "Todo",
                prompt: "\n\n  Use ISO-8601 due dates.  \n\n"
            ),
        ])
        let body = registry.resolvedBriefings().first?.body
        #expect(body == "Use ISO-8601 due dates.")
    }

    @Test("Label is displayName + ' applet'")
    func labelFormat() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "x", displayName: "ToDo List", prompt: "rules"),
        ])
        #expect(registry.resolvedBriefings().first?.label == "ToDo List applet")
    }

    @Test("Returns empty array when no applets contribute prompts")
    func emptyWhenAllSkipped() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "a", displayName: "A", prompt: ""),
            FakeApplet(appletID: "b", displayName: "B", prompt: "  "),
        ])
        #expect(registry.resolvedBriefings().isEmpty)
    }

    @Test("Briefings carry the contributing applet's id")
    func carriesAppletID() {
        let registry = AppletRegistry(applets: [
            FakeApplet(appletID: "bible", displayName: "Bible", prompt: "bible rules"),
        ])
        #expect(registry.resolvedBriefings().first?.appletID == "bible")
    }

    @Test("Compact body is the trimmed compactSystemPrompt when the applet authors one")
    func compactBodyFromCompactPrompt() {
        let registry = AppletRegistry(applets: [
            FakeApplet(
                appletID: "bible",
                displayName: "Bible",
                prompt: "full rules",
                compactPrompt: "\n lean rules \n"
            ),
        ])
        let briefing = registry.resolvedBriefings().first
        #expect(briefing?.body == "full rules")
        #expect(briefing?.compactBody == "lean rules")
    }

    @Test("Compact body falls back to the full body when no compact variant exists")
    func compactBodyFallsBackToBody() {
        // `DefaultCompactApplet` omits `compactSystemPrompt` entirely,
        // exercising the `MiniApplet` default extension
        // (compactSystemPrompt == systemPrompt); the whitespace-only case
        // exercises the registry's own empty-compact fallback.
        let registry = AppletRegistry(applets: [
            DefaultCompactApplet(appletID: "a", displayName: "A", prompt: "full rules"),
            FakeApplet(appletID: "b", displayName: "B", prompt: "b rules", compactPrompt: "   \n"),
        ])
        let briefings = registry.resolvedBriefings()
        #expect(briefings.map(\.compactBody) == ["full rules", "b rules"])
    }
}

/// Tests for `AppletRegistry.resolveActiveID(applets:storedID:fallbackID:)` —
/// the cold-start backdrop resolution. Pins the invariant that the fallback is
/// independent of the applets array order, so the sidebar rail can lead with
/// any applet (Chats, in SuperOS) without moving the fresh-install landing
/// surface (Todo).
@Suite("AppletRegistry.resolveActiveID")
@MainActor
struct ResolveActiveIDTests {
    private let applets: [any MiniApplet] = [
        FakeApplet(appletID: "chats", displayName: "Chats", prompt: ""),
        FakeApplet(appletID: "todo", displayName: "Todo", prompt: ""),
        FakeApplet(appletID: "bible", displayName: "Bible", prompt: ""),
    ]

    @Test("Persisted id is honored when it still matches a registered applet")
    func honorsStoredID() {
        let resolved = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: "bible",
            fallbackID: "todo"
        )
        #expect(resolved == "bible")
    }

    @Test("Fresh install (nil stored id) resolves to the explicit fallback, not applets.first")
    func freshInstallUsesFallback() {
        let resolved = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: nil,
            fallbackID: "todo"
        )
        // The decoupling guard: applets.first is "chats", but a fresh install
        // must land on the explicit fallback "todo".
        #expect(resolved == "todo")
        #expect(resolved != applets.first?.appletID)
    }

    @Test("Stale persisted id (no longer registered) falls back to the default")
    func staleStoredIDFallsBack() {
        let resolved = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: "recipes", // not in `applets`
            fallbackID: "todo"
        )
        #expect(resolved == "todo")
    }

    @Test("Fallback is returned verbatim even when it isn't a registered applet")
    func unregisteredFallbackReturnedVerbatim() {
        // Pins the documented contract: the helper does NOT chain an
        // unregistered fallback to applets.first — it returns the caller's
        // fallback as-is. (Production always passes a registered id.)
        let resolved = AppletRegistry.resolveActiveID(
            applets: applets,
            storedID: nil,
            fallbackID: "ghost"
        )
        #expect(resolved == "ghost")
    }
}

/// Bare-bones test conformance — only the fields touched by
/// `resolvedBriefings()` carry meaning; the rest exist to satisfy the
/// protocol.
@MainActor
private struct FakeApplet: MiniApplet {
    let appletID: String
    let displayName: String
    let prompt: String
    /// `nil` leans on the `MiniApplet` default extension
    /// (`compactSystemPrompt == systemPrompt`).
    var compactPrompt: String?

    var accentColor: Color { .gray }
    var systemPrompt: String { prompt }
    var compactSystemPrompt: String { compactPrompt ?? prompt }

    func iconView(size: CGFloat) -> AnyView { AnyView(EmptyView()) }
    func rootView() -> AnyView { AnyView(EmptyView()) }
}

/// Deliberately does NOT declare `compactSystemPrompt`, so it resolves
/// through the `MiniApplet` protocol default extension.
@MainActor
private struct DefaultCompactApplet: MiniApplet {
    let appletID: String
    let displayName: String
    let prompt: String

    var accentColor: Color { .gray }
    var systemPrompt: String { prompt }

    func iconView(size: CGFloat) -> AnyView { AnyView(EmptyView()) }
    func rootView() -> AnyView { AnyView(EmptyView()) }
}
