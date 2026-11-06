# Validation notes

Version: Loftlane 0.2.0 preview. Test date: November 6, 2026. Architecture: Apple Silicon. Claude Desktop: 4.23118.0.

## Verified

- Core tests pass for storage, registry migration, exact process arguments, locks, validation, and archive preservation.
- Additional accounts have distinct desktop data folders and exact app-copy launch paths.
- Repeated launch focuses/reuses the same process.
- Live integration tests quit and reopen their own unauthenticated profiles.
- Main reuses the existing original Claude process without profile arguments.
- Original Claude signatures remain valid. Loftlane and generated wrappers are ad-hoc signed.
- Two signed-in accounts displayed different identities and completed synthetic tasks in separate selected folders.

Each task read its own random marker and values, waited 45 seconds, and wrote a result file. Account A produced sum 41; account B produced sum 59. Both returned their own marker. The recorded UTC execution intervals overlapped by 16.894279 seconds.

The tasks were cloud-backed desktop workflows with access to selected Mac folders. Account B reported that its local Linux environment was still downloading, so it computed in the session workspace and copied the result back. No independent local VM isolation claim is made.

The additional signed-in account was then quit and reopened through its generated launcher. Its login and task history persisted. A continuation read the original result and wrote a matching `resumed.json` with `resumed: true` to the same folder. That continuation reported executing directly on the computer. Main was not restarted because it contained existing user work.

## Still unverified

- Real application updates and updater-triggered restart behavior.
- Browser and MCP integrations across accounts.
- Long-running workload behavior, all login methods, and Intel compatibility.

These observations cover one Claude version on one Mac. They are not a certification of account isolation or a guarantee for future versions.
