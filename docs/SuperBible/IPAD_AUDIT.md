# SuperBible iPad audit

Baseline audit: 2026-09-10 at revision `67f5b2be`. The findings and source references below describe that revision; the implementation results are recorded separately here.

## Implementation and verification

All six recommended updates are implemented: the shell reserves the reported system window-control inset; the reader, navigation, Chat and lists share a fluid column capped at 760 points; expanded Chat covers its outer margins; and the annotation acknowledgment scrolls its explanation when vertical space is limited. Existing iPhone spacing and orientation policy remain intact. The user accepted the iPad result as a starting point and requested a PR.

- **Package tests:** Core 339, Bible 953, Chat 1,144 passed with `swift test`.
- **Simulator comparisons and behavior:** 73 Bible tests across five affected suites and 116 Chat tests across six affected suites passed on the pinned iPhone simulator. Existing iPhone PNG baselines from main are unchanged. Both Super and SuperBible simulator builds passed with Xcode 26.4.1.
- **New visual coverage:** eight captures cover wide reader/navigation, narrow enlarged reading, wide Bookmarks and Chats, three wide Chat states, and the short acknowledgment. The tracked inventory grows from 593 to 601 after integrating PR #371 (560 package captures plus 41 native previews); 48 inventory guard tests passed. The unaffected full capture matrix is left to CI.
- **iPad manual checks:** portrait, landscape, and a 375 × 486 floating window; hamburger access below the system controls; reader/control alignment; narration follow-scroll; semi-expanded Chat dismissal by tapping its side margin; and expanded Chat's full-width background. The native acknowledgment was tested at 120% on initial presentation and while resizing. Its button now ends around 453 points inside the 486-point window, with the explanation independently scrollable. Local canned annotations and a nested annotation sheet were also exercised.
- **iPhone manual checks:** reader and chapter navigation, sidebar, Chat expansion/minimization, a canned conversation with the software keyboard, and Chats search. Hardware rotation preserves the existing portrait-only iPhone policy; iPad retains all four orientations.
- **Review:** a subagent reviewed the plan before implementation; a separate implementation reviewer reported no serious actionable findings.

Post-change manual coverage does not include a physical device, VoiceOver, the complete iPad keyboard matrix, every drag/reference handoff, or exhaustive secondary-sheet interactions such as the short-window voice picker and share cancellation. These remain spot-check limits, not claims of verified behavior.

Committed examples: [wide reader](../../Packages/Bible/Tests/BibleTests/UI/Snapshots/__Snapshots__/BibleScreenSnapshotTests/landscape.landscape.png), [short acknowledgment](../../Packages/Bible/Tests/BibleTests/UI/Snapshots/__Snapshots__/AnnotationDisclaimerSheetSnapshotTests/shortWindow.short_window.png), and [expanded Chat](../../Packages/Chat/Tests/ChatTests/UI/Snapshots/__Snapshots__/ChatOverlaySnapshotTests/landscapeExpanded.landscape_expanded.png).

## Baseline scope

SuperBible already declares iPhone and iPad support (`TARGETED_DEVICE_FAMILY = "1,2"`) and all four iPad orientations. The shipped composition root registers Bible, Bookmarks, and Chats, with Chat as the shared overlay. Plans, Memorize, Quiz, and Learn are not present in this revision and are excluded, despite references in older roadmap documents.

The recommended work is concentrated in six areas: fix windowed navigation and the annotation acknowledgment sheet; adapt the Bible reader and Chat to readable widths; then polish the Chats and Bookmarks lists. Most secondary screens can retain their current layouts.

## Evidence and limits

- Reviewed the reachable screen and presentation graph in the app target, shared shell, Bible, Chat, and shared sheet components. A separate reviewer examined secondary screens and checked the findings.
- Built SuperBible successfully using Xcode 26.4.1 (`17E202`) and ran it on a dedicated iPad Pro 13-inch (M5), iPadOS 26.4.1 (`23E254a`). Inspected portrait (1032 × 1376 points), landscape (1376 × 1032), and a resized window reported by accessibility as 375 × 486.
- Inspected the reader, sidebar, passage picker, translations, verse actions, annotation acknowledgment, Settings root, Models, Add Model, Look & Feel, empty and populated Chat, Bookmarks, Chats, narration transport, and voice picker. Tested 100% and 120% app font scale in selected layouts. Populated Chat used the local canned debug provider.
- Other inventory rows below are source-reviewed, not claims of a completed simulator test for every screen/state. No physical iPad, iPad mini, external keyboard, VoiceOver session, complete Dynamic Type matrix, or exhaustive keyboard/presentation interaction matrix was tested.
- At the baseline revision, the inspected screen snapshots used phone widths. The original audit captures are local scratch evidence under `.build/ipad-audit/evidence/`; those links require the retained worktree and are not repository baselines. The initial audit itself made no production or test changes.

