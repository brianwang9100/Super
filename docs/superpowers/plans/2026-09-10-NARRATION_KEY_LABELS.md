# Narration key labels implementation plan

## Requirements

The narration picker must explain that it reuses an existing API key and put the associated saved model name in parentheses. Preserve credential identity and dedicated-key behavior. Address PR #363's Codex finding that duplicate saved model names produce indistinguishable choices; do not expose raw IDs or secret key material.

## Approach

- Keep source names as the saved model names supplied by the composition root.
- Add a small pure Bible-owned picker-label function. Unique names render `Use existing key (model name)`. Duplicate names render `Use existing key 1 (model name)`, `Use existing key 2 (model name)`, and so on.
- Assign duplicate ordinals by sorting matching source IDs, rather than by the incoming array order or selected source. IDs remain internal. Numbering represents positions among the current same-name choices, not permanent key names; adding or removing choices may renumber existing options.
- Continue tagging picker rows with their original source IDs. Do not change key references, persistence, provider configuration, or key lookup.

## Risks

- A label must never become the credential identifier. Regression coverage must exercise selecting each same-name source and verify its corresponding key is resolved.
- Ordinals distinguish otherwise identical choices but are not account names. Their scope is the current group of same-name sources; model renames are the existing way to attach account meaning.
- Longer labels can wrap in the native picker. Cover the duplicate selected state using one representative existing narration snapshot and inspect the menu manually.

## Validation and delivery

- [x] Obtain a read-only plan review and address actionable findings before implementation. No blocking findings; clarified that inserting duplicate names can also renumber choices.
- [x] Add failing regressions for unique names, duplicate names, incoming-order independence, unrelated names, and selecting both same-name credentials; implement the label helper and wire the picker. Confirmed duplicate-label regressions fail against prior behavior and pass with the fix.
- [x] Reuse the existing enabled XXL narration setup capture for duplicate-source visual coverage. Dedicated saved-key light/dark and manual-key setup XXL captures remain. Inspected and explicitly recorded one changed PNG; narration capture count stays 44.
- [x] Run the Bible package suite (940 tests passed), narration snapshot comparison (44 captures passed), SuperBible build, strict lint, and diff checks. Manually inspected both duplicate menu entries on the pinned worktree simulator and removed the temporary model fixtures.
- [x] Obtain a separate read-only code review and fix findings. No actionable findings.
- [ ] Update the existing draft PR description and reply to Codex's inline finding. Confirm auto-merge is disabled before pushing, then request fresh Codex review tied to the new head SHA.
- [ ] Check CI and Codex review together every 10 minutes while pending. Require current-head Codex approval and passing applicable checks, verify live required-check protection, then mark ready, enable auto-merge, and verify the merge. Stop monitoring after merge.
