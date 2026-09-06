# Worktree Simulator Lifecycle Plan

## Outcome

Each worktree uses its own simulator. A merged PR permits removal of its clean
worktree, and deleting a worktree causes its owned simulator to be deleted.
Retained worktrees retain their simulators. A scheduled cleanup enforces the
orphan-removal rule independently of PR monitoring.

## Approach

1. Add a small Python CLI that creates/reuses the current worktree's simulator and
   records its owner path, Git admin-directory identity/token, and simulator UUID
   in a registry under the repository's common Git directory. The registry
   survives individual worktree deletion. Serialize operations and write changes
   atomically. Persist creation intent before `simctl create` so interrupted
   creation can be recovered by its recorded unique name.
2. Use CI's pinned device/runtime when creating a simulator. Associate each macOS
   worktree on first use; create once and reuse it thereafter. Keep a
   dedicated managed name plus UUID; never infer ownership of legacy simulators.
3. Add a dry-run-first cleanup command. Only delete registered simulators whose
   owner directory no longer exists; resolve moved worktrees through their Git
   admin-directory identity/token, and retain existing paths even if Git metadata
   was pruned. Recheck ownership and existence immediately before deletion.
   Abort on unreadable/corrupt inventory or registry. Never delete worktrees from
   the cleanup command.
4. Update the existing simulator guard to recognize a named simulator's device
   type rather than confusing its display name with the iPhone model. Add a
   regression test for managed simulator names.
5. Update root `AGENTS.md`, `docs/TESTING.md`, CI guidance, and the PR monitor to
   replace the previous keep-worktree/delete-simulator-on-merge policy.
6. Schedule daily orphan cleanup against a durable checkout if the user approves
   standalone scheduling. The scheduled executable must live in the main checkout
   after merge; until then, use a reviewed installation under the common Git
   directory, independent of this worktree. Verify that exact durable command.
   Run it once in preview mode, then apply confirmed
   registered orphan deletions. Do not delete unregistered legacy simulators.

## Risks and validation

- Tests cover idempotent association, competing operations, orphan detection,
  corrupt/missing state, moved/existing worktrees, simulator identity mismatch,
  shutdown/delete errors, and unrelated simulator preservation.
- Run the CLI tests and existing hook tests, plus documentation link/diff checks.
- Validate local CI pins, associate this worktree, and exercise cleanup preview
  without deleting any live worktree's simulator.
- Request a plan-review subagent before implementation and a separate change
  review after QA. Address findings, push to draft PR #326, and request Codex
  review of the new head; previous approval cannot authorize the new changes.

## Plan review

The reviewer identified moved-worktree identity, interrupted creation, and the
scheduled executable's lifetime as risks. The implementation follows Git admin
metadata across moves, journals creation before calling simctl, and supports a
reviewed installation in the common Git directory until the main checkout has
the merged helper. Regression tests cover the first two cases; live QA verifies
the durable invocation.

## Change review and QA

The change reviewer found Git admin-directory reuse, including a moved
replacement and an original directory retained after metadata pruning. The
helper now distinguishes registered replacement identities, follows their Git
backlinks, and preserves retained original directories. All 23 helper/guard
tests pass, as do the existing hook fixtures. The custom-name guard regressions
were demonstrated failing before the fix. Live association returned the same
simulator UUID twice; cleanup preview retained the live worktree and found no
registered orphans. The final review found no remaining actionable issues.