## Screens to update

| Area | Priority | Finding | Recommended change |
| --- | --- | --- | --- |
| Shared shell / sidebar entry on every main screen | Fix | In a floating iPad window, the system window controls cover the hamburger. Tapping the overlapping area opened the system window controls. The sidebar itself has an appropriate 300-point width. | Make the sidebar entry avoid the window controls using responsive placement or native toolbar integration. Preserve a visible navigation entry in small windows. |
| About AI annotations acknowledgment | Fix | At 120% app font scale in the 375 × 486 window, the icon is cropped at the top and the Got it button is cropped at the bottom. The button's reported bottom is approximately 497 points, beyond the 486-point window. The same sheet fits full-screen landscape. | Make the contents scrollable and/or adapt its presentation height. Keep the acknowledgment fully visible in the initial presentation, including after window resizing. |
| Bible reader, including immersive reading and its navigation controls | High | Scripture stretches almost edge to edge. Landscape leaves approximately 1324 points of reading width after the two 26-point margins. Chapter footer buttons and floating controls also spread across the screen. This is a readability problem, not a rendering crash. | Center a bounded reading column and align its chapter controls to that column. Keep the layout fluid in narrow windows. Existing typography and verse rendering can remain. |
| Chat: minimized dock, empty conversation, populated transcript, and composer | High | The dock and conversation span essentially the full iPad width. Assistant prose, thinking rows, and code blocks stretch across the screen; the composer sends related controls to opposite edges. The semi-expanded state covers almost all scripture below the navigation bar. | Constrain transcript and composer widths together and align the accessories. Preserve gesture and keyboard behavior across resizing. A side-by-side reading/chat mode is an optional further design decision. |
| Chats list and search | Polish | The search field and list rows span the entire screen with only 18-point side margins. Short titles sit at the far left and disclosure chevrons at the far right. | Use a bounded list/search column. A conversation list beside the active chat is optional. |
| Bookmarks overview | Polish | Six short bookmark slots occupy full-width rows with extensive unused horizontal space. | Use a bounded list or a deliberate compact grid; preserve the six-slot model. A grid is optional, not a functional requirement. |

Source evidence:

- Shell placement: [AppShell.swift](../../App/Shell/AppShell.swift), `HamburgerLayer`, lines 856–866; [FixedHamburgerButton.swift](../../App/Shell/FixedHamburgerButton.swift), line 18. The problem is placement relative to system controls; the hamburger layer does not itself ignore the top safe area.
- Disclaimer: [AnnotationDisclaimerSheet.swift](../../Packages/Bible/Sources/Bible/UI/AnnotationDisclaimerSheet.swift), lines 18–37 and 55–62; [BibleStudySheetsModifier.swift](../../Packages/Bible/Sources/Bible/UI/BibleStudySheetsModifier.swift), line 76. Non-scrollable contents are hosted with only a medium detent.
- Reader: [BibleChapterReader.swift](../../Packages/Bible/Sources/Bible/UI/BibleChapterReader.swift), lines 205–208.
- Chat: [ChatOverlay.swift](../../Packages/Chat/Sources/Chat/UI/ChatOverlay/ChatOverlay.swift), line 151; [MessageList.swift](../../Packages/Chat/Sources/Chat/UI/MessageList.swift), lines 182–185; [ChatComposerFooter.swift](../../Packages/Chat/Sources/Chat/UI/ChatComposerFooter.swift).
- Lists: [ChatsScreen.swift](../../Packages/Chat/Sources/Chat/UI/ChatsScreen.swift), lines 39–55 and 145–160; [BookmarksScreen.swift](../../Packages/Bible/Sources/Bible/UI/BookmarksScreen.swift), lines 32–40 and 58–63.

## Screens that can retain their current design

“Keep” means no separate iPad redesign was justified by this audit. It does not mean every interaction has been certified. Shared shell fixes still apply when these screens are reached from affected main-screen navigation.

