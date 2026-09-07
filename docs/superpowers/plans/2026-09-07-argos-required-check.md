# Require Argos and retire duplicated composer snapshots

## Approach

- Add the observed `argos` review status and GitHub Actions `native-previews` capture/upload check to main branch protection, retaining all five existing checks and their app bindings. Verify the main Argos reference build before retiring coverage. Required status changes live in GitHub, not workflow YAML.
- Keep OIDC and the current explicit fork restriction. Fork PRs will be blocked by the required Argos status until a supported upload path is enabled and verified; do not bypass required review, introduce a reusable secret, or use `pull_request_target` to execute fork code.
- Once the main reference succeeds, retire only `ChatComposerSnapshotTests` and its 21 PNGs: all 21 have named Argos preview replacements in the committed inventory. Preserve the other 598 legacy PNGs, all four remaining package jobs, build checks, and nonvisual tests.
- Remove the migration-only hash/parity dependency from normal capture. Keep preview identity, expected inventory, dimensions, metadata, complete PNG decoding, environment, lockfile, and upload-size checks. Remove obsolete comparison tooling and baseline fields while preserving the historical pilot results as evidence.
- Label the remaining workflow matrix as legacy coverage and document that its discovery naturally excludes the deleted suite. Keep required aggregate job IDs stable. Update current setup/testing guidance and record the capture-count change (Argos 23→23; legacy 619→598).

## Risks

- Required capture alone does not enforce visual approval; require the Argos App's own review status as well. Bind checks to their observed publisher where supported. Preserve existing protection settings.
- Forks currently cannot upload. Required Argos deliberately blocks their merge; enable and verify tokenless support separately before promising fork support.
- Do not remove legacy coverage until the main reference exists and all 23 current captures are verified. No broad workflow deletion or Git history rewrite.
- A valid PNG header alone is insufficient: decoding every image must continue to fail on corrupt/truncated payloads, including the two UIKit probes.

## Validation and delivery

- Independent plan review before implementation, then guard regressions including corrupt PNG payloads and retained discovery/inventory contracts.
- Run the Chat package suite and complete pinned native capture; compare all 23 generated PNGs with the pre-change verified set to demonstrate unchanged rendering.
- Validate workflow syntax and remaining discovery (Bible, Chat, Core, Todo); verify missing/failed Argos statuses prevent merge via GitHub protection and PR check state.
- Independent change review, draft PR using the template, current-revision Codex approval and passing applicable CI before ready/auto-merge. Do not approve visual diffs merely to unblock merging. Monitor every ten minutes and verify eventual merge.

## Plan review requirements

The reviewer confirmed the 21-case legacy suite contains no behavioral assertions. Before this retirement merges, verify the PR selects main build #7 as its reference and reports 23 unchanged captures. Record rejection/approval enforcement and failed capture/upload controls; the prior comparison-only demo is insufficient. If visual approval cannot be exercised with available authentication, leave the cleanup draft and explicitly report that remaining prerequisite instead of claiming migration is complete.

Main capture run 34117546159 succeeded on 2026-09-07; Argos build #7 on commit `58d18b5b` reports success. Branch protection now requires `argos` from Argos App 57576 and `native-previews` from GitHub Actions 15988, in addition to all five previous checks. Other protection settings are preserved.

## Local verification

- Fresh count at base `58d18b5b`: 619 tracked legacy PNGs, 21 composer PNGs removed, 598 retained. Earlier audit totals were stale; current docs are corrected.
- Chat: 1,117 tests in 86 suites pass (`.build/argos-required-chat-tests.log`).
- Capture: 28 iOS tests pass; 23 images in `run-h7pwi9td` are byte-identical to pre-change `run-1629azyg`.
- Python: 19 guards pass, including real decoder empty/truncated-file controls and failed-decoder prevention of screenshot staging.
- Both modified workflows pass `actionlint`; all four legacy package directories still contain suites; deleted composer suite is no longer discovered.
- GitHub protection reread confirms both new app-bound checks and exact preservation of all previous protection settings.
- Remote rejection→approval enforcement and cleanup PR reference selection remain delivery checks; no visual approval has been performed by this agent.
