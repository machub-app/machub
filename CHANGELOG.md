# Changelog

All notable changes to MacHub. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- **Mac games through Steam for Mac**: games installed with Steam for Mac show as "Installed (Mac)" and Play starts them through Steam for Mac, without Wine. A game with a native Mac build that isn't installed offers "Install for Mac" (Steam for Mac downloads it and MacHub follows the progress) or its Steam page when the account doesn't own it; the Windows version stays in the … menu. Steam for Mac's library cache also fills the library when no Web API key is set.
- **Nintendo Switch games through Astris** (a Switch emulator installed separately): the games Astris knows and the game files in its folders appear in the Library with their artwork and details from nlib, and Play opens them in Astris. Settings › Emulators shows Astris and its game folders. MacHub never provides games, firmware or keys.
- Steam for Windows quits by itself once the game it was started for closes (cloud saves sync on the way out; never during a download). It can be kept open in Settings › Steam for Windows.
- **Game version and updates** on each installed Steam game's page: the installed build and when it was updated, the latest build on Steam (from api.steamcmd.net), the version named in the developer's latest announcement (e.g. v0.40), and "Update Now" when a newer build is out.
- Steam for Mac and Astris quit by themselves once the game MacHub opened them for is closed (unless they were already open; a setting in Settings › General keeps them open).
- **Game renderer** for games that choose it by launch option: BeamNG.drive can start with Vulkan through MoltenVK instead of DirectX 11 (not tested yet; Automatic switches back).
- Update checks at launch and then every hour while MacHub is open, so the sidebar card appears without going to Settings.
- **Assetto Corsa mods**: browse and install from Nexus Mods inside MacHub, like BeamNG.drive and Cyberpunk 2077. Cars and tracks go to `content/cars` and `content/tracks` (archives laid out like the game folder are merged as they are); every mod can be disabled, enabled again or removed, and a game file it replaced is put back.
- **Mods from other sites** (Overtake, AssettoCorsa.club, BeamNG's repository): MacHub opens the site, watches the Downloads folder for 15 minutes for the archive downloaded there and installs it in one click. Any archive or unpacked folder can also be added by hand.
- `.7z` and `.rar` mod archives, unpacked with macOS's own bsdtar.
- **Settings › Sound**: a volume and a mute button per app (a game, Discord, the browser playing YouTube…), with Core Audio process taps. macOS asks once for permission; volumes apply while MacHub is open, and a browser is one app (macOS doesn't separate tabs).
- Steam for Windows already installed in a Whisky bottle is used as it is: no download and no "Install Steam" step. Valve's installer already on the Mac is reused instead of downloaded again.

### Fixed
- "Wine didn't start" with an empty message at launch: the cleanup of programs left by an earlier session could also end the engine check MacHub had just started.
- Mods merged into a game folder (Cyberpunk 2077 layout) could be written under a wrong sub-folder: the temporary folder is reached through `/var` → `/private/var`, which shifted every relative path.
- Nexus mods could only be installed for games in a MacHub environment; games in a Whisky bottle work too.
- MacHub didn't compile with Xcode 26.6 in Debug (RootView's body was too long for the type checker).
- When the Windows engine crashes at start on macOS 26 (engine 1.0.5 was built with the macOS 27 SDK and calls `pipe2`), the error now says so. `scripts/build-wine.sh` sets `ac_cv_func_pipe2=no`: the next engine build runs on macOS 26 and earlier.

## [0.4.1] - 2026-10-20

### Fixed
- Wine programs could outlive MacHub and freeze in a black window that wouldn't close (Steam's window, left without its wineserver). Quitting MacHub now asks whether to quit Windows programs too (Steam is closed properly first, so cloud saves sync), with a setting in Settings › General. At launch, MacHub ends programs an earlier session left without their wineserver.

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
