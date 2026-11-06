# Red-flag audit

Reviewed the complete Swift app, build and packaging scripts, documentation, and Git history before the first downloadable release. Baseline: b589445. The subsequent untangle pass addresses the findings below. Optional comment and test cleanup was declined; existing tests remain the regression safety net.

## Security and secrets

- No credentials found in tracked files or Git history. The synthetic `SECRET_ENV` parser fixture is not a credential. Profile data, app copies, build output, and environment files are ignored.
- [High] `Platform.swift:26-89` and `App.swift:49-75`: separate manager/launcher processes can race profile-copy replacement and launch, while archiving checks runtime state outside that operation. Fix: one per-profile file lease covering open and archive lifecycle operations.

## Repo hygiene and onboarding

- [Medium] No CI workflow: future changes can bypass the local build and packaging checks. Fix: run the existing build, regression checks, and archive round-trip validation in a minimal macOS workflow.
- [Low] No formatter configuration. This small Swift-only repository has no installed formatting dependency. Keep compiler diagnostics and whitespace checks in the build workflow; introducing a new formatter is not a release blocker.
- Setup, storage, compatibility, and installation documentation exist. No `.env.example` is needed because the app requires no environment secrets or backend.

## Code structure and architecture

- [Medium] `App.swift`, `Platform.swift:140-146`, and `build.sh`: product name, executable, version, and bundle metadata must change together but are separately hardcoded. Fix: one checked-in app plist, runtime metadata access, and inherited metadata for generated launchers.
- [Medium] `Core.swift:25` and `Platform.swift:96-102`: supported colors and their native rendering are disconnected, with unknown values silently rendered blue. Fix: a Codable/CaseIterable enum and exhaustive native mapping while preserving stored raw strings.
- No 500-line functions, unused framework abstraction, database layer, or oversized view requiring a split was found.

## Error handling and observability

- [Medium] `Platform.swift:171-180`: subprocess failures discard context and incorrectly promise no existing app changed. Fix: report the failed tool and exit status without that blanket promise.
- [Medium] `Platform.swift:14-22`: status checks read unrelated Claude processes before matching the executable, so an unrelated unreadable process blocks every profile. Fix: filter the executable path before reading arguments.
- Staging cleanup and exited-process races deliberately suppress non-actionable errors. Retain these narrow cases. No production console logging or credential telemetry exists.

## Type safety and tests

- Swift types and behavior checks already cover registry integrity, migration, exact arguments, locks, corrupt files, and symlink rejection.
- Add targeted checks for the new lifecycle lease, inherited bundle metadata, and asynchronous subprocess success/failure. Preserve existing checks; no optional test cleanup is included.

## Native frontend

- [Medium] `Platform.swift:171-178`: synchronous subprocess waiting blocks the main actor during copying, signature verification, and launcher generation. Fix: await process termination and expose launcher-export progress.
- [Medium] `App.swift:141,229`: menu and window disagree on whether a failed status read disables opening. Fix: one model-owned availability predicate.
- React-specific checks do not apply. The process-lifetime singleton timer is not a current unmount leak; do not add an observer framework.

## Backend and API

Not applicable. The app has no server, database, custom network API, or request handlers.

## Live verification finding

- [Medium, fixed] The temporary-directory integration check exposed equivalent `/var` and `/private/var` executable paths. Raw string comparison rejected the intended process. The shared executable-ownership predicate now resolves filesystem aliases; data-directory arguments remain exact, and profile storage symlink rejection remains in place.

## Priority actions

1. Coordinate profile launch/copy/archive operations across processes.
2. Move subprocess waiting off the UI thread and report failures accurately.
3. Centralize product metadata, colors, and action availability.
4. Add regression and CI packaging checks, then publish the renamed preview with signing limitations stated clearly.

## Resolution

All high- and medium-severity findings above were addressed before the downloadable release. The existing tests pass alongside the new regression checks. Live launch/reuse/relaunch checks passed after resolving the path-alias finding, and an independent structural review found no remaining blocker. The low-severity formatter observation is intentionally deferred; compiler checks and whitespace validation run in CI without adding a dependency.
