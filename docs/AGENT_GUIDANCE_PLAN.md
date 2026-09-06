# Agent Guidance Cleanup Plan

## Outcome

Keep Super's agent instructions focused on repository-specific constraints and
encode the agreed plan → review → implementation → QA → review → draft PR →
monitoring → auto-merge workflow.

## Changes

1. Add the delivery workflow to root `AGENTS.md`, scoped to substantive
   implementation tasks. Require separate plan and change reviews, actionable
   findings addressed, and renewed validation/review after relevant changes.
2. Preserve the instruction cleanup across all eight `AGENTS.md` files: remove
   generic advice and source inventories, retain local constraints, consolidate
   test procedures in `docs/TESTING.md`, and use one PR description template.
3. Update references affected by consolidation. Keep current behavior distinct
   from planned server/CI architecture. Replace conflicting human-only approval
   guidance in `docs/CI_PIPELINE.md` with a link to the root delivery workflow;
   do not change application or CI logic.
4. Gate auto-merge on explicit Codex approval of the current revision. A missing
   review or approval from another reviewer is insufficient. Mark the draft ready
   before enabling auto-merge. Verify live merge rules and wait for applicable CI
   checks to pass, even if branch protection does not enforce them. Do not change
   repository protection settings in this PR.

## Review and validation

- Have a subagent review this plan before the remaining edits; address findings.
- Check all instruction links, changed references, inbound root anchors, and all
  eight `CLAUDE.md` symlinks. Parse documented shell examples, compare executable
  workflow content, and run `git diff --check`.
- Have a separate subagent review the complete diff against the base, including
  removed rules and the new testing reference. Address findings and repeat the
  affected checks. No Swift runtime tests are needed for documentation-only edits.

## Delivery

Create a `codex/` branch and a draft PR with both review results and QA evidence.
Monitor checks and Codex review, fixing actionable failures. Request Codex review
if it does not start automatically. Enable auto-merge only after approval covering
the current revision; verify the eventual merge and retain the worktree/branch.

## Plan review

The plan reviewer identified conflicting human-only merge guidance and unverified
branch protection. Both are addressed in steps 3–4 and the delivery checks.

## Change review

The separate change reviewer found no serious issues in the cleanup. Its remaining
consistency finding was the CI introduction describing implemented jobs as planned;
the introduction now reflects the live workflow scope and links to the merge gates.
The updated base's Codex hooks, native review integration, and persona-eval skill
requirements are retained.