| Screen / surface | Assessment | Evidence or remaining check |
| --- | --- | --- |
| Sidebar drawer contents | Keep | Visually inspected at 100% and 120%. Its 300-point width and scrolling list are suitable. Fix the entry button, not the drawer's content layout. A persistent sidebar is optional. |
| Bible book/chapter picker, reference search, and sorting | Keep | Visually inspected the picker. Native sheet bounds the width; book list scrolls and chapter cells flex. Search keyboard and result navigation still need dedicated interaction coverage. |
| Translation picker | Keep | Visually inspected. Four choices fit cleanly inside the shared native sheet. |
| Verse selection / highlight / copy / share / annotation / note / Chat action panel | Keep | Visually inspected. The content-sized sheet has a sensible width and flexible action columns. Share presentation is a separate unverified interaction. |
| Bookmark color / assignment sheet | Keep, source-reviewed | Native content-sized sheet, flexible two-column grid. Test small-window height at enlarged text. |
| Chapter / verse preview opened from Chat | Keep, source-reviewed | The shared reader is contained in a native large sheet. Its width is already constrained by its host. Test nested study sheets and return-to-Chat behavior on iPad. |
| Book / chapter / verse annotation detail | Keep, source-reviewed | Shared scrolling annotation surface covers saved, generating, empty, and error content. Native sheet constrains width. Test deletion confirmation and long generated content. |
| Book / chapter / verse note list | Keep, source-reviewed | Native List inside a sheet provides scrolling and row actions. |
| New note and Edit note | Keep, source-reviewed | Large native sheet with a flexible TextEditor. Verify software-keyboard and short-window behavior; no separate tablet layout is currently necessary. |
| Narration transport | Keep | Visually inspected play/stop states at 120%. Controls remain grouped in a compact native sheet. Playback was stopped after inspection. |
| Narration voice picker | Keep full-size design; short-window test pending | Visually inspected the full-screen iPad popover. Its width is bounded to 280–360 points, but its requested height is fixed at 520. Verify that short windows keep the close control and scrolling voice list accessible. |
| Narration settings | Keep, source-reviewed | Scrollable pane; also reachable through the voice picker. Verify the nested presentation chain. |
| Apple narration setup | Keep, source-reviewed | Native large sheet with scrolling contents. |
| OpenAI narration setup / cache controls | Keep, source-reviewed | Native large scrolling form. Verify keyboard avoidance and cache confirmation placement. No credentials or paid provider calls were used in this audit. |
| Settings root | Keep | Visually inspected at 100% and 120%. A roughly 580-point-wide sheet provides an appropriate settings layout. The list scrolls. |
| Models list | Keep | Visually inspected. Cards and switches fit within the sheet. |
| Add Model / Edit Model | Keep | Add Model was visually inspected; Edit Model shares the source-reviewed form. Labels stack above fields and content scrolls. Keyboard, validation, and save/cancel interaction coverage remains. |
| Look & Feel | Keep | Visually inspected the font slider and theme grid, including 120% scale. Two flexible theme columns work well at the sheet width. |
| Personalization | Keep, source-reviewed | Scrollable settings host and stacked text entry. Verify keyboard behavior. |
| Default Verbosity | Keep, source-reviewed | Stacked choices fit the existing settings sheet. |
| Tools | Keep, source-reviewed | Scrollable rows and toggles. |
| Memory, reached from Tools | Keep, source-reviewed | Text reflows and the editor can grow vertically within Settings scrolling. |
| Compaction | Keep, source-reviewed | Standard controls inside the shared scrolling settings host. |
| Search settings | Keep, source-reviewed | Standard settings controls; no independent tablet layout needed. |
| Data | Keep, source-reviewed | Standard scrollable pane. Export and delete confirmations require separate interaction verification. |
| About | Keep, source-reviewed | Centered identity and a 260-point text column inside Settings. |
| Settings → Annotations hub | Keep, source-reviewed | Uses the Settings scroll host; coverage summary, run cards, and completed-run rows with Retry/Dismiss actions are suitable for the sheet width. |
| Generate annotations / book and chapter selection | Keep, source-reviewed | Selection list scrolls. Header/footer consume fixed vertical space, so test usable list height in a short window. |
| Bulk annotation progress | Keep, source-reviewed | Shared progress presentation with a scrolling chapter list. Test pause/retry and sheet transitions separately. |
| Model menu, speed menu, chapter actions, contextual confirmations | Keep native controls | Model and voice controls were exercised. Remaining menu/dialog placements need ordinary iPad interaction verification, not a new visual design. |
| Verse share and data-export share sheet | No redesign established; interaction test pending | SwiftUI owns the presentation. The UIKit export wrapper has no explicit popover anchor, but this alone does not establish a crash. Verify actual presentation and cancellation on iPad. |
| Splash / launch, unavailable chapter, bootstrap failure, empty/error states | Keep, source-reviewed | Centered or flexible layouts do not require separate tablet composition. Chat-specific empty/error states inherit the proposed Chat width change. Startup failure was not deliberately induced. |

