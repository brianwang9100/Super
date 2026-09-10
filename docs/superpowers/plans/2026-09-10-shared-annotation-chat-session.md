# Shared annotation ChatSession Implementation Plan

> Execute in the current worktree. A review subagent critiques this plan before implementation; a separate reviewer checks the implementation. Independent error-presentation work may be delegated while the primary agent implements the session integration.

**Goal:** Route annotations through ChatSession with an isolated in-memory transcript and shared response/error components, fixing divergent generation settings.

**Architecture:** Keep ChatSession as the one engine. Construct ephemeral instances with the existing memory-backed ChatDatabase and GRDB repositories. Configure tool availability and verified completion independently of composer visibility and persistence.

**Tech Stack:** Swift 6, actors, AsyncStream, GRDB, SwiftUI, Core UI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-10-shared-annotation-chat-session-design.md` (user-approved intent in the task).

## Global constraints

- Edit only `/Users/bwang/.codex/worktrees/a519/Super`; initial revision `96d624669748ffba796b7f34008e7922360bf0f2`, clean detached worktree.
- Applets import Core, never each other; use existing injection/event bus. No dependency changes.
- Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a, iPhone 17; simulator A185DB21-586B-4B1B-A628-A3D945E26A47.
- Preserve saved annotations on all failures, bulk behavior, no-composer layout, draft/query handoff, tool persistence/recovery, and baseline inventory.
- Use fake/gated providers in tests. Only final bounded manual validation uses the already-configured simulator's key under explicit user authorization.

## Task 1 — Configurable ephemeral ChatSession

Files: create `Packages/Chat/Sources/Chat/Orchestration/ChatSessionConfiguration.swift`, `ChatSession+Ephemeral.swift`, and `Packages/Chat/Tests/ChatTests/Orchestration/EphemeralChatSessionTests.swift`; modify `ChatSession.swift`, `ContextAssembler.swift`, `ChatSessionDriver+Adapter.swift`.

Interfaces:
```swift
public struct ChatSessionConfiguration: Sendable {
    public enum ToolPolicy: Sendable { case enabled, disabled }
    public static let defaultTemperature = 1.0
    public let tools: ToolPolicy
    public let requiresCompleteResponse: Bool
}
// ChatSession initializer accepts configuration with ordinary-chat defaults.
// Factory returns the same actor type, with its repositories retaining the memory database.
public static func makeEphemeral(
    provider: any LLMProvider,
    toolRegistry: ToolRegistry,
    briefing: String,
    configuration: ChatSessionConfiguration,
    clock: any Clock,
    idGenerator: any IDGenerator
) async throws -> ChatSession
```

- [x] Write behavior tests: two sequential sends preserve the first turn; separately created sessions do not share messages; settings default equals ordinary driver; tool-disabled requests advertise no tools/search or search briefing; unsolicited tools fail without executing; strict missing terminal/error-after-terminal/content-after-terminal streams do not produce saved assistant events.
- [x] Run focused tests and record the expected failure before implementation. Existing annotation request test gets a `temperature == 1.0` assertion to reproduce the live regression without billing.
- [x] Implement factory using `ChatDatabase.makeInMemory()`, insert only its memory conversation, construct existing repos/Compactor, and return ChatSession. Inject clock/IDs; no title/sidebar services.
- [x] Thread configuration into provider options, tool assembly/search policy, context assembly, and complete-through-EOF validation. Use one default temperature constant in send/retry/driver. Keep normal configuration behavior unchanged.
- [x] Run ephemeral, ChatSession, ContextAssembler and strict provider tests, including multi-turn/cancellation tests.

## Task 2 — Foreground annotation adapter

Files: `BibleAnnotationStreamGenerator.swift` (reduce to domain adapter and rename if appropriate), `BibleAnnotateDispatcher.swift`, corresponding generator/dispatcher tests.

- [x] Keep tests for exact target fields, progress-before-save, missing writer, empty/thinking-only output, unsolicited tools, incomplete/late errors, cancellation, and save failures. Add same-defaults regression and absence of persistent chat rows.
- [x] Replace `provider.stream` with `ChatSession.makeEphemeral`, then `session.send`. Forward text progress and only save the successfully finished assistant response after EOF. Preserve target/briefing helpers and failure classification.
- [x] Use a cancellation handler to cancel and await the owned ChatSession, avoiding an orphaned billable request. Explicitly check cancellation before the final write. Retain normal deduplication/draft lifetime through existing dispatcher ownership.
- [x] Run annotation generator and dispatcher suites and all Chat tests.

## Task 3 — Shared error presentation

Files: Core LLM error descriptions and Core UI/Responses error types/banner; `Chat/UI/Messages/ErrorBanner.swift`, `Chat/UI/MessageList+Content.swift`, `Chat/ViewModels/ChatScreenViewModel.swift`; `Bible/UI/AnnotationSheet.swift`; focused Core/Chat/Bible tests.

- [x] Write a regression proving provider error details survive `localizedDescription` and non-HTTP provider codes are not labeled HTTP.
- [x] Extract reusable Chat error state/banner into Core, preserving Chat APIs and geometry. Use the same banner for annotation failure and retain the feature-owned return-to-saved action. Existing shared response Markdown/activity/actions remain the common response body.
- [x] Reuse centralized LLM error formatting from Chat and annotation outcomes. Preserve existing error actions and retry visibility.
- [x] Run affected package tests. Compare existing representative Chat error and annotation failure snapshots; inspect and record only intentional annotation appearance changes. No new captures unless an uncovered distinct risk is demonstrated.

## Task 4 — Integration and delivery

- [x] Update the architecture/UI docs for ephemeral sessions and how another popup composes them.
- [x] Run each affected package suite with `DEVELOPER_DIR='/Applications/Xcode 26.app/Contents/Developer' swift test --package-path Packages/<Core|Chat|Bible>`; run affected simulator captures via `Scripts/VisualTesting/capture.py`.
- [x] Build Super and SuperBible on the registered simulator with local signing. Install SuperBible without uninstalling it; preserve the user's configured key. Manually verify one annotation streams/saves, normal Chat works, close/reopen preserves generation, and no annotation conversation appears in history.
- [x] Independent implementation review; address serious findings and rerun affected tests.
- [ ] Create branch `codex/shared-annotation-chat-session`, commit, and open draft PR using repository template and exact test results/capture counts.
- [ ] Check CI and Codex review together; request review if absent. Fix findings. Follow 10-minute scheduled monitoring and only enable auto-merge after explicit Codex approval plus applicable CI for the current revision; verify merge.

## Review and execution record

- User authorized implementation of shared ChatSession, in-memory annotation history, and future multi-turn capability on 2026-09-10.
- Ruling: use an isolated GRDB in-memory database instead of new dictionary repository conformers. Existing repository ordering/cascade/replay behavior is reused; no disk history is created.
- Plan reviewed by `plan_review`; two actionable corrections accepted:
  - Capture provider/model together and seed a private request registry before constructing the annotation session. Test switching the app registry during generation. This pins generation only; existing writer provenance issue #143 remains separate.
  - Check cancellation before startup and after `send`, cancel and drain the owned session on every cancelled exit, and check cancellation after provider EOF before persistence. Cover pre-cancelled startup as well as mid-stream cancellation.
- Suppress ContextAssembler's native-search briefing explicitly when tools are disabled; withholding tool definitions alone is insufficient.
- Regression confirmed: `BibleAnnotationStreamGeneratorTests.requestContract` fails because temperature is `0.7` instead of ordinary Chat's `1.0`.
- Factory API refinement: accept the already-resolved provider and create its private registry internally, making generation pinning the default for every ephemeral caller.
- Tasks 1–2 implemented. Focused session/annotation/dispatcher run: 74 tests across 4 suites passed. Added a further deterministic cancellation-at-EOF regression before full validation.

- Final local suites: Core 338 tests, Chat 1,144 tests, Bible 938 tests passed. The cancellation-at-EOF regression passes.
- Simulator comparisons passed: AnnotationSheet 12, AnnotationSheetContainer 7, MessageList 27, ChatScreen 15. Six inspected annotation error PNGs intentionally changed; Chat PNGs unchanged; repository inventory remains 586.
- Signed Debug builds of SuperBible and Super passed on the pinned worktree simulator.
- Independent implementation review (`implementation_review`) found no serious actionable issues; design and package boundaries confirmed.
- Live simulator: gpt-5.6-luna generated and saved a 1 Peter 2 annotation; closed while generating and reopened successfully. Sidebar retained only the two prior chat rows, with no annotation conversation.
- SwiftLint completed successfully with existing repository warnings; no warnings in new session/error files.
- Live regular Chat on the same gpt-5.6-luna configuration completed the follow-up prompt “Reply with only OK.” with “OK”.
