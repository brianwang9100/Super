# Chat: SwiftUI Naming Conventions

> The taxonomy an agent or developer applies when naming a new SwiftUI view in the Chat applet. Pick the bucket; the suffix follows. If nothing fits, treat that as a smell and stop to add a new bucket here before coining a one-off name.
>
> Companion: [`UI_STRUCTURE.md`](./UI_STRUCTURE.md) — what view owns what, organized by surface. Read that for the org chart; this doc is the rulebook.

---

## Rule 0 — drop the `View` suffix

Apple's standard-library views (`Text`, `Button`, `VStack`) are bare nouns; ours should be too. Apply `View` only when the bare name collides with a model/protocol — and if you hit that, rename the model instead. A view's `View`-ness is already declared by `: View` on the struct.

## Rule 1 — pick a bucket, use its suffix

Every new SwiftUI view fits into one of these buckets. The bucket determines the suffix.

| Bucket | Suffix | What it is | Existing examples |
|---|---|---|---|
| **Screen** | `*Screen` | Full-viewport top-level surface owned by the host. Has a `*ScreenViewModel`. | `ChatScreen`, `LoadingScreen`, `FailureScreen` |
| **Drawer** | `*Drawer` | Edge-anchored overlay that slides in from a side. Paints its own scrim. | `SidebarDrawer` |
| **Sheet** | `*Sheet` | Bottom-anchored modal overlay with rounded top corners. | `SettingsSheet` |
| **Pane** | `*Pane` | Sub-screen content navigated *within* a Sheet/Screen via `NavigationStack`. | `SettingsRootPane`, `SettingsModelsPane`, … |
| **Region** | bare | Composed strip inside a Screen/Pane. Name *is* the role. | `ChatHeader`, `ChatComposer`, `ChatComposerFooter` |
| **Pill** | `*Pill` | Small inline rounded control, often a dropdown trigger. | `ModelPill`, `VerbosityPill` |
| **Meter** | `*Meter` | Progress/measurement indicator. | `ContextMeter` |
| **Row** | `*Row` | One item in a vertical list. | `SettingsRow`, `ChatRow` |
| **Bubble** | `*Bubble` | Chat-bubble-shaped message container. | `UserBubble` |
| **Block** | `*Block` | Collapsible bordered card with header + body. | `ThinkingBlock`, `ToolCallBlock`, `CodeBlock` |
| **Banner** | `*Banner` | Full-width status strip. | `ErrorBanner`, `CompactionBanner` |
| **Group** | `*Group` | Rounded card grouping rows. | `SettingsGroup` |
| **Toggle** | `*Toggle` | Labeled switch. | `SettingsToggle` |
| **Button** | `*Button` | Custom-shaped button (when system `Button` isn't enough). | `MessageActionButton` |
| **Icon** | `*Icon` | Atomic glyph. | `TodoIcon`, `SettingsIcon`, `ModelsIcon`, `CloseIcon` |
| **Primitive** | bare | Single-purpose visual atom that doesn't fit a shape suffix. | `TypingCaret`, `WaitingSpark`, `SpinnerRing` |
| **Style** | `*Style` | `ButtonStyle` / `LabelStyle` / `ProgressViewStyle` conformer. | `SidebarPressableRowStyle` |
| **Modifier** | `*Modifier` | `ViewModifier` conformer. | `HiddenNavigationBarModifier` |

## Rule 2 — one struct per file (with one carve-out)

Each top-level view, region, component, and primitive lives in its own file named after the struct. The carve-out: a parent file may keep `private` helper structs *only* if (a) they have no callers outside the file and (b) they're <40 lines. `SidebarDrawer.swift` keeps `SpinnerRing` and `SidebarPressableRowStyle` under that rule.

## Rule 3 — data passed to a view ≠ the view

When a view needs a state struct/enum as input, name the data by *role* (`*State`, `*Item`, `*Config`), never by *shape*. The view owns `Banner`; the data is `BannerState`. The in-tree examples: `MessageList.StreamingState` is the data; `StreamingTail` is the view. `MessageList.ErrorState` is the data; `ErrorBanner` is the view. `MessageList.Item` and `MessageList.ToolCallItem` carry the projected row payloads consumed by `MessageList` itself.

## Rule 4 — view models

`@Observable @MainActor final class *ViewModel`. Backing a Screen → `*ScreenViewModel`. Backing a Drawer/Sheet/Pane → `*ViewModel` (no shape suffix on the VM; the VM doesn't know which shape will render it).

---

## Invariants

After applying this taxonomy, the following greps must return zero hits over `Packages/Chat/Sources/`:

- `rg '\bstruct \w+View\s*:'` — no `View`-suffixed view structs
- `rg '\bstruct \w+Glyph\s*:'` — no `Glyph`-suffixed icon views; the generic `StrokedGlyph<S: Shape>` rendering wrapper is the one intentional exception.

---

*Last updated: 2026-05-11*
