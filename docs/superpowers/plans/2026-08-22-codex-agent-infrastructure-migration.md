# Codex Agent Infrastructure Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Claude-specific repository tooling and PR review with subscription-backed Codex infrastructure while preserving `CLAUDE.md` compatibility symlinks and the in-app Anthropic provider.

**Architecture:** Codex project configuration lives under `.codex/`, reusable persona evaluation is a repository skill under `.agents/skills/`, and a deterministic Node runner launches isolated `codex exec` processes. Native Codex GitHub review replaces the Claude GitHub Action and reads the canonical root and module `AGENTS.md` files.

**Tech Stack:** Codex CLI, TOML, JSON hooks, Starlark exec-policy rules, POSIX shell, Python 3, Node.js 22 built-ins, GitHub native Codex review.

**Spec:** `docs/superpowers/specs/2026-08-22-codex-agent-infrastructure-migration-design.md`

## Global Constraints

- Work only inside `/Users/bwang/.codex/worktrees/607a/Super`; it is an externally managed detached worktree.
- Keep every `CLAUDE.md` symlink and treat the neighboring `AGENTS.md` as canonical.
- Leave all in-app Anthropic provider code, model metadata, tests, fixtures, and user-facing BYOK behavior unchanged.
- Do not introduce `OPENAI_API_KEY` or another API credential.
- Do not run the full persona corpus during implementation or verification.
- Use test-first development for hook and runner behavior; configuration and human documentation are the stated TDD exceptions.
- Preserve historical Claude references when they are records rather than active instructions.

---

### Task 1: Codex hook guardrails

**Files:**
- Create: `.codex/hooks/tests/test-hooks.sh`
- Create: `.codex/hooks/block-outside-worktree.sh`
- Create: `.codex/hooks/enforce-snapshot-sim.sh`
- Create: `.codex/hooks/enforce-snapshot-sim.py`
- Create: `.codex/hooks.json`
- Reference: `.claude/hooks/block-outside-worktree.sh`
- Reference: `.claude/hooks/enforce-snapshot-sim.sh`
- Reference: `.claude/hooks/enforce-snapshot-sim.py`

**Interfaces:**
- Consumes: Codex `PreToolUse` JSON on standard input with `tool_name`, `tool_input.cmd`, and `cwd` (`tool_input.command` remains a compatibility fallback).
- Produces: exit 0 for allowed operations; JSON `{ "decision": "deny", "reason": "..." }` and nonzero exit for denied operations.

- [ ] **Step 1: Write failing behavior tests**

Create a shell test that invokes the worktree guard with literal synthetic events. Include a valid in-tree patch and a mixed patch with an out-of-tree target:

```sh
run_hook '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** End Patch"}}'
assert_allowed

run_hook '{"tool_name":"apply_patch","cwd":"'"$repo"'","tool_input":{"command":"*** Begin Patch\n*** Update File: AGENTS.md\n*** Add File: /tmp/escape.txt\n*** End Patch"}}'
assert_denied "outside the active worktree"
```

Add cases for relative traversal, absolute in-tree paths, malformed JSON, non-edit tools, safe snapshot commands, and mismatched snapshot destinations.

- [ ] **Step 2: Run tests and verify RED**

Run: `bash .codex/hooks/tests/test-hooks.sh`

Expected: FAIL because the Codex hook scripts do not exist.

- [ ] **Step 3: Implement minimal Codex hooks**

Port the simulator scripts without behavior changes. Implement the worktree guard so it extracts every add/update/delete path from an `apply_patch` command, normalizes it against event `cwd`, and denies the whole patch when any target escapes the worktree.

Register both guards in `.codex/hooks.json` with `PreToolUse` matchers for `apply_patch|Edit|Write` and `exec_command|Bash` respectively.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `bash .codex/hooks/tests/test-hooks.sh`

Expected: all hook fixtures pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add .codex/hooks.json .codex/hooks
git commit -m "feat: migrate repository guardrails to Codex hooks"
```

### Task 2: Subscription-backed persona evaluator

**Files:**
- Create: `eval/superbible-persona/persona-eval.mjs`
- Create: `eval/superbible-persona/persona-eval.test.mjs`
- Create: `eval/superbible-persona/schemas/assistant-output.schema.json`
- Create: `eval/superbible-persona/schemas/judge-verdict.schema.json`
- Modify: `eval/superbible-persona/corpus.json`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `buildRunItems({ models, cases, iterations })`, `runEvaluation(options, invokeModel)`, `createCodexInvoker(options)`, and `formatSummary(report)`.
- CLI: `node eval/superbible-persona/persona-eval.mjs [--dry-run] [--model ID] [--judge ID] [--iterations N] [--concurrency N] [--case ID]`.
- Codex process: `codex exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only --cd <temp> --model <id> --output-schema <schema> --output-last-message <file> -`.

- [ ] **Step 1: Write failing unit tests**

Use `node:test` with hand-derived fixtures. Cover:

```js
test('buildRunItems creates one item per model, case, and iteration', () => {
  const actual = buildRunItems({ models: ['sol', 'terra'], cases: [{ id: 'a' }, { id: 'b' }], iterations: 2 })
  assert.equal(actual.length, 8)
  assert.deepEqual(actual[0], { model: 'sol', caseId: 'a', iteration: 0 })
})

