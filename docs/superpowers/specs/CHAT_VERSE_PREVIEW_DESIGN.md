# Chat verse preview design

Date: 2026-09-08  
Status: Approved by user and two independent plan reviewers; implementation underway

## Intended behavior

Tapping a Bible citation in the Chat transcript opens a native, large-detent
chapter sheet above Chat. It loads the complete chapter in the reader's current
translation, selects the cited verse or range, and scrolls the first selected
verse into view. Chapter-only citations open at the top without a selection.

The header uses `SheetNavBar`: its existing leading X cancels the preview, the
center shows the chapter with a static translation subtitle, and its 44-point
trailing slot contains `arrow.up.right.square`, labeled and hinted as
"Open in Bible". The sheet contains no translation picker, book picker, chapter
arrows (including the footer), narration controls, spark menu, or shell composer
accessories. The chapter and translation are fixed for that presentation.

The selected verses use the existing selection treatment. The existing verse
action sheet opens above the chapter sheet after the chapter presenter is ready.
Readiness is a one-shot native presentation-completion signal latched per preview
ID, not SwiftUI `.onAppear` or a sleep. A small UIKit representable observes
`viewDidAppear` and, if a transition is still active, its successful completion;
it emits nothing after cancellation/unmounting. All sheets still use SwiftUI
`.sheet`. Apple documents presentation completion relative to
[`viewDidAppear`](https://developer.apple.com/documentation/uikit/uiviewcontroller/present(_:animated:completion:))
and exposes an ancestor's active
[transition coordinator](https://developer.apple.com/documentation/uikit/uiviewcontroller/transitioncoordinator).
Its readable-background behavior keeps the chapter interactive. Tapping selected
verses deselects them; tapping other verses changes the selection using the
reader's existing multiple-selection behavior. Empty selection dismisses actions.
Closing actions retains selection. A small selection citation control below the
header reopens actions and includes the existing clear-selection affordance; this
avoids stranding actions after their close button is used. This control provides
selection management only, never chapter navigation.

Preserve the existing action sheet's Highlight, Clear highlight, Copy, Share,
Annotate, Add note, Add to chat, and New chat actions. Notes, annotations, and
bookmarks use their existing secondary sheets above the preview. Note editors
keep their existing save/cancel semantics. Generation disclaimers remain intact.
Annotation markdown inside the preview renders Bible citations as noninteractive
text so it cannot navigate to a different chapter; external web links retain
their normal behavior. Full Bible keeps its existing annotation-link navigation.
Add a scoped Core markdown citation policy, defaulting to the existing enabled
behavior. In the preview, skip automatic Bible linkification and unwrap existing
Bible-scheme link nodes to their inline label content, including reference-style
links. Preserve external link nodes and code blocks. Apply this at the renderer
so disabled citations have neither link styling nor accessibility link traits;
URL interception remains a defensive guard, not the implementation of inert text.

Cancel or interactive dismissal discards the preview's chapter/selection/scroll
state. It does not revert deliberate persisted edits. The underlying Bible
position, translation, selection, narration, active applet, Chat transcript,
composer draft, and Chat expansion state remain unchanged by previewing or
cancelling. Opening a preview resigns composer focus so the keyboard does not
compete with the sheet; dismissal does not automatically summon the keyboard.

"Open in Bible" dismisses the entire preview stack and then follows the existing
`openRecord` route to the displayed chapter. It uses the current selection, not
the original citation, preserving its exact verse set and captured translation;
an empty selection opens the chapter without selection. Add a Bible-owned
`BibleReaderReference` codec for this internal handoff, using generic
`RecordReference(kind: "readerPosition")` with a validated versioned payload in
`sourceID`: `v1/<translation>/<book>/<chapter>[/<sorted-comma-separated-verses>]`.
`BibleReferenceInbox` accepts this format alongside its existing `BibleDeepLink`
path. Public URL parsing/emission and Chat attachment payloads remain unchanged.
Do not pass `makeVerseReference()` to the deep-link parser: its attachment grammar
is different. Add to chat and New chat likewise dismiss the stack before
publishing their existing events.

External `super://bible/...` URLs continue to open full Bible directly. Composer
and sent-message reference pills are currently read-only/removable, not deep
links; changing those interaction contracts is outside this feature.

## Current implementation and pressure points

- `Chat/UI/BibleDeepLinkRouting.swift` currently publishes `.openRecord` for
  transcript links. Both `AppShell` and `BibleReferenceInbox` consume it, changing
  the backdrop and the app-lifetime reader simultaneously.
- `BibleChapterReader` already owns text layout, verse hit testing, scroll
  anchoring, and reactive GRDBQuery decorations. It also hardcodes full-reader
  top/bottom clearance and always constructs a chapter-navigation footer.
- `BibleScreen` (714 lines at planning time) mixes full-reader chrome, composer
  accessories, common study sheets, and cross-sheet handoffs.
- `BibleScreenViewModel` (1,510 lines) already has injectable repositories and
  supports no position persistence when `positionRepository` is nil. Reusing its
  app-lifetime instance would mutate the reader behind Chat.
- Annotation request status currently belongs to that instance. Simply making a
  temporary second model would lose in-flight/failure state when the preview is
  dismissed and permit conflicting per-target requests across the two surfaces.

## Approaches considered

1. **Embed `BibleScreen` with hidden controls.** Lowest initial code churn, but
   its mount/disappear handlers still publish shell chrome, install accessories,
   restore reading position, and manage audio. Many unrelated flags would be
   required. Rejected.
2. **Compose a separate preview from shared reading and study components.**
   Recommended. Reuse the renderer and existing interaction logic with a fresh
   local model; extract common presentation and app-lifetime annotation dispatch
   where the second consumer demonstrates a real need.
3. **Replace the full reader/view model architecture in one change.** A clean
   long-term possibility, but moving every navigation, narration, persistence,
   and selection API at once expands regression scope beyond this feature.
   Defer that wholesale rewrite.

## Package boundary and routing

Core gains a generic `.previewRecord(reference:)` event and an optional preview
factory on `MiniApplet`, defaulting to nil. The factory returns opaque SwiftUI
content and accepts a typed completion callback. Core contains no Bible views or
GRDB dependency; Chat and the shared shell still import no Bible package.

```swift
public enum RecordPreviewCompletion: Sendable, Equatable {
    case cancel
    case openRecord(reference: RecordReference)
    case addToChat(reference: RecordReference, startNewConversation: Bool)
}

// @MainActor, on MiniApplet; default implementation returns nil.
func recordPreview(
    for reference: RecordReference,
    onFinish: @escaping @MainActor (RecordPreviewCompletion) -> Void
) -> AnyView?
```

Only `BibleApplet` implements this capability for valid Bible deep-link
references. The shell resolves the factory by `reference.appletID` in the existing
fixed registry. Unsupported previews are ignored without navigating or presenting
an empty sheet. No separate provider registry or target-specific shell code.

`AppShell` owns the outer `.sheet(item:onDismiss:)`, its unique presentation ID,
and any pending completion. Construct the opaque content exactly once when
accepting an event; do not call the factory from a recomputing body. Repeated taps
while a preview is active are ignored. A completion is accepted at most once for
its presentation ID. Cancel/drag dismissal emits no navigation event. Explicit
completion queues a value, dismisses, and publishes only from outer `onDismiss`.

The shell must arbitrate existing Settings/sidebar/navigation events: never mount
two sibling root sheets simultaneously. Ignore preview requests while Settings is
presented; authoritative full navigation cancels the preview and its stale queued
completion. After dismissal, apply that navigation once. Preview presentation
does not modify `AppletRegistry.activeID` or Chat overlay progress.

For an already-published authoritative `.openRecord`, defer only the shell's
visible applet/Chat transition. `BibleReferenceInbox` already processes the
original event: do not replay it after dismissal and navigate/persist twice.
Preview-originated completions instead publish their first event after dismissal.

Apply the shell's live `.superTheme(theme)`, `.superFontScale(appearance.fontScale)`,
`.superTypography(typography)`, and event-bus environment outside the cached opaque
content, just as its existing Chat/Backdrop/Settings layers do. Caching the
factory's result must not freeze theme/scale values or fall back to Core defaults.

## Reusable Bible components

### Chapter content

Keep one `BibleChapterReader` for text, queries, anchors, and hit testing. Replace
the four loose footer parameters with an optional `BibleChapterNavigation`
configuration containing labels and actions; nil renders no footer. Introduce
`BibleChapterReaderLayout` with explicit top and base-bottom clearance. Full
reader uses its existing 68-point top and existing shell-bottom reserve; the
preview uses a header in normal layout and no shell-bottom reserve. The existing
selection/narration overlay clearance remains added as needed in both hosts.
Keep default full-reader behavior for existing tests/consumers during migration.

Extract `BibleChapterContent` to bind a model to this reader (including unavailable
state, query identity, verse taps, and scroll consumption). Hosts supply layout,
optional navigation, active overlay, and explicit scroll callbacks. It must not
publish shell events, start narration, or restore a reading position.

### Study sheets and handoffs

Extract `BibleStudySheetsModifier` from `BibleScreen` for action-sheet callback
composition, annotation/disclaimer/note/bookmark sheets, and deferred handoffs.
Keep book/translation picker presentation and shell/narration lifecycle in
`BibleScreen`. The modifier accepts explicit on-open-link and on-add-to-chat
callbacks, plus an optional narration-sheet contribution from the full reader.
Absence of this contribution prevents narration presentation in the preview;
there is no bundle of `hideX` flags and no preview branch in `BibleScreen`.

Preserve the existing combined action/narration presentation in full Bible and
its selection-scroll gate. Distinguish two transitions: action tiles capture note
specs/annotation ranges, clear selection, and replace actions after `onDismiss`;
glyph-driven note/annotation presentation preserves existing selection.
Bookmarks retain their existing clear-selection behavior and action-dismissal
handoff. Narration keeps playing and its transport returns after a note/bookmark
sheet, regardless of whether verses were previously selected.
Do not indiscriminately dismiss every predecessor. Cross-host completion waits
for nested study sheets to dismiss before asking the shell to finish the outer
preview. Guard all queued work with the presentation identity so dismissal cannot
resurrect a sheet. Use actual dismissal callbacks, never timing delays.

### State ownership and lifetime

`BibleChapterPreviewSheet` owns a fresh `BibleScreenViewModel` created by
`BibleApplet`. This is reuse of tested interaction logic, not shared reading
state. Add an `initialTranslation` initializer input; the preview captures the
applet reader's current translation and receives no position repository. Load
and select the citation before presenting. Reuse the same bundled text loader,
highlight/note/bookmark repositories, disclaimer store, clock, ID generator,
clipboard, and haptics dependencies as the full reader. Inject the same read-only
`DatabaseContext` through the factory; neither shell nor Chat sees the database.

Resolve the full reader's initial saved position/translation once during
`BibleApplet.attach(to:)`, before attaching the inbound-reference inbox and before
the bootstraps expose the shell. Make `load()` idempotent so a later first mount
cannot overwrite the explicit preview handoff with a stale repository read.
Concurrent initial-load callers await the same restoration task; setting a flag
before awaiting must not let a second caller return before restoration finishes.
Explicit navigation/translation changes win over any in-flight initial restore;
use an initialization/navigation generation token and deterministic gated tests.
This also ensures a preview opened before Bible has ever been the active backdrop
uses the saved translation. This initialization reads state without saving it.

The preview never runs `BibleScreen.load()`/lifecycle hooks or attaches an inbound
`BibleReferenceInbox`. Its local narration controller is never configured with
the shared audio activity or exposed through UI, and voice discovery/preparation
is not called. No new audio architecture is needed.

Extract the app-lifetime request/status portion of annotation handling into
`BibleAnnotationDispatchViewModel`, owned by `BibleApplet` and shared by full and
preview models. It owns bus attachment, request-ID/status matching, and duplicate
in-flight suppression for the same target. Request text/target construction,
disclaimer presentation, and which sheet is open stay local. It exposes status
without owning selection or a displayed chapter. Shared status survives preview
dismissal; completed persisted rows repaint both surfaces through `@Query`.
Existing full-reader methods remain forwarding APIs so downstream features and
their behavioral tests need no sweeping rename.

Do not cancel accepted note/highlight writes or dispatched annotation jobs when
the preview closes. Scoped presentation work is cancelled/invalidated; the
app-lifetime dispatch subscriber remains attached once. No new persistent tables,
third-party packages or resolved versions, provider APIs, or cross-applet imports
are introduced. Core explicitly declares MarkdownUI's existing swift-cmark
dependency to unwrap internal link nodes without reimplementing Markdown syntax.

## Errors and boundaries

- Invalid URL/reference: keep parser rejection; no navigation or empty modal.
- Valid chapter with missing text: show the existing Chapter unavailable content
  inside the header; Cancel and Open in Bible remain usable; no action sheet.
- Verse range partly outside the loaded chapter: select only existing verse
  numbers; if none exist, present the chapter unselected without actions.
- Construct the valid selection by filtering actual chapter verse numbers against
  range bounds, not allocating an arbitrarily large input range first.
- Repository failures keep existing toasts; disclaimer and annotation retry
  failures keep their current visible recovery paths inside the preview.
- Reopening the same reference after dismissal creates a fresh model/ID, not a
  cached selection or stale pending completion.

## Validation and delivery

Unit/integration coverage must prove preview versus open event separation, local
selection and no reading-position writes, partial/empty verse clipping, current
selection handoff encoding, shared annotation request lifetime, and reactive
decorations across two readers. Retain existing reader/navigation/narration tests.

Reuse existing reader, action, annotation, note, bookmark, theme-gallery, and
minimum-font captures. Add only new modal-content evidence: primary light/dark
and one combined XXL/maximum-app-font reflow. The existing single-pass snapshot
renderer cannot capture native sheet stacks; verify nested actions and last-verse
visibility on the real simulator instead of expanding capture infrastructure.
Target +3 captures: the verified inventory is 623 total (582 package/41 native),
becoming 626 (585 package/41 native), with Bible 276 becoming 279. Reconfirm counts
at implementation time. Repository PNGs are the baseline; explicitly record, inspect, commit, and compare the three intentional modal images.

The dedicated pinned simulator must verify the native stack, interactive chapter
behind actions, action reopening, long-chapter anchoring, unsaved-note behavior,
Close/drag cancellation, Open in Bible, Add to chat/New chat, and direct external
deep links in both app targets. Build both schemes and run Core, Chat, and Bible
package suites plus affected UIKit visual coverage before a draft PR.

Follow root AGENTS.md through a separate implementation review, draft PR,
current-revision Codex approval and passing applicable CI, ready status,
auto-merge, and verified merge. Poll CI/review together every ten minutes while
waiting, preferably with a scheduled wakeup; disable auto-merge before new pushes.

## Plan review outcome

Two independent subagents reviewed the design against the current implementation:
one for architecture/state ownership, one for interactions/native presentation/QA.
Both approved after the plan incorporated their actionable findings. Review added
live appearance injection, true noninteractive citation rendering, existing
bookmark/selection and narration-return semantics, exact handoff encoding,
presentation readiness, feasible visual coverage, and guarded initial restoration.
The user approved implementation and using stacked PRs on 2026-09-08.
