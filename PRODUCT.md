# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS 15+ native desktop app (SwiftUI, Apple Silicon only). Not iOS, not web.

## Stack

SwiftUI, Swift 6 language mode, Xcode project, no third-party Swift dependencies.
Compatibility layer: MacHub's own Windows engine (Wine 11.0 compiled from WineHQ sources with MacHub's patches,
DXMT, DXVK), downloaded by the app from GitHub Releases into Application Support and run as separate processes
(see docs/ENGINE.md). Whisky stays as a read-only fallback for existing bottles. Non-sandboxed, ad-hoc signed and
distributed as a `.dmg` on GitHub Releases (not notarized yet; never signed with another project's Developer ID).
GPLv3, free and open source (github.com/machub-app/machub), by Mathieu and Johan Bielle.

## Users

Mac (Apple Silicon) players with Windows game libraries, Steam first; later, users of regular Windows software.
Audience is the general public (public release), not only the author.

## Product Purpose

One click to play, one click for mods. Success = installing and playing Steam's Windows games (BeamNG.drive
plays through DXMT), modding them safely, and running a plain Windows .exe, from one library, with honest status
at every step. Next big step: DirectX 12 through Apple's D3DMetal.

## Positioning

A cinematic, console-grade library with its own Windows engine, for games AND Windows software, with
non-destructive mod management. Builds on Wine, DXMT and DXVK (patched and packaged, not rewritten); never
redistributes Apple's D3DMetal (guided import from Apple instead).
References named by the user: Netflix Gaming, Steam Deck OLED, Apple TV+, GameHub (xiaoji).

## Capabilities and Constraints

- Steam sign-in through Steam OpenID; passwords/tokens never handled. Library from the signed-in Steam for Windows'
  cache, or from the Web API with an optional user-supplied key (Keychain). Nexus Mods API key in Keychain.
- Installed vs owned titles always distinguished; a title is never shown as playable unless prerequisites are met.
- Demo content, while it exists, is always labelled as demo and never presented as a real integration.
- Must degrade gracefully offline / without artwork / without API key.
- Localization: English (base) and French complete; Japanese and Simplified Chinese behind on newer screens.
- Never modify or delete existing Whisky bottles without explicit user action.
- Compatibility is shown as an estimate from public signals (MacHub tests, native Mac version, AreWeAntiCheatYet,
  DirectX version, ProtonDB), always labelled as such.

## Evidence on Hand

BeamNG.drive played via DXMT (2026-10-18). No testimonials, benchmarks or user counts may be invented.
Artwork comes from Steam's public CDN per App ID.

## Product Principles

1. Prove before promising: status shown = status verified.
2. Own the engine, keep it replaceable (versioned runtimes, checksums, sources published).
3. Non-destructive by default (bottles, mods, settings).
4. Keyboard- and controller-first navigation.

## Accessibility & Inclusion

Full keyboard navigation with visible focus; VoiceOver labels on artwork-only controls; respects Reduce Motion
and Increase Contrast; 4 languages including CJK typography.
