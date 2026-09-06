import SwiftUI

/// One hovering accessory button shown beside the chat composer pill. A pure
/// *data* descriptor (naming Part 4 Rule 3): the caller supplies the glyph, an
/// enabled flag, and an action — the chat composer owns the glass chrome, size,
/// and placement. The content is an SF Symbol name (not a `View`) because this
/// value is stored in a shell-owned ``ComposerAccessoryStore`` and read across a
/// disjoint view tree (a backdrop applet writes it; the chat overlay reads it),
/// so it must be a plain carryable value rather than a view.
///
/// Despite the word "Button", this is not a `*Button` *view* — it carries no
/// `: View`. It exists so an applet can hand generic flank controls (e.g. the
/// Bible reader's previous / next chapter chevrons) to the composer without the
/// applet's domain logic leaking into Chat.
public struct ComposerAccessoryButton {
    /// SF Symbol rendered inside the composer's circular glass button (e.g.
    /// `"chevron.left"`). The renderer applies the theme font / ink and glass.
    public let systemImage: String
    /// VoiceOver label for the button (e.g. "Previous chapter"). Required —
    /// every interactive element carries one.
    public let accessibilityLabel: String
    /// `false` dims the button to 0.35 and disables it. Updates live as the
    /// caller mutates the store.
    public let isEnabled: Bool
    /// Fired on tap.
    public let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// The leading / trailing pair of hovering accessory buttons for the chat
/// composer — leading pinned to the left screen edge, trailing to the right.
/// Either side may be `nil` (nothing renders on that edge), with optional
/// selection controls in the center. An empty configuration (``none``) renders
/// no accessory row, so a target that supplies none is visually unchanged.
public struct ComposerAccessoryButtons {
    public let leading: ComposerAccessoryButton?
    public let trailing: ComposerAccessoryButton?
    /// Optional selection controls centered between the two edge buttons.
    public let selection: ComposerAccessorySelection?
    /// Dynamic suppression predicate. When it returns `true`, the renderer fades
    /// the whole accessory row out even though the buttons are present — e.g. the
    /// Bible reader hides the hovering chevrons once its own previous/next
    /// chapter footer cards scroll into view. `nil` (the default) never hides.
    ///
    /// Evaluated inside the rendering view's body, so a closure that reads the
    /// publishing applet's `@Observable` state stays reactive: SwiftUI's
    /// Observation tracking records the read and re-renders when the state flips,
    /// so the applet publishes this once rather than republishing on every change.
    public let shouldHide: (() -> Bool)?

    public init(
        leading: ComposerAccessoryButton? = nil,
        trailing: ComposerAccessoryButton? = nil,
        selection: ComposerAccessorySelection? = nil,
        shouldHide: (() -> Bool)? = nil
    ) {
        self.leading = leading
        self.trailing = trailing
        self.selection = selection
        self.shouldHide = shouldHide
    }

    /// The empty pair — nothing renders. The default everywhere a caller opts
    /// out (SuperOS, snapshot fixtures, previews). Computed (not a stored
    /// `static let`) because the descriptors hold non-`Sendable` action
    /// closures, so a stored global would trip strict-concurrency checking;
    /// the empty pair is trivially cheap to rebuild.
    public static var none: ComposerAccessoryButtons { ComposerAccessoryButtons() }

    /// True when neither edge nor center has a control — the renderer skips the row.
    public var isEmpty: Bool { leading == nil && trailing == nil && selection == nil }
}

/// Shell-owned, app-session-lived holder for the chat composer's optional
/// hovering accessory buttons. The shell owns it, a backdrop applet (today the
/// Bible reader) fills it, and the chat overlay reads it — so an applet's flank
/// controls can render beside the composer pill without the applet's domain
/// logic bleeding into Chat. Injected via ``EnvironmentValues/composerAccessoryStore``
/// from a common ancestor so both the writing applet (a child of the backdrop)
/// and the reading composer layer (a sibling) share one instance; the event bus
/// can't carry the live action closures and a sibling can't read an applet's
/// environment, so a shared reference is the seam.
///
/// Created only by the target that wants the behavior (SuperBible); a target
/// that never injects one leaves the environment value `nil`, so the composer
/// renders no accessory row.
@MainActor
@Observable
public final class ComposerAccessoryStore {
    /// The current edge buttons and optional center selection. The backdrop applet
    /// writes this when navigation or selection changes; the composer layer reads
    /// it and re-renders. ``ComposerAccessoryButtons/none``
    /// until a caller fills it.
    public var buttons: ComposerAccessoryButtons = .none

    public init() {}
}

/// SwiftUI environment plumbing — only the `\.composerAccessoryStore` accessor
/// and `View.composerAccessoryStore(_:)` modifier are public; the key stays
/// internal so it isn't re-exported as API surface. Defaults to `nil` so a
/// target that injects nothing renders no accessory row.
struct ComposerAccessoryStoreKey: EnvironmentKey {
    static let defaultValue: ComposerAccessoryStore? = nil
}

public extension EnvironmentValues {
    var composerAccessoryStore: ComposerAccessoryStore? {
        get { self[ComposerAccessoryStoreKey.self] }
        set { self[ComposerAccessoryStoreKey.self] = newValue }
    }
}

public extension View {
    /// Inject the shared ``ComposerAccessoryStore`` into this subtree so a
    /// backdrop applet can publish composer flank controls and the composer
    /// layer can read them. Pass `nil` (or omit injection) on targets that
    /// don't want the behavior.
    func composerAccessoryStore(_ store: ComposerAccessoryStore?) -> some View {
        environment(\.composerAccessoryStore, store)
    }
}
