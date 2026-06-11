import SwiftUI

/// A mini-app the shell can host. The shell owns the chat surface and overlays
/// it on top of whichever `MiniApplet` is currently active; the applet itself
/// only declares display metadata and provides a SwiftUI `rootView` rendered
/// behind the chat overlay.
///
/// This is the minimal slice in [`docs/DESIGN.md` §3.1](../../../docs/DESIGN.md).
/// The doc draft includes additional members for chat-tool registration,
/// chat-card renderers, record-action handlers, the event bus, and lifecycle
/// hooks; those land as those subsystems are built — keeping the protocol lean
/// here lets applet authors conform with zero ceremony today.
///
/// Conformance must be `Sendable` so the shell can hold an applet across
/// concurrent contexts (registry mutation, sidebar refresh, sheet
/// presentation). Display-metadata members are stateless by design — anything
/// stateful belongs inside the applet's own view models, not on the
/// conformance type itself.
@MainActor
public protocol MiniApplet: Sendable {
    /// Returned for `id` on the conformance instance. Stable, lowercase,
    /// dash-free — used for routing, settings keys, and deep-link URIs
    /// (`super://<appletID>/<recordID>`). Conformances typically expose a
    /// `static let appletID` and return it from the instance property; the
    /// shell only reads the instance member.
    var appletID: String { get }

    /// Human-readable label rendered in the sidebar applet rail and in the
    /// chat title region when the applet is active.
    var displayName: String { get }

    /// Glyph rendered in the sidebar applet rail. Returned as an opaque
    /// `AnyView` so individual applets can supply hand-stroked `Shape`-based
    /// icons without forcing every conformance through a single `Image`
    /// shape — see the in-tree `TodoIcon` / `RecipeIcon` / etc.
    func iconView(size: CGFloat) -> AnyView

    /// Secondary brand color used for the applet's iconography and chat-card
    /// accent strips. Per `docs/DESIGN.md §8.2` these are muted OKLCH-shifted
    /// derivatives of the pastel-green palette, not raw bright colors.
    var accentColor: Color { get }

    /// The SwiftUI view the shell embeds behind the chat overlay when this
    /// applet is active. Returned as `AnyView` so conformances can lazily
    /// construct view models without parameterizing the protocol.
    func rootView() -> AnyView

    /// Markdown text the Chat Large Language Model (LLM) sees as one block
    /// in the leading system message. Loaded from the applet's own
    /// Swift Package Manager (SPM) bundle — conventionally a one-liner
    /// returning `AppletSystemPrompt.load(from: .module)`, which reads
    /// `Resources/SystemPrompt.md`. Return `""` (or omit the file) for an
    /// applet that has no behavioral guidance yet — the registry drops
    /// empty bodies, so no block is injected in that case.
    var systemPrompt: String { get }

    /// Short variant of `systemPrompt` for small-context-window models
    /// (`ModelContextTier.compact`), keeping only the behavior-critical rules.
    /// Conventionally loads `Resources/SystemPrompt.compact.md` via
    /// `AppletSystemPrompt.load(from: .module, resource:)`. Defaults to
    /// `systemPrompt`, so applets without a compact variant send their full
    /// briefing on every tier.
    var compactSystemPrompt: String { get }

    /// Ready-made chat prompts this applet contributes to the chat empty state.
    /// The shell aggregates these across the registered applet set (see
    /// `SuggestedChatAction.merged`), so each target surfaces only the actions
    /// for the applets it ships. Defaults to `[]`; applets with no actions
    /// inherit it.
    var suggestedChatActions: [SuggestedChatAction] { get }
}

public extension MiniApplet {
    /// Applets contribute no chat actions by default; Bible and Todo override.
    var suggestedChatActions: [SuggestedChatAction] { [] }

    /// No compact variant by default — small-window models get the full
    /// briefing.
    var compactSystemPrompt: String { systemPrompt }
}