The main secondary-screen hosts are [SettingsSheet.swift](../../Packages/Chat/Sources/Chat/UI/Settings/SettingsSheet.swift), [BibleStudySheetsModifier.swift](../../Packages/Bible/Sources/Bible/UI/BibleStudySheetsModifier.swift), and [SheetNavBar.swift](../../Packages/Core/Sources/Core/Theme/SheetNavBar.swift). Native `.sheet` presentation already bounds their width on iPad; an internal infinite maximum width is not, by itself, a tablet defect.

## Suggested implementation and verification order

1. Fix the obscured sidebar entry and clipped annotation acknowledgment. Add focused coverage of the actual windowed/native presentation risk.
2. Introduce bounded content widths for the reader and Chat, keeping compact-window behavior and font scaling. Validate chapter navigation, selections, narration follow-scroll, Chat expansion/dragging, and keyboard transitions after the width change.
3. Apply a consistent bounded list layout to Chats and Bookmarks.
4. Verify remaining small-window, keyboard, share, and nested-sheet interactions before declaring complete iPad support. Prioritize the 520-point voice popover and Generate annotations header/footer in short windows.

A persistent sidebar and simultaneous reader/Chat columns could improve the tablet experience, but they are separate product choices. Neither is required to correct the two confirmed bugs or the stretched content widths.

Add representative iPad landscape, narrow-window, and native-sheet cases to the visual matrix rather than duplicating every phone fixture. Current settings snapshots use 402 × 874; the disclaimer's enlarged-text snapshot uses an explicitly taller 480-point host, which does not establish that the real medium-detent presentation fits a short window.

## Local screenshot index

These files are ignored scratch evidence and are available only in this retained worktree:

- [reader-portrait.png](../../.build/ipad-audit/evidence/reader-portrait.png)
- [reader-landscape.png](../../.build/ipad-audit/evidence/reader-landscape.png)
- [window-chrome-overlap.png](../../.build/ipad-audit/evidence/window-chrome-overlap.png)
- [annotation-disclaimer.png](../../.build/ipad-audit/evidence/annotation-disclaimer.png)
- [annotation-disclaimer-120.png](../../.build/ipad-audit/evidence/annotation-disclaimer-120.png)
- [annotation-disclaimer-small-window.png](../../.build/ipad-audit/evidence/annotation-disclaimer-small-window.png)
- [chat-semi-expanded.png](../../.build/ipad-audit/evidence/chat-semi-expanded.png)
- [chat-populated.png](../../.build/ipad-audit/evidence/chat-populated.png)
- [chats-list.png](../../.build/ipad-audit/evidence/chats-list.png)
- [bookmarks.png](../../.build/ipad-audit/evidence/bookmarks.png)
- [sidebar.png](../../.build/ipad-audit/evidence/sidebar.png)
- [passage-picker.png](../../.build/ipad-audit/evidence/passage-picker.png)
- [translations.png](../../.build/ipad-audit/evidence/translations.png)
- [verse-actions.png](../../.build/ipad-audit/evidence/verse-actions.png)
- [settings.png](../../.build/ipad-audit/evidence/settings.png)
- [models.png](../../.build/ipad-audit/evidence/models.png)
- [add-model.png](../../.build/ipad-audit/evidence/add-model.png)
- [appearance.png](../../.build/ipad-audit/evidence/appearance.png)
- [narration-transport.png](../../.build/ipad-audit/evidence/narration-transport.png)
- [narration-voices.png](../../.build/ipad-audit/evidence/narration-voices.png)

Dedicated audit iPad: `D34E9541-8316-4CFD-B2C0-ABFBBCFB351B`, retained with the worktree and the updated app installed for spot checks. The repository helper also associated its standard iPhone with this worktree: `5C687A0D-A7C2-4D71-A408-F6A6F1DC2026`. The supplemental iPad was created specifically for this audit because the helper supports only the pinned iPhone configuration; it is not part of the helper's orphan-cleanup registry.

## Navigation integration during PR review

CI exposed stale expectations in only the two new reader captures after PR #371 changed the navigation title size and preferred width on main. The branch now incorporates that reviewed navigation change. Existing iPhone baselines come from main unchanged; the two new reader captures are refreshed for the integrated navigation layout. Both refreshed files exactly match the inspected CI renderings. The affected five Bible simulator suites passed all 73 tests after the update, the Bible package passed 953 tests, and 48 inventory guards passed. A separate integration reviewer found no serious actionable issues. No comparison tolerance or fixture coverage is relaxed.
