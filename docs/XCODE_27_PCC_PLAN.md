# Xcode 27 and Private Cloud Compute Plan

Status: proposed implementation plan, 2026-09-06. No tooling, application code, signing configuration, or snapshot baselines have been changed by this document.

## Outcome and scope

Deliver in two sequential phases, preferably two separately reviewable PRs:

1. Move the Apple build/test toolchain and screenshot baselines to Xcode 27 + iOS 27.
2. Add Apple Private Cloud Compute (PCC) as a distinct Apple Intelligence model for iOS 27 and above, including registration, availability, and fresh-setup defaults.

**Keep the app deployment minimum at iOS 26.0 in both phases.** Building against the iOS 27 SDK does not mean making every API call require iOS 27. Keep the packages' iOS 26 and macOS 26 deployment floors; guard newer APIs at their actual availability boundaries. Do not change Swift 6 language mode or raise package tools versions solely because Xcode changed.

This applies to both the `Super` (SuperOS) and `SuperBible` targets. PCC uses Apple's Foundation Models framework, not a custom HTTP endpoint, BYOK credential, app backend, or CloudKit sync service.

### Product contract for phase 2

| Scenario | Default and registration behavior |
| --- | --- |
| Fresh setup on iOS 26 | Seed and select Apple Intelligence — Local only. PCC is visible but disabled in registration. |
| Fresh setup on iOS 27 or later | Seed and select Apple Intelligence — Private Cloud Compute. Local only remains available to add/select explicitly. |
| Existing configured install, including an iOS 26 → 27 upgrade | Preserve all records, record IDs, names, selection, and per-chat/settings model choices. Do not automatically replace local with PCC. |
| iOS 27+, but PCC is temporarily unavailable, offline, or quota-limited | Preserve the PCC configuration and preference; explain the actual limitation. Offer an explicit route to local or another model, not an automatic substitution. |
| A persisted PCC configuration is encountered on iOS 26 | Keep it visible and unavailable; do not instantiate a 27-only API or interpret its ID as the local model. |

For this plan, **fresh setup uses the existing empty-model-repository rule**, not a new installation-tracking system. Deleting every model and relaunching can seed the OS-appropriate default again, as empty-store seeding does today. A populated store is never reseeded. Changing that reset behavior to strictly once-per-install is outside this change.

Default configuration is distinct from service readiness: choosing PCC by OS must not depend on a transient network/readiness result during first launch. Persist the OS-appropriate default, then show its real availability. No generation request is issued merely to seed/register a model. This makes the requested default deterministic, including on unsupported hardware, where the configured model must explain why it cannot run.

## Current implementation and external constraints

### Repository findings

- The Apple jobs in [ios-build.yml](../.github/workflows/ios-build.yml), [swift-test.yml](../.github/workflows/swift-test.yml), and [testflight.yml](../.github/workflows/testflight.yml) use `macos-26` and Xcode `26.4.1`. Derived-data and compiled Swift package cache keys also contain that version.
- Screenshot verification pins iPhone 17, iOS 26.4.1 runtime build `23E254a`. The local [.claude/hooks/enforce-snapshot-sim.py](../.claude/hooks/enforce-snapshot-sim.py) reads the workflow using format-sensitive regular expressions and has old-version fallbacks. Its numeric-only Xcode matching is insufficient for exact beta pinning.
- [project.yml](../project.yml) has `xcodeVersion: "26.4"`, while both app targets deploy to iOS 26.0. All four Swift packages use Swift tools 6.2 and iOS/macOS 26 platform minimums.
- There are currently **543 PNG screenshot baselines and 3 text snapshots** across Core, Chat, Bible, and Todo. Recount when implementation begins; renderer migration does not justify changing database schema snapshots.
- [ModelConfigurationSeeding.swift](../Packages/Chat/Sources/Chat/Repositories/ModelConfigurationSeeding.swift) atomically seeds one selected `.appleFoundation` / `system-default` record into an empty repository. Both bootstraps currently call it only when the **local** model reports available.
- [LLMProviderFactory.swift](../Packages/Chat/Sources/Chat/LLM/LLMProviderFactory.swift) currently dispatches every `.appleFoundation` row to the same local provider without checking `modelId`.
- [SettingsViewModel.swift](../Packages/Chat/Sources/Chat/ViewModels/SettingsViewModel.swift) has a single `hasAppleFoundationModel` duplicate check and hardcodes `system-default` on creation. The registration pane already has a Model menu; extend it instead of introducing a second picker system.
- [SettingsModelsPane.swift](../Packages/Chat/Sources/Chat/UI/Settings/Panes/SettingsModelsPane.swift) uses local availability for every Apple row. Bootstrap hydration can skip an unavailable selected provider and silently retain the first registered provider; PCC needs explicit unavailable-selection handling.
- Title generation's automatic choice explicitly targets `system-default`. Empty-chat suggestions construct their own local provider. These must not accidentally become cloud requests when the chat default changes.