test('judge process errors are excluded from the denominator', async () => {
  const report = await runEvaluation(fixtureOptions, scriptedInvoker)
  assert.deepEqual(report.coverage, { totalRuns: 2, judged: 1, assistErrors: 0, judgeErrors: 1 })
  assert.equal(report.perModel['gpt-5.6-sol'].rate, 1)
})
```

Also test assistant errors, two retry rounds, mixed-iteration flaky detection, threshold evaluation, option validation, dry-run behavior, report writing, and an isolated fake executable that proves `createCodexInvoker` reads structured output from `--output-last-message`.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test eval/superbible-persona/persona-eval.test.mjs`

Expected: FAIL because the evaluator module and exports do not exist.

- [ ] **Step 3: Implement the minimal evaluator**

Use only Node built-ins. Load the prompt, Bible briefing, and corpus from their canonical paths. Build assistant and judge prompts with the preserved rubric semantics. Run jobs through a bounded worker pool, retry only process failures twice, and aggregate judged-only rates.

Default models are `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`; default judge is `gpt-5.6-sol`; default iterations are 3. Write timestamped reports to `eval/superbible-persona/results/` and ignore generated JSON files.

- [ ] **Step 4: Run tests and dry-run verification**

Run: `node --test eval/superbible-persona/persona-eval.test.mjs`

Expected: all evaluator tests pass.

Run: `node eval/superbible-persona/persona-eval.mjs --dry-run --iterations 1 --case fetch-anxiety`

Expected: prints the selected model/case matrix without launching Codex.

- [ ] **Step 5: Commit**

```bash
git add .gitignore eval/superbible-persona
git commit -m "feat: add subscription-backed Codex persona evaluator"
```

### Task 3: Repository persona-eval skill

**Files:**
- Create: `.agents/skills/superbible-persona-eval/SKILL.md`
- Create: `.agents/skills/superbible-persona-eval/agents/openai.yaml`

**Interfaces:**
- Trigger: `$superbible-persona-eval` or a request to run, shard, interpret, or refresh the SuperBible persona evaluation.
- Consumes: evaluator CLI from Task 2.
- Produces: explicit run scope, coverage-first interpretation, and paths to generated reports.

- [ ] **Step 1: Establish the failing skill baseline**

Give a fresh agent this repository and ask it to explain how it would run a one-case, one-iteration persona smoke test without spending usage. Do not expose the intended command. Record whether it finds the retired Claude workflow, misses `--dry-run`, or proposes an API key.

- [ ] **Step 2: Initialize the repository skill**

Run the official skill initializer with repository-local placement and deterministic UI metadata:

```bash
python3 /Users/bwang/.codex/skills/.system/skill-creator/scripts/init_skill.py superbible-persona-eval --path .agents/skills --interface 'display_name=SuperBible Persona Eval' --interface 'short_description=Validate the SuperBible chat persona across Codex models' --interface 'default_prompt=Use $superbible-persona-eval to run or interpret the SuperBible persona evaluation.'
```

- [ ] **Step 3: Write the minimal skill**

Replace the generated template with concise imperative instructions that select smoke, shard, or full modes; run the checked-in evaluator; read coverage before rates; never silently run a full matrix; and never request an API key.

- [ ] **Step 4: Validate and forward-test the skill**

Run:

```bash
python3 /Users/bwang/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/superbible-persona-eval
```

Give a fresh agent the same one-case dry-run scenario with `$superbible-persona-eval`. Expected: it selects `--dry-run`, states that no model usage occurs, and reports the exact command without invoking a full evaluation.

- [ ] **Step 5: Commit**

```bash
git add .agents/skills/superbible-persona-eval
git commit -m "feat: add SuperBible Codex persona-eval skill"
```

### Task 4: Codex MCP and command policy

**Files:**
- Create: `.codex/config.toml`
- Create: `.codex/rules/default.rules`
- Reference: `.mcp.json`
- Reference: `.claude/settings.json`

**Interfaces:**
- Produces: project-scoped `xcodebuild` and `ios-simulator` MCP servers plus explicit safe command rules.

- [ ] **Step 1: Add Codex project configuration**

Translate the two stdio MCP declarations to `[mcp_servers.xcodebuild]` and `[mcp_servers.ios-simulator]`. Enable project hooks without pinning a model.

- [ ] **Step 2: Add least-privilege exec-policy rules**

