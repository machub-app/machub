# MacHub: guide for coding agents

MacHub is a native macOS app (SwiftUI, Swift 6, Apple silicon, macOS 15+) that plays Windows games with its own
Windows engine (Wine 11.0 compiled by MacHub + DXMT + DXVK), Steam for Windows in its own Wine prefix, and safe mods.
Free and open source (GPLv3), github.com/machub-app/machub, by Mathieu (`mbielle`) and Johan (`johan-bielle`) Bielle.
The owners speak French: talk to them in French, plainly; code, comments and commits are in English.

Read first: `README.md` (what users get), `docs/ENGINE.md` (engine architecture, build, verified state, limits),
`CHANGELOG.md` (what each version shipped), `PRODUCT.md` and `DESIGN.md` (product and visual rules).
`docs/dev/` holds old French working notes (history only, partly outdated).

## Layout

| Folder | What lives there |
|---|---|
| `MacHub/App` | Entry point, language, `AppUpdater` (self-update from GitHub Releases) |
| `MacHub/Engine` | Wine runtime install/check (`WineRuntime`), prefixes (`WinePrefix`), settings, graphics layers (DXMT/DXVK/wined3d/D3DMetal), Steam for Windows setup, performance log, `runtime-manifest.json` (the engine version the app downloads) |
| `MacHub/Steam` | OpenID sign-in, store and Web API (`SteamStore`), cached HTTP with pacing (`SteamHTTP`), Steam for Windows files (`SteamLibrary`: ACF manifests, library cache) |
| `MacHub/Library` | `LibraryStore` (the app's main observable state and actions), `Title`, launches (`LaunchRunner`), compatibility estimate, Discover model |
| `MacHub/Mods` | Nexus Mods (+ installer per game), Modrinth/Minecraft, Assetto Corsa archive import |
| `MacHub/Input`, `MacHub/Install` | Controllers; importing a Windows installer into a prefix |
| `MacHub/Whisky` | Legacy Whisky fallback, plus `ProcessRunner` / `ProcessWatch` used everywhere |
| `MacHub/UI` | SwiftUI views (`RootView` = window, sidebar and its cards) |
| `MacHub/Resources/Localizable.xcstrings` | All UI strings; English source, French must stay complete |
| `MacHubTests` | Swift Testing suites; `Real*`/`FreshInstall*` are opt-in integration tests |
| `scripts/` | `build-wine.sh` (compile Wine), `build-runtime.sh` (pack the engine), `make-dmg.sh` (app disk image) |
| `tools/` | Wine patches, Steam CEF shim (`winmm.dll` proxy), DMG background and share-image generators |

## Build and test

```bash
xcodebuild build -project MacHub.xcodeproj -scheme MacHub
xcodebuild test -project MacHub.xcodeproj -scheme MacHub \
  -skip-testing:MacHubTests/RealSteamTests -skip-testing:MacHubTests/RealWhiskyTests \
  -skip-testing:MacHubTests/RealEngineTests -skip-testing:MacHubTests/RealSteamEngineTests \
  -skip-testing:MacHubTests/FreshInstallTests -skip-testing:MacHubTests/RealUpdateTests
```

Opt-in integration tests use `TEST_RUNNER_MACHUB_*` variables (listed in `docs/ENGINE.md` › Tests). Useful launch
arguments for screenshots and checks: `-startPage home|discover|library|software|settings`,
`-settings.category engine|graphics|…`, `--open title:<steam app id>` (a game's page, e.g. `title:284160`),
`-AppleLanguages "(fr)"`, `-installUpdateNow YES` (test the updater).
`xcodebuild … -quiet` sometimes prints "failed with exit code 0" while succeeding: check `** BUILD SUCCEEDED **`.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `MacHub.xcodeproj/project.pbxproj`, add a
   `CHANGELOG.md` section, translate new strings to French.
2. PR into `main` (branch protection: one approval, owners may bypass when asked to).
3. `scripts/make-dmg.sh` → `build/release/MacHub-X.Y.Z.dmg` + `.sha256`. It signs **ad-hoc only** on purpose:
   never sign MacHub with a Developer ID found in the keychain (it belongs to another project); `SIGN_IDENTITY` and
   `NOTARY_PROFILE` exist for a future MacHub-owned account.
4. `gh release create vX.Y.Z` with `MacHub.dmg` (stable name for the README link), `MacHub-X.Y.Z.dmg` and its
   `.sha256`. The in-app updater picks the newest `vX.Y.Z` release and requires that `.sha256` asset.
5. Engine releases are separate (`runtime-X.Y.Z`, never "latest"): archive, manifest, exact Wine sources and
   patches (LGPL). Then update `MacHub/Engine/runtime-manifest.json`.

Commit as the person you work for (`mbielle`: `217834167+mbielle@users.noreply.github.com`; Johan commits as
`johan.bielle1@icloud.com`). Ask before pushing, merging or publishing.

## Rules of the house

- **Honesty over optimism**: nothing is shown as working or compatible until it has been checked; estimates are
  labelled as estimates; docs separate "verified" from "not verified".
- **Never touch credentials**: no Steam password ever (OpenID / Steam's own window); API keys only in the Keychain.
- **Non-destructive**: back up any file a mod replaces; move things to the Trash rather than deleting; never
  overwrite DLLs a game ships itself (`machub-graphics.json` ledger).
- **No third-party Swift dependencies**; no redistribution of Apple's D3DMetal (guided import only).
- Match the surrounding code style; keep French translations complete.

## Where things live on a Mac

`~/Library/Application Support/app.machub.MacHub/`: `Runtimes/<version>/` (engines), `Prefixes/<uuid>/`
(Wine prefixes; the Steam one holds the games), `GPTK/`, settings JSON files, `steam-app-kinds-v2.json`.
Logs: `~/Library/Logs/app.machub.MacHub/Wine/` (per launch, and `wineboot-*.log` for environment setup).

## Gotchas learned the hard way

- Steam's CEF window is black under Wine unless `steamwebhelper.exe` gets `--disable-gpu --single-process`
  (the winmm shim does it). Steam needs the env set in `SteamSetup.environment`; `ROSETTA_ADVERTISE_AVX` and
  `WINE_LARGE_ADDRESS_AWARE` made Steam hang, so they default to off.
- CrossOver/WineCX builds never connected Steam: the engine is upstream WineHQ 11 + `tools/wine-patches/`.
- DXMT needs patch 0002 (exported `macdrv_functions`, client view for D3D windows).
- Games inherit Steam's environment: settings changes need a Steam restart (handled in `LibraryStore`).
- Without a Web API key, the library comes from Steam for Windows' `appcache/librarycache`, which only fills while
  Steam runs; Steam Family games appear there too.
- `ProcessRunner` writes output to temp files (no pipe deadlocks). In zsh, `log` is a builtin: use `/usr/bin/log`.

## Open work

- **DirectX 12 via D3DMetal**: import exists, routing disabled (`GPTKStore.canRunDirectX12 = false`); first check
  D3DMetal loads with upstream Wine 11, then route DX12 games and test one for real.
- Not yet tried on a real game: installing a Nexus mod, uninstall/verify from the game menu.
- Johan's "Wine couldn't set up the Windows environment" (empty message) wasn't reproduced; 0.2.0+ logs it.
- CI workflows (`runtime.yml`, `release.yml`) were never run. Japanese and Chinese translations are behind.
