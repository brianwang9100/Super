# Argos integration retirement

This setup guide is retired by the repository snapshot rollback. Use [SNAPSHOT_TESTING.md](SNAPSHOT_TESTING.md) for current comparison commands, baseline locations, and reviewed PNG updates. No Argos account, token, CLI, upload, or external visual approval is needed by the replacement workflow.

The inventory remains 623 images: 582 package snapshots and 41 native previews. The rollback preserves current fixtures, UI, renderer fixes, simulator pins, and behavioral assertions. The [CI cutover procedure](CI_PIPELINE.md#repository-snapshot-workflow) removes only the external `argos` requirement after validated replacement checks and current-revision Codex approval; editing workflow YAML alone does not change branch protection. All other required checks and protections remain enforced.

Historical evidence remains in the [pilot results](PREVIEW_VISUAL_TESTING_RESULTS.md), [Settings migration results](ARGOS_SETTINGS_MIGRATION_RESULTS.md), [Settings stability results](ARGOS_SETTINGS_STABILITY_RESULTS.md), and [complete migration results](ARGOS_COMPLETE_MIGRATION_RESULTS.md). Their upload, baseline, and review statements describe the earlier integration, not current operating instructions. [PR #332](https://github.com/brianwang9100/Super/pull/332#issuecomment-5571855771) records the former rejection/approval enforcement controls.

Git history cleanup and its monitor remain paused. Retiring this repository integration does not authorize deletion of account data, changes to other projects, or a history rewrite. See the [rollback plan](superpowers/plans/2026-09-08-repository-snapshot-rollback.md).
