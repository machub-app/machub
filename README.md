<p align="center">
  <img src="docs/brand/icon.png" width="180" alt="MacHub icon">
</p>

<h1 align="center">MacHub</h1>

<p align="center">
  Play your Windows games on a Mac with Apple silicon: one library, one click to play, one click for mods.<br>
  Free and open source (GPLv3).
</p>

---

MacHub is a native macOS app (SwiftUI) that runs Windows games and programs with its own built-in compatibility engine. You don't need Whisky, CrossOver or anything else.

## Features

- **Built-in Windows engine:** MacHub's own build of Wine 11.0 (official WineHQ sources plus MacHub's patches), with DXMT (Direct3D 10/11 → Metal) and DXVK. Engine versions are installed side by side and checked by SHA-256.
- **Steam for Windows:** installed silently in its own Windows environment. You sign in in Steam's own window, and MacHub never sees your password. Downloads, updates and play all start from MacHub.
- **Per-game settings:** Direct3D layer (detected automatically from the game's imports), launch options, and a frame-rate summary after each session.
- **Game management:** update, verify files, open the game folder, Steam properties, stop, uninstall.
- **Mods:** a Nexus Mods catalog (BeamNG.drive, Cyberpunk 2077, Dead Island 2), Modrinth for Minecraft, and a safe .zip import for Assetto Corsa. Every mod can be turned off or removed, and anything it replaced is put back.
- **Controllers:** connect, test and check what Windows games receive.
- **Your Steam account:** sign-in with Steam OpenID, the Steam store and your library in a console-style interface.
- **Languages:** English and French (Japanese and Chinese in progress).

DirectX 12 needs Apple's D3DMetal, which MacHub never redistributes. MacHub guides you to download it from Apple.

## Requirements

- A Mac with Apple silicon, macOS 15 or later
- Rosetta 2 (MacHub shows the command to install it)

## Building

Open `MacHub.xcodeproj` in Xcode and run the `MacHub` scheme. To build the Windows engine yourself, see [docs/ENGINE.md](docs/ENGINE.md).

## Authors

Designed and developed by **Mathieu Bielle** ([@mbielle](https://github.com/mbielle)) and **Johan Bielle** ([@johan-bielle](https://github.com/johan-bielle)).

## License

MacHub is released under the [GNU GPL v3](LICENSE). Bundled components keep their own licenses: see [docs/LICENSES.md](docs/LICENSES.md).