### Verified external baseline, September 6, 2026

- GitHub currently exposes the **`xcode-27` public-preview runner**, not a `macos-27` label. Its ARM64 image lists macOS 26.5.2, image `20260901.0153.1`, Xcode 27 beta 6 build **`27A5252f`**, and iOS 27.0 / iPhone 17 simulators. Thus phase 1 upgrades the toolchain and simulator to 27, **not the host OS to 27**. [GitHub runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
- The image inventory does not establish the exact iOS simulator runtime build. Discover that from a real runner before choosing the final pin. Do not substitute an iPhone OS beta build number for a simulator build.
- `setup-xcode` selects preinstalled Xcodes. A selector such as `27.0-beta` does not lock a specific beta build: an independent build-number assertion is required. [setup-xcode documentation](https://github.com/maxim-lobanov/setup-xcode)
- Apple's `PrivateCloudComputeLanguageModel` is available on iOS 27 and later, with corresponding macOS 27 availability. PCC has its own availability and quota state; it is not the existing on-device `SystemLanguageModel`. Check the exact declarations in the selected SDK during implementation. [Apple integration guide](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute?changes=latest_major)
- Access requires App Store Small Business Program enrollment, Apple's download-count eligibility, and an assigned managed PCC entitlement. Apple describes App Store, TestFlight, and ad hoc distribution for eligible developers. Account and bundle eligibility have **not** been checked in this planning pass. [Apple PCC eligibility](https://developer.apple.com/private-cloud-compute/)

The intentional beta migration is acceptable for this plan. A subsequent beta/RC/GA update may require another reviewed baseline migration. Recheck the release and runner inventory at implementation time; do not silently substitute whatever happens to be latest.

## Phase 1 — Toolchain and screenshot migration

### 1. Resolve and prove the new pin

- [ ] Run a read-only inventory job on `xcode-27` and record: runner image/version, host OS/architecture, `xcodebuild -version`, `swift --version`, `xcodebuild -showsdks`, `xcrun simctl list runtimes --json`, `xcrun simctl runtime list`, and available iPhone 17 devices.
- [ ] Start with Xcode build `27A5252f` if still provisioned. Resolve and record the **exact installed iOS 27 runtime build**; no placeholder build may remain when phase 1 merges.
- [ ] Confirm that the same Xcode and simulator runtime can be installed locally. Record against a dedicated per-worktree iPhone 17 simulator addressed by UDID. Do not replace the shared booted simulator or delete runtimes used by another worktree.
- [ ] Keep the existing 26 toolchain available for compatibility investigations. A machine-wide macOS 27 upgrade is not part of this plan.

### 2. Update every Apple CI consumer and its caches

- [ ] Change all Apple build, package-test, snapshot-test, and archive jobs in the three workflows to the selected 27 runner/toolchain. Leave Ubuntu jobs alone.
- [ ] Assert the exact Xcode build after selection and before cache restoration/building. A newer beta supplied by a refreshed hosted image must fail with an actionable mismatch, not silently consume existing baselines.
- [ ] Update the primary simulator picker to iOS 27.0, the verified runtime build, and iPhone 17. Require one unambiguous matching runtime; select a device belonging to that runtime and use its UDID.
- [ ] Update derived-data and compiled `.build` cache keys **and restore prefixes** with the exact Xcode build and runner architecture; include runtime build in snapshot-derived-data keys. Do not restore old compiled caches through a broad fallback prefix. Source checkout caches can remain separately reusable.
- [ ] Keep existing package/snapshot discovery, both app build legs, required gate names, coverage thresholds, and docs-only/skip semantics intact.

### 3. Update project generation and local enforcement together

- [ ] Set `project.yml`'s Xcode metadata to 27, regenerate via the existing script, and verify both app schemes and all four package test schemes still exist.
- [ ] Retain iOS 26.0 deployment settings, package `.iOS(.v26)` / `.macOS(.v26)`, Swift 6 mode, strict concurrency, and warnings-as-errors. Fix actual new-compiler incompatibilities without broadly relaxing checks.
- [ ] Validate the existing pinned XcodeGen first. Upgrade it only if required for 27 compatibility, with a reviewed version/checksum update to the shared install action.
- [ ] Update the snapshot hook and workflow parsing in the same change: beta selectors, exact Xcode build, runtime build, device, and stale fallback behavior. Malformed/missing pins must fail closed for screenshot recording/verification.
- [ ] Add focused guard tests for matching pins, wrong beta build, wrong runtime build, ambiguous runtime installs, wrong device, and malformed configuration. Keep a single authoritative pin definition or mechanically check duplicate consumers for agreement.
- [ ] Give non-snapshot iOS 26 compatibility runs an explicit, testable path through the guard. The current guard covers every concrete simulator command; do not bypass it wholesale to test back-deployment. The compatibility path must refuse screenshot recording and must not use the 27 reference set for 26 screenshot comparisons.

### 4. Re-record and review the complete screenshot set

- [ ] First run the current suites under 27 without recording. Separate compile/test logic failures from expected rendering differences.
- [ ] Using the exact CI trio, opt into the existing `SnapshotEnvironment.isRecording` seam and record all UIKit screenshot suites in **Core, Chat, Bible, and Todo**, including theme galleries and existing accessibility/font-scale variants.
- [ ] Preserve existing coverage and snapshot scaffolding: font registration, UIKit guards, per-package serialization conventions, Vellum light/dark screen coverage, and gallery-only coverage of other families.
- [ ] Review changed old/new images and diffs for clipping, layout, typography, glass, dark-mode contrast, and XXL text. Explain the intentional OS/toolchain migration; do not accept every difference merely because the new runtime produced it.
- [ ] Do not delete failing variants, loosen precision, or change database text snapshots simply to make this migration pass. Unchanged PNGs need not produce artificial diffs.
- [ ] Turn recording off and rerun the full screenshot suites successfully locally **and on a fresh CI run**. Keep representative migration evidence in the PR.

### 5. Verify iOS 26 support and release tooling

- [ ] Run all four package suites with the new compiler; build both app schemes with signing disabled, then verify Release/device compilation as well.
- [ ] Confirm generated build settings still declare iOS 26.0. Install the newly built application on iOS 26 and test launch, settings/model registration, chat with a fake/local provider, and basic navigation for both targets. Prefer an iOS 26.0 device/runtime to prove the actual minimum; document any testing gap if only a later 26.x version is available.
- [ ] Add or retain a bounded iOS 26 non-snapshot compatibility leg where the runtime can be provisioned. A newer SDK build alone is not a back-deployment test, and an old Xcode-built binary does not validate the new compiler's output.
- [ ] Validate manual signing and archive/export with Xcode 27. Preserve the current release trigger and scheme scope; the checked-in TestFlight workflow currently archives `Super`, not an implemented two-target release matrix.
- [ ] Record a successful TestFlight processing result before relying on the new toolchain for distribution. A closed runner issue is not proof that this app's archive is accepted. If processing is rejected, keep that release gate visibly unresolved; do not declare the release migration done.

### 6. Synchronize operational documentation

- [ ] Update `AGENTS.md`, target-specific toolchain instructions, `docs/CI_PIPELINE.md`, `docs/DEVELOPMENT_SETUP.md`, and active scripts/runbooks that still instruct contributors to record on 26.4.1. Preserve historical plans as history.
- [ ] Document exact pins, the hosted macOS 26 / Xcode 27 distinction, local installation/selection, dedicated-simulator usage, recording commands, compatibility commands, and the deliberate beta tradeoff.
- [ ] Search tracked configuration/instructions for old version/build values and review each occurrence. Do not mechanically change every `26` to `27`: deployment minimums must remain 26.

**Phase 1 exit:** both app builds and all package/screenshot suites pass on the asserted 27 trio; the complete baseline migration is reviewed; iOS 26 compatibility has evidence; release-tooling status is explicit. No PCC entitlement, model choice, or default-seeding change is included in this phase.

## Phase 2 — PCC provider, registration, and OS-based defaults

### 1. Prove entitlement and device access before enabling the default

- [ ] Verify developer-account eligibility and request/enable `com.apple.developer.private-cloud-compute` for the intended app identifiers: `com.brianwang.Super` and `com.brianwang.SuperBible`.
- [ ] Add the capability to each target's entitlement configuration in `project.yml`; refresh the necessary profiles through the authorized signing workflow. Never commit certificates, provisioning profiles, keys, or account secrets.
- [ ] Prove an entitled, signed build can perform a small PCC request on a compatible iOS 27 device, including the supported distribution route for each target. Do not assume unsigned simulator success proves service access.
- [ ] If entitlement approval or account eligibility is missing, continue isolated implementation/tests, but **do not ship PCC as the fresh-install default** or claim the feature works. Phase 1 remains independently useful.

### 2. Model identity and provider routing

- [ ] Keep `LLMProviderKind.appleFoundation` and the existing persisted local ID **`system-default`**. Add a distinct app-owned PCC model ID, **`private-cloud-compute`**. These are configuration discriminators, not invented Apple HTTP model names.
- [ ] Add the two variants to `LLMProviderCatalog`. Persist them as ordinary independently selectable/deletable records; no BYOK URL or Keychain reference for either. Existing local rows and custom names are unchanged.
- [ ] Dispatch `makeLLMProvider` by Apple `modelId`. Unknown Apple IDs must fail explicitly as unsupported, never fall through to local. The existing record shape can represent both variants; no database schema change is expected solely for PCC identity.
- [ ] Add an availability-gated Core PCC provider using `PrivateCloudComputeLanguageModel` and `LanguageModelSession(model: ...)`. Keep the local provider explicitly on `SystemLanguageModel`.
- [ ] Reuse the tested transcript conversion, tool bridge, cumulative-stream-to-delta normalization, cancellation, and terminal-event contract where suitable. Keep session construction injectable through the existing `LanguageSession` seam; avoid copying the whole local adapter to change only the backend.
- [ ] Use model-specific context/capability metadata from the chosen SDK rather than the local model's 4K fallback. Validate long transcripts and compaction budgeting. Do not advertise a configurable thinking capability unless the adapter actually wires it; a new reasoning-level UI is not required for this phase.
- [ ] Keep all 27-only types behind explicit availability boundaries, including stored properties, defaults, and static initialization. Shared package tests must still execute on macOS 26; do not use `canImport(FoundationModels)` as a substitute for runtime availability.

Primary files: Core's `LLM/AppleFoundationLLMProvider.swift`, `LLM/AppleFoundationAvailability.swift`, `LLM/LanguageSession.swift`, a new PCC adapter and capability seam, Chat's `LLM/LLMProviderFactory.swift`, `Models/LLMProviderCatalog.swift`, and their tests.

### 3. Separate OS support, readiness, and usage limits

- [ ] Introduce injected, model-specific capability/status reporting usable by the provider factory, Settings, seeding, and shell. Test fixtures provide logical iOS 26/27 states without reading the machine's actual OS.
- [ ] Distinguish unsupported OS, device ineligibility, Apple Intelligence disabled, setup/model not ready, regional/service availability, and transient request failures where the SDK exposes them. PCC must not be gated by the local model download state.
- [ ] Refresh status when entering model settings, returning to the foreground, and before generation; do not retain one launch-time availability snapshot indefinitely. Use observable/awaitable signals, not polling sleeps.
- [ ] Handle quota separately from `isAvailable`. Show concise inline quota/reset information when provided; handle quota exhaustion during a stream, offline/network errors, cancellation, and retryable service failures without corrupting the saved transcript.
- [ ] Preserve the selected model's identity when unavailable. Update hydration/model resolution so skipping it does not invisibly route the request to another registered cloud provider. An unavailable configuration needs an actionable status, not the inaccurate “no model configured” state.
- [ ] Offer an explicit “Use local model” or model-settings action when useful. Do not retry the same prompt on another backend automatically, and do not silently send local-only requests to PCC.

Apple documents dedicated quota state and errors in its [PCC integration guide](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute?changes=latest_major). Map the exact beta SDK declarations at implementation time rather than inventing availability/error enum cases.

### 4. Extend the Apple Intelligence registration page

Reuse the existing Provider → Apple, Model menu in `SettingsModelDetailPane`:

- **Local only** — local model inference; no API key.
- **Private Cloud Compute (PCC)** — cloud inference through Apple; no API key.

On iOS 26, show the second choice disabled and gray, with the suffix immediately following its label:

> Private Cloud Compute (PCC) (only available for iOS 27)

Display this explanatory text on the registration page, not only inside the menu:

> Private Cloud Compute requires iOS 27 or later. On iOS 26, Apple Intelligence uses the on-device model only.

On iOS 27+, omit the OS-restriction suffix, allow either model subject to its own status/duplicate rule, and explain PCC's internet and Apple Intelligence requirements. Show “already added” separately from “unavailable” where applicable. On both OS versions, the Apple provider page must remain reachable even if a model cannot currently be used, so its explanation is discoverable.

- [ ] Replace the one-Apple-row rule with per-variant duplicate checks. One local configuration must not prevent adding PCC, and vice versa. Enforce valid variant/OS/duplicate choices in the save path, not just with disabled UI; serialize concurrent save attempts through a testable seam.
- [ ] In create mode, prefer the OS-appropriate unregistered variant; if it is already registered, offer the other supported variant. Never preselect a disabled choice. In edit mode, preserve the saved variant and record identity; add a second record to use the other variant rather than silently converting an existing one.
- [ ] Make Apple context labels, model status, read-only detail presentation, and persisted creation values variant-aware. Both variants omit URL/API-key fields. Keep cloud/local identity visible in the model list and chat picker even when a user customizes the record name.
- [ ] Preserve native menu/disabled semantics, VoiceOver labels/hints, Dynamic Type reflow, and the repository's typography/theme/glass helpers. Do not rely on gray color alone to communicate the restriction.
- [ ] Review model deletion/“last model” logic and picker/grouping code that currently treats all `.appleFoundation` rows as one model.

Primary files: `SettingsViewModel.swift`, `SettingsModelDetailPane.swift`, `SettingsModelsPane.swift`, `LLMProviderCatalog.swift`, model-row/picker projections, and existing Settings tests/snapshots.

### 5. Wire deterministic fresh-setup defaults in both apps

- [ ] Make the seed helper accept the chosen Apple variant/capabilities as injected input. Resolve OS support in the shared composition path, not from `UIDevice`/process state inside repository logic.
- [ ] On an empty repository, atomically insert **one** selected production model: local on iOS 26, PCC on iOS 27+. Preserve lazy ID allocation, injected clock/IDs, idempotence, and the one-selected-record invariant.
- [ ] Remove the current `if bootAvailability.isAvailable` local-only gate around seeding. Separate persistent default choice from current request readiness, as defined in the product contract.
- [ ] Thread local and PCC capability dependencies consistently through `AppBootstrapSupport`, both app bootstraps/dependency structs, `AppShellDependencies`, `AppShell`, and Settings. Shared app files are explicitly included by both targets in `project.yml`.
- [ ] Hydrate the chosen provider/configuration before exposing the initial chat. Verify both the registry's active selection and the chat picker's persisted selection resolve to the intended model; a selected database flag alone is insufficient.
- [ ] Keep debug seeding after production default seeding. Debug fixtures must not mask the fresh-install choice; verify Release as well as Debug builds.
- [ ] Preserve populated repositories and stored model choices across app/OS upgrades. Adding PCC through Settings follows existing add-versus-select behavior; it must not unexpectedly replace the active model.

**Background/utility model policy:** keep empty-chat suggestions local-first with the existing static fallback. Keep automatic title selection tied to `system-default`; with a PCC-only fresh setup it uses the existing non-generated title fallback unless the user explicitly selects a configured title model. Explicitly selecting PCC for titles is allowed and consumes PCC usage. Do not rename `defaultModelID` to mean PCC or silently redirect auxiliary generations. Document this behavior in the title-setting help text if needed.

### 6. Update privacy and model guidance in the same PR

- [ ] Explain local versus PCC processing on the registration page and show cloud identity before the user's first PCC message. Fresh-install defaulting must not be described as “everything stays on device.”
- [ ] Update [App-SuperBible/PRIVACY.md](../App-SuperBible/PRIVACY.md), `docs/SECURITY.md`, relevant Chat/design documentation, the SuperBible overview/fork spec, and target instructions. Qualify claims about notes, Bible passages, or tool results staying local when those contents can be supplied to the selected cloud model.
- [ ] Document Apple's framework-managed PCC route as the narrow exception to SuperOS's general backend-proxy guidance. This does not authorize a new third-party direct transport or a SuperBible backend.
- [ ] Preserve local persistence, explicit user control over model choice, and content-free Apple-built-in diagnostics. Never log prompts, generated text, tool payloads, or credentials while diagnosing PCC.
- [ ] Validate SuperBible's full persona + enabled tool schemas against PCC's actual context/tool behavior. The target currently documents that the local model cannot fit its full persona; do not promise that PCC fixes this without an end-to-end check, and do not remove the local limitation/disclaimer without evidence.

### 7. Required verification matrix

| Layer | Required cases |
| --- | --- |
| Core provider unit tests | Correct local/PCC construction; independent capabilities/context; cumulative streaming and tools; cancellation; quota/offline/service errors; terminal-event behavior; unsupported API paths never constructed. No real PCC calls. |
| Chat factory tests | `system-default` stays local; PCC routes only to PCC; iOS 26 rejects PCC safely; unknown Apple IDs do not become local; launch and Settings use the same routing. |
| Seeding/repository tests | Empty iOS 26 → local selected; empty iOS 27+ → PCC selected; transient unavailability does not change the OS default; populated local/BYOK/PCC stores untouched; simultaneous/repeated calls produce one seed; no-op consumes no ID. |
| Settings tests | Both variants can coexist; duplicates rejected per variant; disabled PCC cannot save on 26; edit preserves identity; model-specific status/context; deleting one variant leaves the other intact; failures do not leave partial selection state. |
| Selection/orchestration tests | Fresh seed becomes chat selection; unavailable selected PCC does not silently fall back; explicit local switch works; automatic titles/suggestions do not start using PCC; explicit title choice is preserved. |
| UI snapshots on canonical iOS 27 trio | Inject iOS 26 registration with disabled PCC + disclaimer, iOS 27 local/PCC choices, duplicate and unavailable/quota states, and lists with both variants. Vellum light/dark; XXL for new text reflow and relevant font-scale variants. |
| Real iOS 26 compatibility | Both new-compiler-built targets launch, show disabled PCC correctly, preserve local generation, and safely display a seeded/restored unsupported PCC record. No 27 baseline comparisons on 26. |
| Real iOS 27 entitled device | Both targets: fresh default, actual cloud streaming, tool round trip, local-only selection, offline handling, simulated usage limits, relaunch, and existing-install upgrade preservation. |
| Release/distribution | Entitlements present in app and profiles; signed archive/export; successful supported distribution and actual PCC generation. Unsigned simulator tests do not satisfy this gate. |

Run `swift test` locally in every touched package, both app build schemes, and the affected UIKit suites with recording disabled after new snapshots are reviewed. Keep coverage thresholds unchanged and name concrete tests/results in the PR's Test Coverage section. Device validation uses synthetic content, not personal notes or conversations.

**Phase 2 exit:** requested OS-specific defaults and picker behavior work in both targets; existing configured users keep their choices; iOS 26 still runs; unavailable/quota states are truthful; entitlement-backed PCC generation is proven; privacy text and tests ship with the feature.

## Sequencing and rollback

1. Land phase 1 with its pin/baseline change as one coherent migration. Reverting it must revert workflows, local guard, caches, project metadata, and screenshots together.
2. Build phase 2 on that baseline. Keep adapter/status work, Settings/default wiring, and privacy/tests as reviewable commits within the feature PR. Entitlement proof is a release prerequisite, not a reason to mix feature behavior into phase 1.
3. If PCC must be disabled after release, preserve its records and show a clear unavailable state. Do not rewrite them as local or erase user choices. Prefer a forward fix; rolling back to a binary that interprets every `.appleFoundation` row as local is not a safe PCC rollback.

Unresolved implementation prerequisites are limited to the exact hosted iOS 27 simulator build, local parity, account/bundle entitlement access, and signed distribution/device validation. None requires raising the iOS deployment minimum to 27.
