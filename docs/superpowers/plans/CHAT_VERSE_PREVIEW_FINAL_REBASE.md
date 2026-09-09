# Chat verse preview: final stack rebase

## Reason and approach

The protected atomic merge of stack #350 failed without merging any PR. Main
advanced from `99d6dac3` to `91adcd94`, adding the composer drag handle (#346),
snapshot consolidation and documentation-only CI selection (#355), and the
scroll-to-bottom control (#342). A read-only merge found conflicts only in four
testing/CI documents. The approved preview design and behavior remain unchanged.

1. Keep all three PRs draft with auto-merge off; pause the delivery heartbeat.
2. Preserve recovery refs for foundation `ee4742c4`, preview `812ab1dd`, and Chat
   `22b9a579`. Rebase foundation onto `91adcd94`, then each dependent branch using
   its exact old parent as the `--onto` boundary.
3. Resolve the documentation conflicts against main's current workflow and
   coverage policy. Derive counts from the merged inventory: main has 540 package
   captures and 41 native previews; the three approved preview captures yield
   543 package captures and 584 total images. Do not restore retired fixtures,
   replace retained PNGs, or change comparison tolerances.
4. Audit the merged Chat screen and view model for both the preview handoff and
   main's new controls. Compare the rest of main's handle/scroll source set,
   workflows, retirement evidence, and retained PNGs byte-for-byte where this
   stack has no intentional changes.
5. Update QA evidence and PR descriptions, obtain a separate implementation
   review, and atomically push all three branches with exact old-head leases.
   Request fresh Codex reviews for every revised head and resume the ten-minute
   delivery heartbeat. Use the protected native stack merge only after current
   approvals and passing applicable CI, and verify all three PRs merged.

## Risks

- Applying dependent commits twice: use explicit old-parent boundaries and
  compare each rebased layer with its recovery ref.
- Accidentally resurrecting retired baselines or overwriting new chat UI:
  validate inventory/retirement guards and compare main-owned files and PNGs.
- Reusing approval from before the rebase: keep the stack draft until all three
  new heads have explicit Codex approval and passing applicable CI.

## Validation

- Run affected Core, Bible, and Chat package suites with pinned Xcode 26.4.1.
- Run the VisualTesting Python suite, including CI selection and retirement
  guards, and inspect the actual inventory and retained-baseline identity.
- Build both Super and SuperBible for the registered iPhone 17 simulator.
- Run the complete 584-image default comparison on the pinned simulator without
  recording. Preserve all main baselines plus the three approved preview images.
- Repeat the actual shell-source ordering harness and native modal, selection,
  Add/New chat, Cancel, and Open in Bible navigation checks.
- Obtain an independent final diff review; repeat affected validation for fixes.

## Plan review

Faraday approved the approach and requested explicit VisualTesting Python guard
coverage and an audit of the complete new handle/scroll source set. Both are
included above.

## Validation result

The rebased implementation at `21cb2c74` passes Core 335 tests / 43 suites,
Bible 922 / 93, and Chat 1109 / 84, plus both app builds and the actual-source
shell ordering harness's 17 assertions. The full default comparison passes all
584 images: Bible 253, Chat 228, Core 20, Todo 42, and native 41. The runner also
passes all 38 PreviewPilot and 48 VisualTesting Python tests, including CI
selection and retirement guards. Recording remained disabled.

All 581 main snapshot PNGs are byte-identical; the only additions are the three
approved modal images. Main's 540 package inventory rows remain intact. The
rebase retains all main-owned workflow, retirement, composer-handle and scrolling
changes. Sagan's separate final diff review found no serious actionable issues;
Git's merge-tree verification succeeds against `91adcd94`.

Native SuperBible verification in Lapis Dark at 120% confirms the hidden outer
handle, floating bottom pill, range/disjoint/chapter-only titles, clearable
selection, and native child actions. Cancel preserves the exact in-session saved
reading row. Add attaches Romans 8:28–30 once to the existing composer; New opens
a composer with only John 3:16–17 after both sheets dismiss. Open in Bible restores
full controls with John 3:16–17 KJV and appends exactly one chapter-history visit.

Ignored evidence is under `.superpowers/sdd/CHAT_VERSE_PREVIEW/final-rebase-*`,
`.build/VisualTesting/complete-9za60yuz`, and
`.build/verse-preview-floating-pill/final-rebased-modal.png`. The simulator is
retained and the task-owned companion is stopped. This result documentation and
removal of one Markdown hard-break whitespace marker do not alter validated code.