Translate the existing command allowlist into exact `prefix_rule(..., decision="allow")` entries. Include inline match/not-match examples for each broad family and exclude destructive Git or shell operations.

- [ ] **Step 3: Validate configuration**

Run:

```bash
codex --strict-config mcp list
codex execpolicy check --rules .codex/rules/default.rules swift test
codex execpolicy check --rules .codex/rules/default.rules git reset --hard
```

Expected: both MCP servers load; safe test command allows; destructive Git does not allow. If the installed CLI exposes a different exec-policy validation command, use its help-discovered equivalent and document the exact command run.

- [ ] **Step 4: Commit**

```bash
git add .codex/config.toml .codex/rules/default.rules
git commit -m "feat: add Codex MCP and command policy"
```

### Task 5: Native Codex pull-request review

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/CI_PIPELINE.md`
- Modify: `TODO.md`
- Delete: `.github/workflows/claude-pr-review.yml`

**Interfaces:**
- Consumes: native Codex GitHub automatic review and `@codex review`.
- Produces: root review criteria inherited by all modules and documented one-time repository setup.

- [ ] **Step 1: Add canonical review policy**

Add a compact root `AGENTS.md` section directing Codex reviews to report serious, actionable correctness, architecture, concurrency, persistence, security, testability, and regression findings. Require tight file/line evidence, suppress style-only narration, and inherit nested module instructions.

- [ ] **Step 2: Document native review setup**

Replace Claude reviewer workflow documentation with Codex cloud setup, automatic review, `@codex review`, expected standard GitHub review behavior, and the external retirement checklist for branch protection and `CLAUDE_CODE_OAUTH_TOKEN`.

- [ ] **Step 3: Remove the Claude reviewer workflow**

Delete `.github/workflows/claude-pr-review.yml` after the documentation no longer depends on it. Update `TODO.md` to name native Codex review rather than a workflow file.

- [ ] **Step 4: Verify active references and commit**

Run: `rg -n 'claude-pr-review|CLAUDE_CODE_OAUTH_TOKEN|claude-code-action' AGENTS.md docs TODO.md .github`

Expected: only the intentional secret-retirement instruction remains.

```bash
git add AGENTS.md docs/CI_PIPELINE.md TODO.md .github/workflows/claude-pr-review.yml
git commit -m "ci: migrate pull request review to Codex"
```

### Task 6: Active documentation and Claude infrastructure retirement

**Files:**
- Modify: `docs/AI_TOOLS.md`
- Modify: `docs/DEVELOPMENT_SETUP.md`
- Modify: `docs/SuperBible/PERSONA_EVAL.md`
- Modify: `App-SuperBible/AGENTS.md`
- Modify: `.github/workflows/ios-build.yml`
- Modify: `project.yml`
- Modify: active Swift source/test comments returned by the reference audit
- Modify: `.gitignore`
- Delete: `.mcp.json`
- Delete: `.claude/settings.json`
- Delete: `.claude/hooks/block-outside-worktree.sh`
- Delete: `.claude/hooks/enforce-snapshot-sim.sh`
- Delete: `.claude/hooks/enforce-snapshot-sim.py`
- Delete: `.claude/workflows/superbible-persona-eval.js`

**Interfaces:**
- Produces: Codex-native contributor setup and active references; historical and product-provider references remain intentional.

- [ ] **Step 1: Update active contributor documentation**

Describe `.codex/config.toml`, `.codex/hooks.json`, `.codex/rules/`, canonical `AGENTS.md`, compatibility `CLAUDE.md` symlinks, the evaluator skill, subscription-backed CLI usage, and native Codex review. Mark the 2026-06-11 Claude persona measurements as historical rather than current.

- [ ] **Step 2: Update active code and workflow comments**

Point rule references at `AGENTS.md` and simulator hook references at `.codex/hooks/enforce-snapshot-sim.py`. Keep `project.yml` comments explicit that both instruction filenames are excluded from target resources.

- [ ] **Step 3: Remove superseded Claude executable infrastructure**

Delete the tracked `.claude` settings/hooks/workflow and `.mcp.json`. Do not delete or rewrite any `CLAUDE.md` symlink.

- [ ] **Step 4: Verify the complete migration**

Run:

```bash
bash .codex/hooks/tests/test-hooks.sh
node --test eval/superbible-persona/persona-eval.test.mjs
node eval/superbible-persona/persona-eval.mjs --dry-run --iterations 1
python3 /Users/bwang/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/superbible-persona-eval
while IFS= read -r link; do test -e "$link" || exit 1; done < <(find . -name CLAUDE.md -type l)
git diff --check
git status --short
```

Audit active references with the exclusions documented in the spec. Confirm each remaining Claude occurrence is an alias, an Anthropic product-provider reference, or a historical record.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: complete Codex agent tooling migration"
```
