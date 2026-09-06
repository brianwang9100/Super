# Preview visual testing: foundation and ChatComposer pilot

Historical renderer pilot, 2026-09-06. The subsequent authorized CLI integration and current commands are documented in [ARGOS_SETUP.md](ARGOS_SETUP.md). At the end of the renderer-only pilot: Point-Free image tests remain authoritative. No baseline, existing suite, required check, branch protection, account, secret, or upload is changed. This document proposes the eventual architecture; it does not revise global conventions or authorize deletion.

## Architecture and boundaries

Named `#Preview` declarations become the only UI visual-scenario declarations after migration. SwiftUI and UIKit previews use deterministic fixtures in their owning package, guarded end-to-end by `#if DEBUG && canImport(UIKit)`. They never import a test target. The renderer discovers those declarations; neither the XCTest runner nor Argos constructs scenarios. An expected-name manifest is a coverage contract, not another scenario factory.

The pilot adds an isolated XcodeGen project at `Scripts/PreviewPilot/project.yml`. Its minimal application host links Chat and Core without starting services, accessing credentials, or opening databases. Only its XCTest target links `SnapshottingTests`. Production package manifests and `project.yml` have no vendor dependency. Xcode generates this project and its outputs under `.build/PreviewPilot`; it cannot record into `__Snapshots__`. No production Sentry, Argos, gallery, or capture runtime is introduced.

Swift Testing continues to test behavior, interactions, concurrency, and animation correctness. The existing injectable composer morph `progress` stays intact. Static pictures at 0, 0.15, and 1 do not prove timing, hit testing, focus, cancellation, or intermediate motion. GRDBSnapshotTesting remains the database/schema boundary, including any SnapshotTesting dependencies it requires. Eventually remove only UI image assertions/dependencies that are no longer needed, never database snapshots by keyword or dependency name.

## Inventory and identity

The checked-in `Scripts/PreviewPilot/repository-inventory.json` records the pre-pilot inventory: **63 UI suite files, 543 snapshot PNGs, 8 existing #Preview declarations**. Counted tracked `Packages/**/UI/*SnapshotTests.swift` files and tracked PNGs under `__Snapshots__`, rather than all PNGs (554 including app assets). The inventory lists every path so the counts can be reproduced and audited.

Existing previews: Core's SplashView has Vellum Light, Vellum Dark, and Lapis Light; SuperOSContentView has loading and failed; BibleScreen, BibleBookSheet, and BibleTranslationSheet each have an unnamed preview. These are not automatically enrolled. Unnamed previews must receive stable names before migration; SplashView's third-family scenario belongs in the future theme gallery coverage, not a new per-screen matrix.

`Scripts/PreviewPilot/composer-inventory.json` maps all **21** old image paths to unique proposed/exported names and records dimensions, scale, text, theme, Dynamic Type, font scale, Reduce Motion override, recording/mic/streaming state, references, progress, token counts, tolerance, and baseline SHA-256. It is the full mapping; no baseline is inferred from a previous count.

The naming contract for this pilot is:

- Declaration: `#Preview("composer_empty_light", ...)` in `ChatComposerPreviews.swift`.
- Discovery identity: `Chat/ChatComposerPreviews.swift:composer_empty_light`.
- PNG: `Chat_ChatComposerPreviews.swift_composer_empty_light.png`.
- UIKit identity: `Core/PreviewCollectionController.swift:collection_viewport_light`.

The module, filename, and display name are part of identity. Moving declarations to a differently named file is a migration, not a harmless refactor. Unique ASCII names avoid sanitizer collisions; never rely on source lines, macro-mangled types, array order, or generated duplicate ordinals. The pinned renderer sanitizes the file ID plus display name into the exported basename. Its all-name writer deduplicates, so source-name uniqueness must also be checked. Keep legacy-to-preview mappings until a reviewer has accepted complete coverage and baseline history continuity.

## Fixture and variant conventions

