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
