# SuperBible Target

Public App Store app, scheme `SuperBible`. Read the [fork design](../docs/superpowers/specs/2026-05-23-superbible-fork-design.md) and [overview](../docs/SuperBible/OVERVIEW.md) before target changes.

- Cold launch always selects Bible and minimizes Chat, ignoring the persisted backdrop. Foreground returns preserve session state. Configure this through `AppShellLaunchBehavior`, not target checks in the shared shell.
- v1 is local-only: no accounts, server, or sync. BYOK calls go directly to providers; Keychain keys use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The planned v2 path is Sign in with Apple + CloudKit private database. Revisit fork-spec §7 before introducing a different cloud architecture.
- Free, BYOK, no ads/IAP/premium tier/paywalls. The only donation surface is the Settings → About GitHub Sponsors link in `SFSafariViewController`.
- Changes to collection, transmission, storage, capabilities, or Keychain accessibility require a same-PR update to [PRIVACY.md](PRIVACY.md). Diagnostics follow [SuperBible observability](../docs/SuperBible/OBSERVABILITY.md).

## Persona

Edit [Resources/SuperBibleSystemPrompt.md](Resources/SuperBibleSystemPrompt.md) for the persona. It is an explicitly bundled resource loaded by `SuperBibleSystemPromptLoader` into `ChatSessionStore(chatBriefing:)`; keep capability claims aligned with the shipped tools/applets.

For behavior changes, read [PERSONA_EVAL.md](../docs/SuperBible/PERSONA_EVAL.md), use `$superbible-persona-eval` for a dry run or scoped real run (the full matrix requires explicit confirmation), and keep the Bible applet's [SystemPrompt.md](../Packages/Bible/Sources/Bible/Resources/SystemPrompt.md) tool-routing guardrails consistent. Model limitations and evaluation procedures live in that doc.

Follow [app-target verification](../docs/TESTING.md#app-target-verification).