`PreviewChatComposer` owns a false `@FocusState`, constant text binding, the GPT-4o model fixture, and inert callbacks. It lives in Chat to access the internal Reduce Motion seam. No production access-control changes are necessary. The old private `FocusHostingChatComposer` is deliberately untouched during dual-running; remove it only when its old suite is explicitly retired. Preview declarations pass scenario values directly; the JSON mapping does not drive the preview implementation. Use `@Previewable` for state local to a declaration when useful; the shared focus-owning wrapper avoids repeating that declaration 21 times here.

Each composer captures a 402pt width with size-that-fits height at 3×. PNG heights range from 228 to 447 pixels; fractional point heights are retained, not rounded into a new baseline. Default Dynamic Type is explicitly `.large`; XXL is `.xxLarge`. Font-scale variants inject both ChatAppearance and SuperTypography at 1.20. All other fixtures use 1.0. Default morph progress is 1; pill variants use 0; mid-morph uses 0.15. The legacy repeating recording pulse has no explicitly fixed capture phase; its initial/target values and 1.2-second duration are recorded in the inventory. Preview fixtures inject a Debug-only phase of 0 (scale 1, opacity 0.6), preserving a visible ring without starting its repeating animation. Nil keeps the original animation path; Reduce Motion still hides the overlay. Two final complete exports are byte-identical for all 23 PNGs. The recording Reduce Motion case sets the internal override true; other cases retain nil/system behavior. No microphone permission or recognition is used.

The 21 scenarios include empty light/dark; typed; streaming; near-max context; recording light/dark/XXL/Reduce Motion; unavailable mic; pill light/dark; mid-morph; typed XXL; font-scale light/dark/XXL; single reference light/dark/XXL; and multiple references. Every legacy composer comparison uses precision 1 and perceptual precision 1 (no exception). Preserve global 0.99/0.97 custom-font exceptions when migrating other suites; these numbers are not interchangeable with a service's changed-pixel threshold.

## Fonts, glass, and UIKit

Register Core's bundled fonts before any render. The host registers them, fixtures register idempotently for standalone Xcode preview use, and every dynamically rendered test verifies all four EB Garamond faces plus JetBrainsMono-Regular via UIFont lookup. A missing face fails the run. The fixture explicitly supplies the legacy white hosting background even in dark-theme scenarios; this corrects a black-background difference without changing the source baselines. The non-scrolling UIKit font panel displays EB Garamond and JetBrains Mono through SuperTypography; the collection probe displays system body text and monospaced row numbers.

`PreviewCollectionController` returns a real UICollectionViewController from `#Preview`, with 12 deterministic rows and a fixed 402×180pt viewport. The unpatched renderer expanded this collection and compressed it into the requested height. The checked-in test-only patch now disables expansion for fixed layouts; the verified output shows three normal-sized rows in the viewport, with the remaining content offscreen. The separate `font_panel_light` UIViewController preview proves the non-scrolling UIKit bridge without that distortion. The verified collection contract captures the viewport: fixed geometry, known content offset, stable item IDs, no async data source, self-sizing layout settled before capture. Future scrolled, populated, empty, loading, and error states need named scenarios, with explicit completion signals for asynchronous layout. More complex diffable-data-source and reuse behavior remains a behavioral test concern.

Both old and new XCTest processes activate SuperGlass's existing solid fallback. Xcode Canvas does not necessarily link XCTest and can show real glass. Therefore Canvas is the scenario authoring surface, not a promise of byte-identical glass rendering. A future unification must make this policy explicit without changing production glass or silently swapping baseline behavior.

## Reviewed renderer and discovery risks

