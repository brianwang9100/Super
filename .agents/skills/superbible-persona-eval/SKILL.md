---
name: superbible-persona-eval
description: Run, shard, interpret, or refresh the SuperBible persona evaluation with the checked-in Codex evaluator.
---

# SuperBible Persona Eval

Run commands from the repository root with `node eval/superbible-persona/persona-eval.mjs`.

Choose the smallest requested scope.

- For a usage-free one-case smoke check, run `node eval/superbible-persona/persona-eval.mjs --dry-run --model gpt-5.6-sol --iterations 1 --case fetch-anxiety`. `--dry-run` launches no Codex processes, uses no model allowance, and writes no report.
- For a real shard, state the selected models, cases, iterations, concurrency, judge, reasoning effort, and any non-default timeout before running. Pass each selection explicitly with `--model`, `--case`, `--iterations`, `--concurrency`, `--judge`, `--reasoning-effort`, and `--timeout-seconds` as needed. The per-invocation timeout defaults to 600 seconds.
- For the full matrix, first state its scope and request explicit confirmation. Do not run it from defaults or infer confirmation: defaults are all corpus cases, three iterations, and the configured assistant models and judge.

Use the developer's existing Codex ChatGPT subscription login. Never request, set, or expose an API key. The runner verifies `codex login status` before a real run and refuses API-key or logged-out sessions. Its child agents run in temporary directories with inherited shell environment, login shells, shell/exec, web search, Apps/connectors, plugins, browser/computer use, skills, image generation, workspace dependencies, hooks, subagents, automatic skill instructions, user config, and external exec-policy rules disabled. A no-usage prompt-render preflight fails closed if skill, App, plugin, or multi-agent instruction blocks remain model-visible.

After a real run, give the exact timestamped JSON path printed under `eval/superbible-persona/results/`. Interpret coverage before rates: inspect `coverage.judged`, total runs, assistant errors, and judge errors; rates exclude unjudged records. Then review per-model overall and safety targets, category results, flaky cells, and raw verdicts. Treat incomplete coverage or an unavailable rate as inconclusive, not as a pass or failure.
