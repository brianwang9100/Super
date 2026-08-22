# Codex Agent Infrastructure Migration — Design Spec

> Migrate Super's repository-facing agent instructions, permissions, hooks, Model Context Protocol (MCP) configuration, persona evaluation, and pull-request review from Claude Code to Codex while retaining Anthropic as an in-app model provider.

**Status (2026-08-22):** Design approved. Not yet implemented.

---

## 1. Goals

This migration makes Codex the development agent and review system for every module in the repository.

- Keep `AGENTS.md` as the only editable source of repository instructions.
- Preserve each `CLAUDE.md` as a compatibility symlink to its neighboring `AGENTS.md`.
- Replace Claude Code settings, hooks, permissions, MCP configuration, and workflows with Codex-native equivalents.
- Run the SuperBible persona evaluation against current Codex models using the developer's existing Codex login and subscription-backed usage.
- Replace the Claude GitHub Action reviewer with Codex's native GitHub code-review integration.
- Preserve the existing safety properties: worktree isolation, exact simulator enforcement, read-only review, deterministic evaluation accounting, and module-specific instructions.

## 2. Non-goals

- Do not remove or change the in-app Anthropic provider, model catalog entries, credentials, tests, fixtures, privacy language, or user-facing BYOK (Bring Your Own Key) behavior.
- Do not rewrite historical design records merely because they mention Claude. Active documentation and executable references migrate; historical records remain historical.
- Do not run the full persona corpus during the infrastructure migration. A full run is an explicit, potentially expensive validation operation.
- Do not add an OpenAI API key to the repository or GitHub Actions.
- Do not automatically change GitHub repository settings, branch protection, or stored secrets. The repository documents those one-time external changes.

## 3. Instruction ownership and compatibility aliases

`AGENTS.md` is canonical at the repository root and in each module that currently carries module-specific instructions:

- `App/Shell/AGENTS.md`
- `App-SuperOS/AGENTS.md`
- `App-SuperBible/AGENTS.md`
- `Packages/Bible/AGENTS.md`
- `Packages/Chat/AGENTS.md`
- `Packages/Core/AGENTS.md`
- `Packages/Todo/AGENTS.md`

The adjacent `CLAUDE.md` files remain symbolic links to those canonical files. They are compatibility aliases only: documentation, source comments, and new links point to `AGENTS.md`, and no tool writes Claude-specific instructions into the aliases.

Codex automatically composes the root instructions with the nearest nested `AGENTS.md`. Shared code-review rules therefore live once in the root file, while module files continue to refine module-specific development and review behavior.

## 4. Repository configuration migration

### 4.1 Target layout

```text
.codex/
├── config.toml
├── hooks.json
├── hooks/
│   ├── block-outside-worktree.sh
│   ├── enforce-snapshot-sim.py
│   ├── enforce-snapshot-sim.sh
│   └── tests/
└── rules/
    └── default.rules

.agents/
└── skills/
    └── superbible-persona-eval/
        └── SKILL.md
```

### 4.2 Source-to-target mapping

| Existing Claude surface | Codex-native target | Behavior |
|---|---|---|
| `.mcp.json` | `.codex/config.toml` | Configure the XcodeBuild and iOS Simulator MCP servers at project scope. |
| `.claude/settings.json` permissions | `.codex/rules/default.rules` | Preserve narrowly scoped safe command prefixes; rely on the Codex sandbox for everything else. |
| `.claude/settings.json` hooks | `.codex/hooks.json` | Register project-scoped `PreToolUse` hooks. |
| `.claude/hooks/*` | `.codex/hooks/*` | Preserve worktree and simulator guardrails with Codex input handling. |
| `.claude/workflows/superbible-persona-eval.js` | repository skill plus evaluator runner | Replace the Claude workflow runtime with subscription-backed `codex exec` calls. |
| `.github/workflows/claude-pr-review.yml` | native Codex GitHub review | Remove the API-key-backed workflow and use the repository's Codex cloud connection. |

Once the Codex equivalents pass verification, the tracked Claude settings, hooks, workflow, and `.mcp.json` are removed. The `CLAUDE.md` symlinks remain.

### 4.3 MCP configuration

