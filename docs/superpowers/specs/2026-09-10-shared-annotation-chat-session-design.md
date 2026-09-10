# Shared annotation ChatSession

## Approved intent

Use the same `ChatSession` implementation for ordinary Chat and annotation sheets, with separate instances and transcripts. Annotation sessions stay out of persistent Chat history. Composer visibility is presentation policy: ephemeral sessions support subsequent sends without adding a composer in this change.

The live regression was reproduced with gpt-5.6-luna: foreground annotations passed temperature 0.7 and received HTTP 400 (unsupported temperature), whereas ordinary Chat used 1.0 and succeeded. The annotation path also discarded provider details through `localizedDescription`.

## Session construction and lifetime

Add `ChatSession.makeEphemeral`, using `ChatDatabase.makeInMemory()` and the existing GRDB repositories. Its conversation row exists only in that isolated memory database; the application's Chat database, sidebar, title generation, and conversation export are untouched. Reusing the existing repositories preserves ordering, foreign-key cleanup, replay, and checkpoint semantics. Each factory call owns independent storage through its repository references.

The factory accepts task instructions and a `ChatSessionConfiguration` containing tool policy and completion requirements. It shares the same default generation temperature as ordinary Chat. No annotation-specific provider call or event reducer remains. Ephemeral storage imposes no turn limit: `send`, `retry`, `subscribe`, and `cancel` use the same actor implementation. Callers retain the actor for their desired interaction lifetime. Foreground annotation work retains it through generation and saving; the existing Bible draft survives dismissal and completion/query handoff. Retain no unbounded pool of completed ephemeral sessions.

## Execution policy

`ChatSessionConfiguration` has tool policy (`enabled` or `disabled`) and `requiresCompleteResponse`. Default configuration preserves regular Chat and bulk behavior. Disabled tools suppress registered tools, native/mock search tools and related search briefing, and reject unsolicited calls before any execution. Strict completion uses the current provider verification option and additionally requires a terminal event, nonempty text, no tool call when disabled, and no error through EOF before emitting a saved assistant response. Content after terminal completion fails. These checks live in ChatSession, not the annotation adapter.

The ephemeral factory accepts the resolved provider and pins it in a private registry before any send. This keeps the selected generation provider/model together during Settings changes; existing writer provenance issue #143 is separate. Session creation and both driver/default send paths use one default temperature constant. Provider-specific wire encoding remains in the existing adapters. This change fixes the reproduced mismatch by inheriting regular Chat's settings; it does not introduce speculative model-name heuristics.

## Annotation adapter

Replace the foreground generator's provider loop with creation of an ephemeral ChatSession and consumption of ChatEvent. The adapter owns target validation, annotation briefing, progress forwarding, failure classification, and the existing atomic `bible.annotate` write after the session finishes successfully. A cancellation handler cancels and drains the owned session; cancellation cannot save. Target validation and writer availability checks happen before billing. Bulk and in-chat tool-loop semantics remain unchanged.

The existing event bus and request IDs retain same-target deduplication, stale-result rejection, dismissal/reopen behavior, and causal GRDBQuery handoff. Bible never imports Chat. A future composer can retain an ephemeral ChatSession and send further turns through the same API; that UI and final-result selection are outside this change.

## Shared presentation and errors

Keep the existing shared Core Markdown/activity and Copy/Regenerate components. Extract Chat's reusable error banner into Core and use it in both Chat and annotation sheets. Keep Chat's public ErrorState compatibility through an alias or adapter. Centralize LLM error descriptions so provider code/message and interruption details survive annotation outcome conversion. Annotation errors use the shared banner; the return-to-saved annotation action remains feature-owned. Do not duplicate Chat's thinking/tool transcript UI into Bible or add a composer.

## Validation and rollout

Regression tests cover shared defaults, strict incomplete/error/late-error streams, disabled tools including native search, independent ephemeral transcripts, second user turns, cancellation/draining, observable progress before saving, and absence of writes to persistent Chat history. Existing Chat tool-loop/compaction/recovery tests must pass. Shared error formatting must preserve useful details for both HTTP and non-HTTP provider codes.

Run Core, Chat, and Bible package suites. Compare representative Chat and annotation simulator snapshots; update only intentional annotation error-banner baselines and report unchanged capture counts unless a distinct risk needs a capture. Build both app targets on Xcode 26.4.1 / iOS 26.4.1 / iPhone 17. Reuse simulator A185DB21-586B-4B1B-A628-A3D945E26A47. User explicitly authorized bounded real-provider reproduction and verification with the key already configured in that simulator; never read or export the key.

Complete plan review, implementation review, draft PR, current-revision Codex approval and CI, and the repository's authorized merge workflow.
