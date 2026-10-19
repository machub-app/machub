# Contributing to MacHub

Thanks for helping! MacHub is free and open source (GPLv3).

## Report a game result or a bug

Open an issue with the matching template: **Game report** for how a game runs, **Bug report** for something broken in MacHub. Please include your Mac model, macOS version and MacHub engine version (Settings › Windows Engine). The **Copy Report** button in Settings gives a summary you can paste (it contains no account data).

## Code

1. Fork the repository and create a branch from `main`.
2. Open `MacHub.xcodeproj` in Xcode 26 or later.
3. Run the unit tests: `xcodebuild test -project MacHub.xcodeproj -scheme MacHub -skip-testing:MacHubTests/RealSteamTests -skip-testing:MacHubTests/RealWhiskyTests -skip-testing:MacHubTests/RealEngineTests -skip-testing:MacHubTests/RealSteamEngineTests`
4. Open a pull request that explains what changed and how you checked it.

Rules we follow:
- Swift 6, SwiftUI, no third-party dependencies in the app.
- Never handle a user's password. Keys go to the Keychain.
- Never overwrite a user's or a game's files without a backup.
- Don't claim a game works until it has been tested.

## The Windows engine

The engine (Wine, DXMT, DXVK) is built by `scripts/build-wine.sh` and `scripts/build-runtime.sh`. See [docs/ENGINE.md](docs/ENGINE.md). Wine patches live in `tools/wine-patches/`.