Pinned [getsentry/SnapshotPreviews commit 856a1c1585e31d4113c019050d6d0712cf6ddadc](https://github.com/getsentry/SnapshotPreviews/tree/856a1c1585e31d4113c019050d6d0712cf6ddadc), an immutable revision rather than a moving branch. Reviewed Package.swift, SnapshotTest, PreviewBaseTest, FindPreviews, UIKitRenderingStrategy, filename resolution, all-name writing, and PNG/sidecar export. The package declares exact FlyingFox 0.16.0 and SimpleDebugger 1.0.0 dependencies. SnapshottingTests links SimpleDebugger through its Objective-C support; FlyingFox belongs to the unselected SnapshottingSwift server product. No server/gallery product is selected.

`prepare_renderer.py` materializes that revision plus `renderer.patch` into an ignored, content-addressed local checkout. The driver overrides only the pilot test package reference. The patch disables scroll expansion for fixed layouts and gives `.sizeThatFits` a minimum (`.zero`) fitting proposal with exact fractional constraints, matching Point-Free's contract. The original screen-sized proposal produced 118pt rather than 117⅓pt for XXL; the patch restores 352 pixels without cropping. Each run records the patch SHA-256. The local checkout's revision and complete tracked diff must match before reuse. Keep this patch explicit until a reviewed upstream equivalent is available; upgrading requires rerunning the layout regressions and capture matrix.

The package also includes a **precompiled PreviewsSupport.xcframework**. Source-level review is consequently incomplete for that binary. It is confined to the pilot test process. Discovery examines runtime preview conformances and uses unsafe runtime access; XCTest selectors are injected dynamically through Objective-C swizzling. Toolchain changes, dead stripping, static package linkage, Xcode's discovery phase, or duplicate identities can produce zero/partial tests while xcodebuild reports success. This is why a green test process alone is insufficient.

The runner explicitly limits modules to Chat/Core and filters file/display identities to the pilot. Run one discovery subclass and disable parallel testing: upstream maintains process-global preview state. Do not add several subclasses concurrently without auditing that behavior. Export defaults to a live UIKit hierarchy with animations disabled and layout settling; Point-Free's renderer can differ in rasterization, background, safe areas, layout proposal, and animation phase. Investigate parity before adopting tolerances.

## Fail-closed local workflow

Use Xcode **26.4.1 / 17E202**, iOS **26.4.1 / 23E254a**, and an **iPhone 17** at **3×**. XcodeGen is **2.45.4**. The driver verifies versions and the dedicated device's runtime, type, name, and availability before any capture. It refuses missing or mismatched pins. Keep only build 23E254a for the conflated iOS-26-4 identifier. Other iOS minor runtimes are not selected.

Create a per-worktree simulator once (substitute the worktree name):

```sh
xcrun simctl create SB-e7c6-preview-pilot 'iPhone 17' com.apple.CoreSimulator.SimRuntime.iOS-26-4
python3 Scripts/PreviewPilot/run.py <returned-UUID>
```

Keep this simulator while the branch is in flight; delete only after an eventual merge or explicit cleanup request. The driver creates a fresh run directory; no stale successful export can satisfy a subsequent run. It saves environment metadata, logs, xcresults, names, PNGs, JSON sidecars, and parity results. A capture/validation failure stops the workflow; pixel parity failure deliberately leaves a nonzero final exit.

1. `TEST_RUNNER_SNAPSHOTS_ALL_IMAGE_NAMES_FILE` makes SnapshotTest write the discovered names and return without rendering.
2. `verify.py --names` requires exactly the 21 mapped images plus both UIKit probes. Empty, duplicate, missing, renamed, and unexpected names fail.
3. A separate invocation uses `TEST_RUNNER_SNAPSHOTS_EXPORT_DIR`. Never combine these environment variables: names mode suppresses rendering.
4. `verify.py --exports` verifies the inventory, PNG headers, exact width/height for all 23 scenarios, and sidecar presence/identity. The native Swift comparer decodes every PNG and checks exact dimensions and normalized premultiplied sRGB pixels against the unchanged committed baseline. It writes a row for every baseline and exits nonzero on any mismatch or unreadable image. No automatic resizing, tolerance relaxation, or re-recording. Extra diagnostic metrics (including differences above two channel units) do not alter the pass criterion.
5. `audit_release.py` inspects app contents plus Mach-O symbols, linked libraries, and strings for preview fixtures or vendor runtime markers. Repeat on archives before eventual cutover.

`python3 -m unittest discover -s Scripts/PreviewPilot -p 'test_*.py'` covers false-green inventory and dimension paths. `repeatability.py FIRST_EXPORT SECOND_EXPORT REPORT_JSON` requires complete, byte-identical PNG sets. The pilot also runs two renderer layout regression tests during export. This local script is the CI prototype. It has no trigger, required status, or external upload. A later separately callable workflow should preserve all current required checks while dual-running.

## Future Argos account and CI flow (not performed)

The concrete onboarding and workflow implementation plan is in [ARGOS_SETUP.md](ARGOS_SETUP.md).

Argos owns storage, comparison, review, and ultimately a blocking PR status; SnapshotPreviews supplies ordinary PNGs. Its Sentry JSON sidecars are local evidence, **not an Argos tolerance configuration**. Upload only the verified PNG directory or an explicit PNG file glob. Preserve the exact manifest as an artifact. Do not send fixture metadata accidentally as additional file snapshots.

After explicit approval:

1. A maintainer creates/connects the Argos project and installs its GitHub integration for this repository. Set the intended default baseline branch and identify the actual PR status name using a trial PR; do not guess it in branch protection.
2. Prefer [GitHub OIDC authentication](https://argos-ci.com/docs/learn/integrations/github-oidc-authentication): enable it in Argos Project Settings → Authentication, give the upload job `id-token: write`, and leave ARGOS_TOKEN unset. The [tokenless fallback](https://argos-ci.com/docs/learn/integrations/github-tokenless-authentication) supports fork PRs by validating an in-progress GitHub workflow; pass project slug when multiple projects share a repo and GITHUB_TOKEN for PR metadata. Validate internal and fork PR paths before relying on the check.
3. Pin the reviewed [Argos CLI](https://argos-ci.com/docs/reference/argos-command-line-interface-cli) version in a lockfile (candidate researched: `@argos-ci/cli@6.9.2`; not installed in this pilot). The future command shape is `argos upload <verified-PNG-directory> --project <account/project>` after successful capture and inventory verification. Capture on the pinned simulator; upload only after the full manifest is present. Use correct head/base commit metadata, handle merge commits deliberately, and verify a missing/failed upload cannot leave a green visual gate.
4. Seed and manually review the initial baseline. Validate additions, removals, changed pixels, failed discovery, failed render, upload failure, and review rejection. Only after a dual-run proves authority should a maintainer make the observed Argos status blocking. Existing checks stay required until separately authorized retirement.
5. Apply for [open-source sponsorship](https://argos-ci.com/docs/learn/billing-and-subscription/subscription/open-source) if needed. Argos evaluates applications individually: non-commercial open source, reasonable use, README banner plus dofollow link and team-specific UTM tag. A maintainer must approve those public branding changes and email contact@argos-ci.com with team slug, repository, qualification confirmation, and why Hobby is insufficient. Current [pricing](https://argos-ci.com/pricing) lists 5,000 Hobby screenshots; 543 images × 10 full runs already exceeds that. Approval and quota are not assumed.

## Migration phases and exit gate

1. Finish this non-destructive pilot: prove discovery, stable export identities, UIKit capture, deterministic fonts, repeatability, image parity, and Release isolation. Resolve every mismatch or document an explicit reviewed migration decision.
2. Migrate Core primitives/theme gallery, then Chat package-by-package, then Bible and Todo. Before each package, inventory **all** current variants and special tolerances, including platform form factors and Reduce Motion; retain old coverage during dual-running. Never expand every screen to all eight theme variants.
3. Connect Argos and exercise the failure cases above without removing current authority. Check usage/sponsorship, permissions, baseline branch, PR attribution, and reviewer ownership.
4. After separate authorization, remove migrated Point-Free UI suites and PNGs only when a one-to-one coverage manifest and required Argos gate are proven. Retain Swift Testing behavior/animation suites and GRDB schema snapshots. Remove orphaned UI fixtures, record toggles, UI-only dependencies and scheme paths; update global documentation then.
5. Inspect both Release artifacts again, including embedded frameworks/resources and static symbols. Archive validation is stronger than simulator linkage alone and belongs in the final release gate.

Evidence and recommendation are recorded in `PREVIEW_VISUAL_TESTING_RESULTS.md` alongside the machine-readable parity report. The fixed renderer is ready for a reviewed new-baseline trial. Pixel equivalence to Point-Free is not claimed; existing UI suites remain authoritative during onboarding.