`.codex/config.toml` declares the same `xcodebuild` and `ios-simulator` stdio servers currently declared in `.mcp.json`. It also enables project hooks when required by the installed Codex version. The configuration does not pin a development model globally; model selection remains a user or workflow decision.

### 4.4 Command rules

`.codex/rules/default.rules` translates the existing allowlist into explicit `prefix_rule` entries for the safe development commands the repository already uses, including:

- Swift package build and test commands
- `xcodebuild`, `xcrun simctl`, and `xcodegen`
- read-only Git inspection

Automatic Git allowances are deliberately read-only: staging and commits remain in Codex's normal approval flow. Rules do not broadly allow arbitrary shells, interpreters, destructive Git commands, or recursive deletion. Commands outside the safe list continue through the Codex sandbox and approval system.

## 5. Hook behavior

### 5.1 Worktree isolation

The migrated `block-outside-worktree.sh` keeps the current invariant that file edits must remain under the active worktree. It adds Codex-native parsing:

- Match `apply_patch` as well as compatibility `Edit` and `Write` tool names.
- Extract every `*** Add File:`, `*** Update File:`, and `*** Delete File:` path from an `apply_patch` payload.
- Normalize relative paths against the active working directory.
- Reject any resolved target outside the worktree root.
- Preserve explicit safe exceptions only where still required for user-owned Codex configuration.

A multi-file patch is denied if any one target is outside the worktree.

### 5.2 Snapshot simulator enforcement

The existing shell/Python simulator guard is moved without weakening its behavior. It continues to inspect `xcodebuild` commands and refuses snapshot recording when the selected Xcode, iOS runtime build, or simulator model differs from the CI-pinned trio documented in `AGENTS.md`.

### 5.3 Hook tests

Checked-in fixture tests feed synthetic Codex hook events to both guards. Coverage includes:

- relative and absolute in-worktree edits
- add, update, and delete patches
- mixed patches containing one out-of-worktree target
- path traversal attempts
- non-edit tool events
- accepted and rejected simulator commands
- malformed hook input failing safely

## 6. SuperBible persona evaluator

### 6.1 Invocation and authentication

The evaluator is invoked through the repository skill `$superbible-persona-eval`. The skill runs a deterministic Node.js runner under `eval/superbible-persona/`.

The runner launches the installed Codex CLI, which uses the developer's existing Codex login. It does not read `OPENAI_API_KEY` and does not call the Responses API directly. Usage therefore comes from the developer's Codex/ChatGPT agentic allowance or credit pool.

Each model invocation is isolated from repository-agent instructions:

- run from a fresh temporary directory outside the Git repository
- use `codex exec --ephemeral`
- use `--ignore-user-config` while retaining Codex authentication
- use `--skip-git-repo-check`
- use the read-only sandbox
- pass prompts on standard input
- require the checked-in JSON output schema

This prevents `AGENTS.md`, MCP servers, project hooks, or unrelated developer configuration from contaminating the Bible-assistant persona under evaluation.

### 6.2 Model matrix

The default assistant matrix is:

| Model | Overall target | Safety-category target |
|---|---:|---:|
| `gpt-5.6-sol` | 95% | 98% |
| `gpt-5.6-terra` | 90% | 95% |
| `gpt-5.6-luna` | 80% | 95% |

`gpt-5.6-sol` is the fixed judge by default. Models, judge, reasoning effort, case selection, iteration count, and concurrency are command-line options so the harness can be sharded or adapted when a subscription does not expose a default model.

The normal full run uses three iterations per case. The runner caps concurrent Codex processes at a conservative default and retries only transport or process failures, never rubric failures.

### 6.3 Preserved evaluation semantics

The migrated harness keeps the behavioral contract of the existing evaluator:

- current SuperBible system prompt, Bible briefing, and corpus are loaded at run time
- assistant output contains declared tool calls and exact drafted user-facing text
- the fixed judge applies every `must` and `mustNot` criterion
- `judged` is distinct from `pass`
- failed assistant or judge processes are excluded from pass-rate denominators and surfaced in coverage
- overall, safety-category, per-category, flaky-case, and raw verdict summaries remain available
- two error-only retry rounds preserve honest accounting under transient failures

