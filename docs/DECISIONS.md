# Untangle decision log

Scope: complete structural pass over this small native Mac launcher before the POLR Switch downloadable release. Existing comments and tests are preserved except for necessary caller/type updates. New regression checks cover changed behavior.

## Fixes and the problems they solve

- Own profile lifecycle coordination at the launcher service boundary, using a per-profile file lease held through async launch readiness and archive checks.
  - Hidden link: the UI's in-memory opening set does not coordinate independent launcher processes.
  - Hidden link: a running-state check, app-copy replacement, and native launch must be one operation.
  - Hidden link: archive must participate in the same operation ordering.
  - Keep the short registry lock independent from the longer lifecycle lease so unrelated profiles remain usable.
- Make tool completion asynchronous and propagate failure context.
  - Needless link: file-copy and signing duration currently blocks rendering and input on the main actor.
  - Hidden link: export must expose progress while awaiting icon generation and signing.
  - Special case removed: blanket error text saying no existing app changed after any subprocess failure.
- Make Info.plist the product metadata authority and inherit it when exporting a named launcher.
  - Hidden links: name, executable, version, minimum OS, and bundle ID are hardcoded independently in the app, wrapper generation, and build script.
  - Keep the compatibility bundle ID and data directory unchanged. Rename the product without moving account storage.
  - Use brand-neutral storage errors so the registry does not depend on presentation metadata.
- Represent profile colors as a typed set with exhaustive rendering.
  - Hidden link: allowed color names and their native appearance live in separate string lists.
  - Special case removed: silently substituting blue for an unknown stored color.
- Keep action availability in the model and filter process candidates by executable before inspection.
  - Hidden link: menu and window currently enforce different open preconditions.
  - Needless link: an unreadable unrelated Claude process can disable a different profile.
- Match executable identity through resolved filesystem paths while keeping profile arguments exact.
  - Hidden link: macOS can report the same executable through `/var` and `/private/var`; raw path strings failed the live temporary-directory check.
  - Use the same ownership predicate for status, launch guards, and readiness. Storage symlink rejection is unchanged.
- Keep the existing small Core/Platform/App layout.
  - No worthwhile dead code, pass-through service framework, speculative extension point, or large view was found. Extra feature folders would add navigation without improving change locality.
- Run the existing build and release validation in CI.
  - Hidden convention: contributors currently have to remember the local verification commands.

## Necessary special cases retained

- Main opens the original app without a profile argument, as requested.
- Original storage location, bundle identity, and version-1 registry migration preserve existing accounts and launchers.
- Legacy profile-process detection prevents two launch methods from sharing the same data directory.
- Bounded readiness retries accommodate native process startup. Exited-process read failures are ignored only when the process is already gone.
- Best-effort cleanup of unique staging paths must not mask the original operation error.
- The macOS 26.5 SDK fallback works around the inspected 27.0 command-line SDK's missing SwiftUI plugin.
- Archive retains files. Main cannot be archived. Unknown or corrupt registry data is refused, not replaced.

## Verification

Implemented all listed structural fixes. Original regression tests remain, with necessary typed-color caller updates and new checks for cross-process lock exclusion, archive/open coordination, metadata inheritance, subprocess errors, and filesystem aliases. The live integration check passed for two independent profiles, repeated-launch reuse, and quit/relaunch. An independent subagent review found no further worthwhile structural change. The final running indicator was visually verified green, with gray status text.

The first live check exposed a filesystem-alias mismatch, which was fixed before release. CI and downloadable-asset verification are the final publication checks. Notarization, a clean second Mac, browser/MCP integrations, and real Claude updates remain outside this verified scope.
