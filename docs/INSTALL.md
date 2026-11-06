# Install the Mac preview

## Requirements

- An Apple Silicon Mac (M1 or later) running macOS 15 or later.
- Claude Desktop already installed at `/Applications/Claude.app`.
- A normal local APFS volume for the app's profile storage.

## Install

1. On the GitHub release page, open **Assets** and download the file ending in `macOS-arm64.zip`. The **Source code** downloads are for developers.
2. Double-click the ZIP in Finder to extract the app.
3. Drag the extracted app into your Applications folder and open it.
4. Personal / Main opens your normal Claude account. Open Work or add another profile, then sign in to that account.

No Xcode, Terminal build, API key, or separate server is required to run the downloaded app. Claude accounts, subscriptions, and feature availability are handled by Claude.

## First-launch warning

This preview is ad-hoc signed. It is not signed with an Apple Developer ID or notarized by Apple, so macOS may block the first launch. The package's signature checks detect changes to its contents; they do not establish a verified publisher or replace Apple's notarization checks.

If you trust the source and choose to proceed, Apple's documented process is to attempt opening the app, then visit **System Settings > Privacy & Security** and use **Open Anyway** for that specific app. Read the warning before confirming. Managed Macs may disallow this exception. See [Apple's guidance on safely opening Mac apps](https://support.apple.com/en-us/102445).

Do not disable Gatekeeper globally or run commands that remove quarantine attributes. If your policy requires notarized software, wait for a notarized release.

## Optional checksum verification

Each release includes a `.sha256` file beside the ZIP. Download both into the same folder, then run `shasum -a 256 -c` followed by the checksum filename from that folder. A matching checksum confirms the ZIP matches the published artifact; it is not an independent security review.

## Updating and removing

Quit the profile manager before replacing its app with a newer release. Existing profiles remain in `~/Library/Application Support/Claude Profiles/`. Your regular Claude account stays in Claude's original storage.

Removing the manager or a generated launcher does not erase account data. Archiving a profile also preserves its files.

## Preview limits

Intel Macs are not supported by this download. Browser and MCP integrations, real Claude updater restarts, and a clean second-Mac installation have not been validated. Separate accounts are not separate macOS security boundaries. Check the account shown inside Claude before granting access to work files.