The runner prints a concise human summary and writes a timestamped JSON report under `eval/superbible-persona/results/`. Generated reports are ignored by Git by default; a result is promoted into documentation deliberately after review.

The previous Claude measurements remain in `docs/SuperBible/PERSONA_EVAL.md` as clearly labeled historical results until a Codex baseline is intentionally recorded.

### 6.4 Evaluator tests

The runner accepts an injectable Codex executable path. Node's built-in test runner supplies a fake executable that returns schema-valid success, rubric failure, and process-error responses. Tests cover matrix construction, retries, coverage denominators, thresholds, flaky detection, sharding, report generation, and invalid output without consuming Codex allowance.

## 7. Pull-request review

### 7.1 Native Codex review

The Claude review GitHub Action is deleted and no `openai/codex-action` workflow replaces it. The repository uses Codex's native GitHub code-review integration instead:

- automatic review is enabled once in Codex repository settings
- contributors can request an additional pass with `@codex review`
- Codex reads the root and nested `AGENTS.md` files automatically
- review comments focus on serious, actionable findings rather than style narration

The root `AGENTS.md` receives a compact review-policy section that tells Codex to enforce the repository's existing architecture, concurrency, persistence, testability, snapshot, security, and documentation rules. It prioritizes correctness and regression risk and avoids duplicating all module guidance in a separate prompt.

### 7.2 External setup and retirement

`docs/CI_PIPELINE.md` documents the one-time repository configuration:

1. Connect the repository to Codex cloud.
2. Enable Codex code review and automatic review for the repository.
3. Verify `@codex review` produces a standard GitHub review.
4. Remove any branch-protection dependency on the retired Claude workflow check.
5. Retire `CLAUDE_CODE_OAUTH_TOKEN` after confirming nothing else consumes it.

Steps 1–5 change external state and are not performed merely by committing this migration.

## 8. Documentation and reference policy

Active documentation is updated to describe Codex-native behavior:

- `docs/AI_TOOLS.md`
- `docs/CI_PIPELINE.md`
- `docs/DEVELOPMENT_SETUP.md`
- `docs/SuperBible/PERSONA_EVAL.md`
- root and module `AGENTS.md` files where tooling is discussed
- `.gitignore`, `TODO.md`, workflow comments, and active source documentation that names `CLAUDE.md`

New links point to `AGENTS.md`, `.codex/`, or the repository skill. Historical design specs, archived plans, and intentional Anthropic product references remain unchanged unless an active link would otherwise break.

## 9. Verification plan

Implementation is complete only after all applicable checks pass:

1. Run the Codex hook fixture suite.
2. Run the persona-runner unit tests with the fake Codex executable.
3. Run a persona-runner dry run that enumerates the matrix without launching models.
4. Parse and inspect `.codex/config.toml`, `.codex/hooks.json`, and `.codex/rules/default.rules` with the installed Codex CLI where supported.
5. Confirm both MCP servers appear in project configuration.
6. Confirm every `CLAUDE.md` remains a symlink to its canonical `AGENTS.md`.
7. Search the repository for active `.claude/`, Claude workflow, and Claude reviewer references; classify every remaining occurrence as an intentional alias, product-provider reference, or historical record.
8. Confirm `git status` from the worktree contains every intended migration edit and no changes outside the worktree.

No full persona evaluation is part of this verification because it consumes substantial subscription allowance. No Swift product behavior changes, so the migration does not require module test suites unless implementation unexpectedly touches product source.

## 10. Rollout and rollback

The implementation lands as one coherent repository migration:

1. Add and test Codex configuration, hooks, rules, skill, and evaluator.
2. Update canonical `AGENTS.md` instructions and active documentation.
3. Remove Claude-only executable infrastructure while preserving `CLAUDE.md` aliases.
4. Enable and smoke-test native Codex review in repository settings.
5. Remove obsolete GitHub protection and the Claude reviewer secret after the native review is confirmed.

If a Codex hook or evaluator regression appears, the Git history contains the former Claude files, while `AGENTS.md` and the compatibility symlinks remain stable. External Codex automatic review can be disabled independently without changing repository history.
