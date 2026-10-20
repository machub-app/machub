# Changelog

All notable changes to MacHub. Versions follow [Semantic Versioning](https://semver.org).

## [0.4.0] - 2026-10-20

### Added
- **Compatibility from highball-db**, the open database of the Highball project: verified and player-reported verdicts, the renderer and launch options players used (applied automatically, can be turned off per game), known issues with their fixes, and predictions for 12,000 more games. Shown with its source and licence.
- **One-click fixes**: a game's recipe from highball-db (Visual C++, registry keys, variables, notes…) applied in its Windows environment, every download checked by SHA-256. **Windows components** (Visual C++, fonts, XACT) per environment.
- **Report how a game ran**: after a session, a short form pre-fills a report (Mac, macOS, engine, renderer, session length, frame rate) to share with highball-db or MacHub on GitHub.
- **Advanced settings per game**: synchronization, AVX, 4 GB memory, Metal overlay, a fixed resolution (Wine virtual desktop), DLL overrides and environment variables.
- **Mac shortcut per game**: an app in Applications › MacHub Games that launches the game directly (`machub://play/<id>`).
- **Settings › Storage**: disk use per game, environment and engine; a games folder on an external drive for Steam; uninstall all of MacHub's data to the Trash.
- **Epic Games library** through Legendary: sign in with Epic's one-time code, see your games, install and play them with MacHub's engine.
- **Discord status** (“Playing … via MacHub”), ready but off until MacHub's Discord application is registered.

## [0.3.2] - 2026-10-20

### Fixed
- Opening a trailer quit MacHub. The release build linked SwiftUI's video player without AVKit, the framework it is built on, so it aborted the moment it appeared; trailers now use AVKit's own player view.

## [0.3.1] - 2026-10-20

### Added
- **Trailers** on game pages, played in MacHub (streamed from Steam only when you open one).

### Fixed
- The Library explained Steam Families games with outdated text. It now says what to do when shared games are missing (start Steam for Windows once so it syncs the family library) and has a button for it.

## [0.3.0] - 2026-10-19

### Added
- **Mac compatibility estimate** on every game card and page: tested by MacHub, native Mac version, blocked by anti-cheat (AreWeAntiCheatYet), needs DirectX 12, or likely / issues / unlikely from Wine reports (ProtonDB). The game page shows each signal and its source.
- **Your Steam library without a Web API key**: once Steam for Windows is signed in, MacHub reads the library from it, games shared through Steam Families included (tools, DLC and demos are left out).
- The Steam account and Settings share one bar at the foot of the sidebar; a dot shows whether Steam is connected.
- Automatic updates: MacHub checks its GitHub releases at most once a day and offers a new version in the sidebar. **Install and Relaunch** downloads it, checks its published SHA-256, replaces MacHub and relaunches it. Settings › General › Updates shows the version, a manual check and the automatic-check switch.

## [0.2.0] - 2026-10-19

### Added
- First-run setup in the sidebar: install the Windows engine, then Steam for Windows, each with one button and its progress. The card disappears once everything is ready.
- The controller card shows only while a controller is connected, with its Xbox or PlayStation logo, and opens Settings › Controllers.
- The Library explains how games shared through Steam Families appear (once installed with Steam for Windows).

### Fixed
- Setting up a Windows environment failed with an empty message on some Macs. MacHub now retries once, keeps a log of the setup (Settings › Steam for Windows › Show Wine Logs) and shows Wine's exit code and last lines.
- Nexus Mods pictures could overflow onto the next card.
- Library and Discover captions no longer mention Whisky.

## [0.1.0] - 2026-10-19

First public preview.

### Added
- Built-in Windows engine 1.0.5: Wine 11.0 built by MacHub from WineHQ sources, DXMT 0.80, DXVK 1.10.3. Engine versions install side by side and are checked by SHA-256.
- Steam for Windows set up in its own Windows environment, with sign-in in Steam's own window.
- Steam account sign-in (OpenID), Steam store and library in a console-style interface.
- Direct3D layer picked per game from its imports, launch options, performance summary after each session.
- Game menu: Update, Verify Game Files, Show Game Folder, Steam Properties, Stop, Uninstall. Force Quit All Windows Programs.
- Mods: Nexus Mods catalog (BeamNG.drive, Cyberpunk 2077, Dead Island 2), Modrinth for Minecraft, safe import for Assetto Corsa.
- Controllers page: detection, button and vibration test.
- English and French interface.
