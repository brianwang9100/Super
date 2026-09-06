# Super: CI/CD Pipeline

> Continuous integration and deployment architecture. The [root delivery workflow](../AGENTS.md#delivery-workflow) defines planning, reviews, PR monitoring, and merge authorization.

**Prerequisite reading:** [MOBILE_ARCHITECTURE.md](./MOBILE_ARCHITECTURE.md) for the monorepo structure and Swift Package layout, [SERVER_ARCHITECTURE.md](./SERVER_ARCHITECTURE.md) for the server stack.

## Implemented pipeline

| Surface | Current behavior |
|---|---|
| [Swift Tests](../.github/workflows/swift-test.yml) | Discovers Swift packages, runs package suites with coverage, and reports the aggregate `swift-test` check. |
| [iOS Build](../.github/workflows/ios-build.yml) | Builds both `Super` and `SuperBible`, discovers package test schemes for simulator suites, and reports aggregate `build`/`ios-test` checks. |
| [SwiftLint](../.github/workflows/swiftlint.yml) and [secret scanning](../.github/workflows/secrets-scan.yml) | Report `lint` and `gitleaks`. |
| [TestFlight](../.github/workflows/testflight.yml) | Archives and uploads SuperOS only (`Super` scheme). SuperBible release support is not implemented. |
| Native Codex review | Runs through the GitHub integration, separately from Actions; see [§6.3](#63-native-codex-pull-request-review). |

Build/test workflows keep their aggregate checks reporting on documentation-only
PRs while skipping expensive jobs when their change filters permit. Exact
Xcode/runtime pins and local verification live in [TESTING.md](TESTING.md).

The legacy client pipeline example in §4.1, server CI/deployment, and Codecov
gating below remain roadmap material. Inspect
live branch protection for the current required checks; [§6.4](#64-ci-and-review-gates)
records the delivery check, not a replacement for repository settings.

---

## 1. Goals & Philosophy

The [root delivery workflow](../AGENTS.md#delivery-workflow) is the canonical
agent process. CI supplies build, test, lint, and secret-scanning gates; explicit
Codex approval of the current revision authorizes the agent to enable auto-merge
once applicable CI passes. User instructions can narrow that authorization.

## 2. Pipeline Architecture

Implemented jobs live in [`.github/workflows/`](../.github/workflows/). Native
Codex review is separate from GitHub Actions. Server CI and deployment examples
below describe planned infrastructure, not additional delivery requirements.

## 3. CI Platform Choice

| Criteria | GitHub Actions | Xcode Cloud |
|----------|---------------|-------------|
| **iOS/macOS builds** | Supported (macOS runners with Xcode) | Native, first-party |
| **Server builds** | Full support (Linux/Docker) | Not supported |
| **Customization** | Full — arbitrary scripts, Docker, matrix builds | Limited to Apple's predefined steps |
| **AI reviewer integration** | Trivial — just another workflow step | Not possible |
| **Cost control** | Granular (per-minute billing, self-hosted option) | Included with Apple Developer account (25 hrs/mo) |
| **Secrets management** | GitHub Secrets, OIDC, Vault integration | Limited to Xcode Cloud environment |
| **Monorepo support** | Excellent (path filters, conditional jobs) | Poor (one workflow per Xcode project) |
| **Community ecosystem** | Massive (thousands of actions) | None |

**Decision: GitHub Actions is the primary CI platform.**

Xcode Cloud's 25 free compute hours per month are appealing, but its inability to run server-side builds, limited customization, and lack of webhook/API integration for AI reviewer agents make it unsuitable as the primary pipeline. Xcode Cloud may be used as a **supplementary** pipeline for TestFlight distribution if its simplicity proves valuable, but all quality gates run on GitHub Actions.

---

## 4. Client Pipeline (iOS/macOS)

### 4.1 Workflow Overview (Unimplemented Legacy Proposal)

This example is historical roadmap material: `client-ci.yml`, its toolchain,
platform matrix, and UI-test scheme are not implemented. Use the workflow links
in [Implemented pipeline](#implemented-pipeline) for current behavior.

The client pipeline runs on every PR that touches files under `Packages/`, `Super/`, or `Super.xcodeproj/`.

```yaml
# .github/workflows/client-ci.yml
name: Client CI

on:
  pull_request:
    paths:
      - 'Packages/**'
      - 'Super/**'
      - 'Super.xcodeproj/**'
      - '.github/workflows/client-ci.yml'

concurrency:
  group: client-ci-${{ github.head_ref }}
  cancel-in-progress: true

env:
  XCODE_VERSION: '16.2'
  DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      applets: ${{ steps.changes.outputs.applets }}
    steps:
      - uses: actions/checkout@v4
      - id: changes
        name: Detect changed applets
        run: |
          # Compare against base branch to find changed packages
          CHANGED=$(git diff --name-only origin/${{ github.base_ref }}...HEAD \
            | grep '^Packages/' \
            | cut -d'/' -f2 \
            | sort -u \
            | jq -R -s -c 'split("\n") | map(select(. != ""))')
          echo "applets=$CHANGED" >> "$GITHUB_OUTPUT"

  swiftlint:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Install SwiftLint
        run: brew install swiftlint
      - name: Run SwiftLint
        run: swiftlint lint --strict --reporter github-actions-logging

  build:
    needs: [detect-changes]
    runs-on: macos-26
    strategy:
      matrix:
        platform: [iOS, macOS]
        configuration: [Debug, Release]
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s $DEVELOPER_DIR
      - name: Resolve packages
        run: xcodebuild -resolvePackageDependencies -project Super.xcodeproj
      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: ~/Library/Developer/Xcode/DerivedData/**/SourcePackages
          key: spm-${{ runner.os }}-${{ hashFiles('**/Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-
      - name: Build
        run: |
          DESTINATION=${{ matrix.platform == 'iOS'
            && 'platform=iOS Simulator,name=iPhone 16,OS=latest'
            || 'platform=macOS' }}
          xcodebuild build \
            -project Super.xcodeproj \
            -scheme Super \
            -configuration ${{ matrix.configuration }} \
            -destination "$DESTINATION" \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO \
            | xcbeautify

  test-applets:
    needs: [detect-changes]
    if: needs.detect-changes.outputs.applets != '[]'
    runs-on: macos-26
    strategy:
      fail-fast: false
      matrix:
        applet: ${{ fromJson(needs.detect-changes.outputs.applets) }}
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s $DEVELOPER_DIR
      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: ~/Library/Developer/Xcode/DerivedData/**/SourcePackages
          key: spm-${{ runner.os }}-${{ hashFiles('**/Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-
      - name: Test ${{ matrix.applet }}
        run: |
          cd Packages/${{ matrix.applet }}
          swift test --enable-code-coverage 2>&1 | xcbeautify
      - name: Generate coverage report
        run: |
          cd Packages/${{ matrix.applet }}
          xcrun llvm-cov export \
            .build/debug/${{ matrix.applet }}PackageTests.xctest/Contents/MacOS/${{ matrix.applet }}PackageTests \
            -instr-profile .build/debug/codecov/default.profdata \
            -format lcov > coverage.lcov
      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: Packages/${{ matrix.applet }}/coverage.lcov
          flags: ${{ matrix.applet }}

  test-core:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s $DEVELOPER_DIR
      - name: Test Core package
        run: |
          cd Packages/Core
          swift test --enable-code-coverage 2>&1 | xcbeautify
      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          flags: Core

  ui-tests:
    needs: [build]
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s $DEVELOPER_DIR
      - name: Run UI Tests (critical flows)
        run: |
          xcodebuild test \
            -project Super.xcodeproj \
            -scheme Super-UITests \
            -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
            -only-testing:SuperUITests/CriticalFlows \
            CODE_SIGNING_ALLOWED=NO \
            | xcbeautify
```

### 4.2 Xcode/Simulator Setup on GitHub Actions

The implemented pins and runtime assertions live in
[ios-build.yml](../.github/workflows/ios-build.yml). Local setup, exact-build
matching, recording, and simulator lifecycle are documented once in
[TESTING.md](TESTING.md#simulator-environment).

### 4.3 Code Coverage Requirements

[TESTING.md](TESTING.md#required-coverage) owns the coverage floors and required
tests. The checked-in Swift workflow prints coverage summaries; Codecov status
checks remain part of the planned pipeline below.

---

## 5. Server Pipeline (TypeScript)

### 5.1 Workflow Overview

```yaml
# .github/workflows/server-ci.yml
name: Server CI

on:
  pull_request:
    paths:
      - 'server/**'
      - '.github/workflows/server-ci.yml'

concurrency:
  group: server-ci-${{ github.head_ref }}
  cancel-in-progress: true

jobs:
  lint-and-typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'pnpm'
      - run: corepack enable && pnpm install --frozen-lockfile
        working-directory: server
      - name: ESLint
        run: pnpm lint
        working-directory: server
      - name: TypeScript strict check
        run: pnpm tsc --noEmit
        working-directory: server

  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'pnpm'
      - run: corepack enable && pnpm install --frozen-lockfile
        working-directory: server
      - name: Unit tests
        run: pnpm test:unit --coverage
        working-directory: server
      - name: Upload coverage
        uses: codecov/codecov-action@v4
        with:
          files: server/coverage/lcov.info
          flags: server

  integration-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_USER: super
          POSTGRES_PASSWORD: test
          POSTGRES_DB: super_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd="pg_isready"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5
      redis:
        image: redis:7
        ports:
          - 6379:6379
        options: >-
          --health-cmd="redis-cli ping"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'pnpm'
      - run: corepack enable && pnpm install --frozen-lockfile
        working-directory: server
      - name: Run migrations
        run: pnpm db:migrate
        working-directory: server
        env:
          DATABASE_URL: postgresql://super:test@localhost:5432/super_test
      - name: Integration tests
        run: pnpm test:integration
        working-directory: server
        env:
          DATABASE_URL: postgresql://super:test@localhost:5432/super_test
          REDIS_URL: redis://localhost:6379

  docker-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Build Docker image
        uses: docker/build-push-action@v6
        with:
          context: ./server
          push: false
          tags: super-server:pr-${{ github.event.pull_request.number }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### 5.2 Test Framework

- **Vitest** for both unit and integration tests (native ESM, fast, TypeScript-first).
- Unit tests mock all external dependencies (database, Redis, APIs).
- Integration tests use GitHub Actions service containers for real Postgres and Redis.
- Server minimum coverage target: **80%**.

---

## 6. AI Agent Workflow

### 6.1 Branch Naming Convention

Use `codex/<short-description>` for Codex implementation branches unless the user
requests a different name.

### 6.2 How Agents Open PRs

Follow the [root delivery workflow](../AGENTS.md#delivery-workflow) and use the
[PR template](../.github/pull_request_template.md) as the single description
format. Its **Test Coverage** section names the new/updated tests and local
results required by [TESTING.md](TESTING.md). Include visual evidence for UI
changes. With `gh pr create`, pass the prepared description using `--body-file`.

### 6.3 Native Codex Pull-Request Review

Connect this repository to Codex cloud and enable automatic reviews in the Codex GitHub integration. Codex then reviews eligible pull requests automatically; a contributor can also request a fresh review by commenting `@codex review` on the pull request. The root [`AGENTS.md`](../AGENTS.md) supplies the canonical review criteria, and nested module instructions add file-specific requirements.

Codex findings appear as normal GitHub pull-request review comments, inline when a precise location is available and otherwise as a review summary. They are separate from GitHub Actions checks. Address actionable findings and obtain explicit approval covering the current revision before following the [root auto-merge workflow](../AGENTS.md#delivery-workflow); silence or approval of an older revision is insufficient.

For that approval gate, require a clean Codex verdict naming the current commit,
or a Codex 👍 tied to a review request for that commit. Record the requested head
SHA; subsequent pushes invalidate that signal. A pending-review acknowledgment
or an approval from another reviewer does not satisfy the Codex gate.

### 6.4 CI and Review Gates

Check live branch protection/rules and PR checks when delivering. `main` currently
requires `build`, `lint`, `gitleaks`, `ios-test`, and `swift-test`. Native Codex
approval is a separate agent-enforced gate, not one of those Actions checks.
Wait for applicable CI to pass even if protection does not enforce a particular
check. Do not bypass or weaken repository protections to complete a PR.

## 7. Branch Strategy

`main` receives reviewed PRs through the [delivery workflow](../AGENTS.md#delivery-workflow).
Use feature branches for implementation. After verifying a PR is merged, its
clean worktree may be removed; clean up its registered simulator using the
[worktree lifecycle procedure](TESTING.md#worktree-simulator-lifecycle).
GitHub may delete the remote branch automatically. Inspect live
repository rules rather than relying on a copied branch-protection checklist.

## 8. Test Strategy in CI

### 8.1 Tests as the Safety Net

When AI agents write code autonomously, tests are the **primary mechanism for catching regressions.** A strong test suite means an agent can make changes confidently, and CI will catch mistakes before a human ever looks at the code.

This inverts the usual relationship: tests are not written to satisfy a coverage metric. They are written because **without them, autonomous agents are unsafe.**

### 8.2 Coverage Requirements

| Target | Minimum | Enforced By |
|--------|---------|-------------|
| Core package | 80% | Codecov status check |
| Each applet package | 70% | Codecov status check |
| Server (overall) | 80% | Codecov status check |
| UI tests | N/A | Critical flow pass/fail |

Coverage must not decrease on any PR. If new code is added, new tests must accompany it.

### 8.3 Parallelization Strategy

```
test-applets job (matrix):
  ├── Chat   ─── swift test (parallel)
  ├── Calendar     ─── swift test (parallel)
  ├── ToDo      ─── swift test (parallel)
  ├── Home    ─── swift test (parallel)
  └── Core       ─── swift test (parallel)

server jobs (parallel):
  ├── unit-tests
  └── integration-tests
```

Each Swift Package runs `swift test` independently. The `detect-changes` job ensures only modified packages are tested on a given PR, but all packages are tested on merge to `main`.

### 8.4 Flaky Test Detection and Quarantine

- Tests that fail intermittently degrade trust in CI and slow down agents.
- **Detection:** Track test results over the last 20 runs. A test that passes >80% but <100% of the time is flagged as flaky.
- **Quarantine:** Flaky tests are moved to a `@Tag("quarantined")` group (Swift) or `.skip()` with a tracking issue (TypeScript). They still run but do not block merge.
- **Resolution:** Flaky tests generate a task for an agent to investigate and fix. Quarantined tests that are not fixed within 2 weeks are deleted and rewritten.

---

## 9. Deployment Pipeline

### 9.1 Server Deployment

```yaml
# .github/workflows/deploy-server.yml
name: Deploy Server

on:
  push:
    branches: [main]
    paths:
      - 'server/**'

jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - name: Build and push Docker image
        run: |
          docker build -t super-server:${{ github.sha }} ./server
          docker tag super-server:${{ github.sha }} \
            ${{ secrets.REGISTRY_URL }}/super-server:${{ github.sha }}
          docker push ${{ secrets.REGISTRY_URL }}/super-server:${{ github.sha }}
      - name: Deploy to staging
        run: |
          # Deploy via your preferred method (Fly.io, Railway, AWS ECS, etc.)
          # Example using Fly.io:
          flyctl deploy --image ${{ secrets.REGISTRY_URL }}/super-server:${{ github.sha }}
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

  promote-production:
    needs: [deploy-staging]
    runs-on: ubuntu-latest
    environment:
      name: production
      # Manual approval required in GitHub environment settings
    steps:
      - name: Promote to production
        run: |
          flyctl deploy --image ${{ secrets.REGISTRY_URL }}/super-server:${{ github.sha }} \
            --app super-production
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

**Flow:** Merge to main --> auto-deploy to staging --> manual promotion to production (via GitHub environment protection rules).

### 9.2 Client Deployment (TestFlight)

The workflow lives at [`.github/workflows/testflight.yml`](../.github/workflows/testflight.yml). It runs on `macos-26`, pins Xcode `26.4.1` (iOS 26.4 SDK) via [`maxim-lobanov/setup-xcode@v1`](https://github.com/maxim-lobanov/setup-xcode), imports the Apple Distribution `.p12` and App Store provisioning profile into an ephemeral keychain, archives with manual signing, and uploads with `xcodebuild -exportArchive`. Triggered manually from the Actions tab (`workflow_dispatch`) or by pushing a `release/v*` tag.

**Why this way (the four non-obvious choices):**

1. **Manual `.p12` + profile import instead of cloud-managed signing.** Xcode's cloud-managed Distribution signing requires an App Store Connect API key with the **Admin** role. Our CI key is **App Manager**, which can do TestFlight uploads but cannot create or manage Apple Distribution certificates via cloud signing — `xcodebuild -exportArchive` returns `Cloud signing permission error / No profiles for 'com.brianwang.Super' were found`. Manually importing the cert and profile bypasses cloud signing entirely. ([Apple Developer Forums — known limitation since 2022](https://developer.apple.com/forums/thread/698117).)

2. **Release signing settings live in `project.yml` on the `Super` target, not on the xcodebuild CLI.** Build settings passed on the `xcodebuild` command line (e.g. `PROVISIONING_PROFILE_SPECIFIER=...`) propagate to **every** target in the build, including Swift Package Manager (SPM) resource-bundle targets like `GRDB_GRDB`. Those targets reject provisioning profiles and the archive fails with *"GRDB_GRDB does not support provisioning profiles..."*. Setting the signing settings on the `Super` target's Release config in `project.yml` scopes them correctly — xcodegen bakes them into only that target.

3. **Xcode must be pinned literally on the runner.** The `macos-26` image ships several Xcode versions side-by-side (currently 26.0.1 / 26.1.1 / 26.2 / 26.3 / 26.4.1 / 26.5) with 26.4.1 as the default. App Store Connect rejects uploads built with anything older than the iOS 26 SDK. We pin `xcode-version: "26.4.1"` literally (not `latest-stable`) so a runner image refresh can't surprise us with a beta toolchain — repinning to 26.5 only after Apple ships it stable.

4. **Cert + key partition list must be set, not just imported.** Without `security set-key-partition-list -S apple-tool:,apple:`, `codesign` hangs on an interactive macOS UI prompt asking permission to use the private key — fatal in CI.

**Auth split.** Two distinct credentials are at play:
- **Apple Distribution cert + App Store profile** — proves *who* can sign Super for App Store distribution. Imported into the runner's ephemeral keychain at build time.
- **App Store Connect API key (`.p8`)** — proves *who* can upload on behalf of the team. Passed via `-authenticationKeyPath` to `xcodebuild -exportArchive` for the upload itself. App Manager role is sufficient for upload (only Distribution cert management requires Admin).

**Build numbering.** `CURRENT_PROJECT_VERSION` is set to `GITHUB_RUN_NUMBER` so every run yields a unique, monotonically increasing build number. Marketing version (`CFBundleShortVersionString`) is whatever's in `App-SuperOS/Info.plist` (or `App-SuperBible/Info.plist`) unless overridden via the `marketing_version` workflow input.

**Cert rotation runbook (annual).** Apple Distribution certs expire ~1 year after issue. When that happens:

1. In Keychain Access on a Mac that has the existing cert, generate a new Apple Distribution certificate (or revoke the expired one in [developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates) and create a new one).
2. Export the new cert + private key as a `.p12` (select **both** the cert and the key under it before exporting).
3. Re-issue the App Store provisioning profile in [Profiles](https://developer.apple.com/account/resources/profiles) so it points at the new cert. Download the new `.mobileprovision`. Keep the profile name `Super App Store Distribution` — `project.yml` references it by name in `PROVISIONING_PROFILE_SPECIFIER`.
4. Update three GitHub secrets (see §10.1):
   ```sh
   base64 -i AppleDist.p12 | gh secret set APPLE_DIST_CERT_P12_BASE64 --repo brianwang9100/Super
   gh secret set APPLE_DIST_CERT_P12_PASSWORD --repo brianwang9100/Super
   base64 -i Super_App_Store_Distribution.mobileprovision | gh secret set APPLE_PROVISIONING_PROFILE_BASE64 --repo brianwang9100/Super
   ```
5. Trigger the workflow to confirm. Delete the loose `.p12` / `.mobileprovision` files once verified.

### 9.3 Versioning Strategy

| Component | Version Format | Example |
|-----------|---------------|---------|
| Marketing version | `MAJOR.MINOR.PATCH` (semver) | `1.2.0` |
| Build number | GitHub Actions `run_number` (auto-incrementing) | `147` |
| Server Docker tag | Git SHA | `a1b2c3d` |

- Marketing version is bumped manually (or by a dedicated PR) when a release milestone is reached.
- Build number increments automatically on every merge to main.
- Server images are tagged with the git SHA for traceability.

---

## 10. Secrets Management

### 10.1 GitHub Actions Secrets

Wired today for the TestFlight workflow:

| Secret | Purpose |
|--------|---------|
| `APPLE_DIST_CERT_P12_BASE64` | Apple Distribution certificate + private key, exported from Keychain as `.p12`, base64-encoded. Imported into an ephemeral keychain on the runner. |
| `APPLE_DIST_CERT_P12_PASSWORD` | Password set when exporting the `.p12`. |
| `APPLE_PROVISIONING_PROFILE_BASE64` | App Store provisioning profile (`Super App Store Distribution`), base64-encoded. Installed at `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision` on the runner. |
| `APPLE_TEAM_ID` | Apple Developer team ID. Injected into `ExportOptions.plist`. |
| `APP_STORE_CONNECT_API_KEY` | Contents of the `.p8` App Store Connect API key. Staged at `~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8` for `xcodebuild` to discover. App Manager role is sufficient. |
| `APP_STORE_CONNECT_KEY_ID` | The 10-char key ID Apple assigns. |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect organization issuer UUID. |
| `KEYCHAIN_PASSWORD` | Password used to lock the ephemeral build keychain. Any random string; rotateable independently of Apple state. |

Future / planned:

| Secret | Purpose |
|--------|---------|
| `FLY_API_TOKEN` | Server deployment (or equivalent for chosen host) |
| `REGISTRY_URL` | Docker registry URL |
| `CODECOV_TOKEN` | Coverage reporting |

### 10.1.1 Retiring the former Claude review workflow

After native Codex automatic review is confirmed on a test pull request, perform this repository-admin checklist outside the codebase:

1. Remove the former AI-review status check from `main` branch protection, so a deleted workflow cannot block merges.
2. Delete the `CLAUDE_CODE_OAUTH_TOKEN` repository secret from GitHub.
3. Confirm no other branch-protection rule or reusable workflow still requires the removed review job.

### 10.2 Apple Code Signing in CI

Manual `.p12` + provisioning profile import (chosen approach — see §9.2 "Why this way" for the full reasoning).

**Why not cloud-managed signing.** Xcode's cloud-managed Distribution signing needs an App Store Connect API key with the **Admin** role. Our CI key is **App Manager** — it can upload to TestFlight but cannot create/manage Distribution certs. Manual import sidesteps the role requirement entirely.

**Why not fastlane match.** Match wraps the same manual-import pattern with a private-git-repo cert store. For a solo-dev project with one app, the extra dependency (Ruby + Fastlane on CI, plus a private repo to maintain) outweighs the renewal-automation benefit. Revisit if Super grows to multiple apps or developers.

**Annual rotation.** See §9.2's "Cert rotation runbook".

**Industry context.** Manual `.p12` import is the dominant pattern across GitHub Actions iOS pipelines (`apple-actions/import-codesign-certs`, GitHub's own docs, Bitrise, Codemagic). Cloud signing is most common inside Xcode Cloud, where the API key role limitation doesn't apply.

---

## 11. Notifications

### 11.1 Where CI Results Appear

| Event | Channel |
|-------|---------|
| CI pass/fail | GitHub Checks (inline on the PR) |
| AI reviewer comments | GitHub PR review comments |
| PR ready for human review | Slack/Discord webhook + GitHub notification |
| Deploy to staging complete | Slack/Discord webhook |
| TestFlight build available | App Store Connect email (automatic) |

### 11.2 "Ready for Review" Notification

When all status checks pass on a PR, a workflow posts a notification to the user:

```yaml
# .github/workflows/notify-ready.yml
name: Notify PR Ready

on:
  check_suite:
    types: [completed]

jobs:
  notify:
    if: github.event.check_suite.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - name: Find associated PRs
        id: prs
        run: |
          PRS=$(gh api repos/${{ github.repository }}/commits/${{ github.sha }}/pulls \
            --jq '.[].number')
          echo "numbers=$PRS" >> "$GITHUB_OUTPUT"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - name: Notify via webhook
        if: steps.prs.outputs.numbers != ''
        run: |
          curl -X POST "${{ secrets.NOTIFICATION_WEBHOOK_URL }}" \
            -H 'Content-Type: application/json' \
            -d "{
              \"text\": \"PR #${{ steps.prs.outputs.numbers }} has passed all checks and is ready for your review.\"
            }"
```

---

## 12. Cost Considerations

### 12.1 GitHub Actions Pricing (as of early 2026)

| Runner | Cost per minute | Notes |
|--------|----------------|-------|
| Linux (ubuntu-latest) | $0.008 | Cheap. Use for everything that doesn't need macOS. |
| macOS (macos-26) | $0.08 | **10x more expensive.** Minimize macOS runner time. |
| macOS (macos-26-xlarge) | $0.16 | Only if build times on standard runners are unacceptable. |

### 12.2 Cost Optimization Strategies

| Strategy | Impact |
|----------|--------|
| **Path filters** | Only run client CI when client code changes. Only run server CI when server code changes. Saves ~50% of runs. |
| **`concurrency` with `cancel-in-progress`** | When an agent pushes a fixup, cancel the previous run. Prevents wasted minutes on outdated commits. |
| **Changed-applet detection** | Only test applets that actually changed (see `detect-changes` job). |
| **SPM cache** | Cache resolved Swift packages. Saves 1-3 minutes per build. |
| **Docker layer caching** | Use GitHub Actions cache for Docker builds (`cache-from: type=gha`). Saves 2-5 minutes per server build. |
| **Run lint/typecheck on Linux** | SwiftLint is the exception (needs macOS), but ESLint and `tsc` run on cheap Linux runners. |
| **Self-hosted macOS runner** | If CI costs exceed ~$200/month, a Mac Mini ($599 one-time) pays for itself in 3 months. |

### 12.3 Estimated Monthly Cost

Assuming 100 PRs/month (aggressive agent activity), average 4 pushes per PR:

| Component | Runs | Minutes/run | Runner | Cost |
|-----------|------|-------------|--------|------|
| Client CI (build + test) | 200 | 15 | macOS | ~$240 |
| Server CI | 200 | 5 | Linux | ~$8 |
| Deploy (server) | 30 | 3 | Linux | ~$0.72 |
| Deploy (client) | 15 | 20 | macOS | ~$24 |
| **Total** | | | | **~$273/month** |

This can be cut significantly with a self-hosted macOS runner (reduces macOS costs to electricity).

---

## 13. Open Questions

| # | Question | Impact | Notes |
|---|----------|--------|-------|
| 1 | Self-hosted macOS runner from day one, or start with GitHub-hosted? | Cost vs. setup time | GitHub-hosted is zero-setup. Self-hosted saves money but requires maintenance. Recommend starting hosted, switch when costs justify. |
| 2 | Fastlane for the full deployment pipeline, or raw `xcodebuild`? | Complexity | Fastlane adds Ruby dependency but simplifies certificate management, versioning, and TestFlight upload into a single `Fastfile`. |
| 3 | How to handle database migrations in the deployment pipeline? | Server reliability | Need a strategy for running migrations before deploying the new server version. Separate migration job? Init container? |
| 4 | Integration test strategy for cross-applet event bus behavior? | Test coverage gap | Unit tests per applet cannot catch event bus integration issues. Need a dedicated integration test suite in the Shell target. |
| 5 | How to handle Xcode version updates across all agents? | Consistency | Pin Xcode version in a `.xcode-version` file at the repo root. Agents and CI both read from it. |
