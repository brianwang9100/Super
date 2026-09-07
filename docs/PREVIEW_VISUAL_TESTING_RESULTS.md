# Preview visual testing pilot: results

These are the renderer-only pilot results. Subsequent CLI setup, CI configuration, and upload instructions are in [ARGOS_SETUP.md](ARGOS_SETUP.md).

Status: **renderer blockers fixed; ready for an Argos trial with reviewed new baselines**. The 23 final previews are repeatable, and all 21 composer dimensions match the legacy contract. Small pixel differences from Point-Free remain explicit migration differences. Existing Point-Free suites and PNGs are unchanged and remain authoritative.

## Fixes

- **Fixed collection viewport.** The upstream renderer installed a fixed height constraint, then expanded scroll content anyway and compressed it during capture. The test-only `renderer.patch` disables expansion for fixed layouts. The real UICollectionViewController now shows three normal-sized rows within 402×180pt, with the remaining rows offscreen. Both UIKit probes remain 1206×540 pixels.
- **Stable recording ring.** A Debug-only `ChatComposerPreviewPulse` environment value holds the ring at phase 0: scale 1, opacity 0.6. It prevents the repeating animation from starting in previews while preserving the visible ring. Nil preserves live behavior; Reduce Motion still hides the ring. The existing snapshot fixtures do not inject this value.
- **Fractional intrinsic height restored.** Point-Free proposes `.zero` to `UIHostingController.sizeThatFits`; the upstream renderer proposed the full screen. Instrumentation measured 117⅓pt versus 118pt for maximum font scale + XXL. The local patch uses the minimum fitting proposal and exact fractional constraints for `.sizeThatFits`. The result is 1206×352 again, without hard-coding the composer height, cropping, or resizing PNGs. Default/device sizing retains its upstream behavior.
- **Dimension and repeatability gates.** Export validation now checks every scenario's exact dimensions. Two final complete exports contain 23/23 byte-identical PNGs, which also proves identical decoded pixels. The reusable repeatability check fails on any missing or changed image.

The renderer is pinned to upstream revision `856a1c1585e31d4113c019050d6d0712cf6ddadc` plus the checked-in patch. Preparation verifies the revision and tracked diff, and each run records the patch digest. This remains a local test dependency; no production package graph includes it.

## Verification

| Check | Result |
|---|---|
| Discovery and export | Exactly 21 composer previews + 2 UIKit probes |
| Final repeat capture | 23/23 byte-identical PNGs |
| Legacy dimensions | 21/21 match |
| Legacy pixel equivalence | 0 exact, 21 pixel mismatches; no relaxed tolerance |
| Chat macOS package | 1,069 tests in 85 suites pass |
| Core macOS package, initial pilot | 312 tests in 38 suites pass |
| Existing iOS composer suite after fix | All 21 pass; no re-recording |
| Renderer layout regressions | Both fail against unpatched upstream and pass with the patch |
| Python discovery/dimension guards | All 7 pass |
| Production app builds after fix | Super and SuperBible, Debug and Release, all pass |
| Release binary audit | No preview fixtures, renderer, Sentry, or Argos runtime markers |
| Targeted strict SwiftLint | Pass with cache disabled |

The environment is Xcode 26.4.1 / 17E202, iOS 26.4.1 / 23E254a, dedicated iPhone 17 `SB-e7c6-preview-pilot` (`38E8D196-82FC-4741-87CB-E306C36005F8`), at 3×. Runtime disk inspection confirms no stale 26.4 build. Release auditing covered simulator binaries; inspect signed device archives again before cutover.

Manual inspection confirms the collection rows, recording ring, and maximum-scale XXL layout. The initial pilot also inspected light/dark, reference-pill XXL, Reduce Motion, and the UIKit custom-font panel. Every capture validates all five bundled fonts. Static pulse snapshots complement behavioral animation tests; they do not test timing.

## New-baseline candidates and remaining pixel differences

The fresh PNG-only candidate directory is `.build/PreviewPilot/run-zxx_or45/argos-candidates/`. It contains all 23 images. `Scripts/PreviewPilot/candidate-manifest.json` records their hashes, revision, and patch identity. These are local candidates for the new renderer, not replacements written into legacy `__Snapshots__` and not an Argos baseline already uploaded or approved.

The UIKit hierarchy renderer still differs from Point-Free's layer capture in gradients, antialiasing, placeholder appearance, and control edges. The pinned recording phase is also now explicit. The user authorized accepting slight renderer differences as new baselines after fixing the structural/stability problems; those problems are resolved. The exact comparator continues to report every difference rather than hiding them behind tolerance. Review the initial Argos baseline as a complete set.

## Evidence and reproduction

- Final captures: `.build/PreviewPilot/run-80jdufly/` and `run-zxx_or45/`, each with names, images, sidecars, environment, logs, and xcresults. The second export passes 25 XCTest cases: 23 captures plus 2 layout regressions.
- Checked-in reports: `Scripts/PreviewPilot/parity-report.json`, `repeatability-report.json`, `release-audit.json`, and `candidate-manifest.json`.
- Before/after regression controls: `.build/PreviewPilot/layout-before-fix.log` (2 tests, 3 expected assertion failures) and `layout-after-fix.log` (2 tests pass). The exact patch was restored and verified afterward.
- Chat tests: `.build/chat-fix-tests.log`; unchanged legacy snapshots: `.build/legacy-composer-fix-tests.log`; production builds: `.build/fix-{Super,SuperBible}-{Debug,Release}.log`.
- Initial failure evidence remains in `run-qww6ljcu` and `run-g1uucjqb`: squeezed collection, 354px XXL, and dark recording instability. Intermediate `run-c9cm8sgg` and `run-pf57oemz` already repeat identically after the pulse fix and retain fitting-proposal diagnostics.

```sh
python3 Scripts/PreviewPilot/run.py 38E8D196-82FC-4741-87CB-E306C36005F8
python3 Scripts/PreviewPilot/repeatability.py FIRST_RUN/images SECOND_RUN/images REPORT.json
python3 -m unittest discover -s Scripts/PreviewPilot -p 'test_*.py'
```

The local driver's final legacy-parity exit remains nonzero intentionally. Successful export, stable new images, and equivalence to the old renderer are separate checks. The Argos plan describes an explicit migration mode for CI rather than swallowing this failure.

## Argos next step

Follow [ARGOS_SETUP.md](ARGOS_SETUP.md): connect the repository, enable GitHub OIDC, add a pinned non-required upload workflow, seed an actual main-branch build, review all 23 images, and validate trial PR failures and approvals. Start with the pilot's small quota footprint, then expand coverage package by package. No account, secret, upload, PR, or branch protection action was performed. The original inventory remains 63 UI suite files / 543 snapshot PNGs / 8 pre-existing previews.
