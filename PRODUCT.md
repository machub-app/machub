# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS 15+ native desktop app (SwiftUI, Apple Silicon only). Not iOS, not web.

## Stack

SwiftUI, Swift 6 language mode, Xcode project, no third-party dependencies in v1.
Compatibility layer: Whisky (frankea fork, `com.franke.Whisky`) driven only through its WhiskyCmd CLI
(subprocess; never linked, never bundled). Non-sandboxed, Developer ID + notarization (not Mac App Store).

## Users

Mac (Apple Silicon) players with Windows game libraries, Steam first; later, users of regular Windows software.
Audience is the general public (public release), not only the author.

## Product Purpose

One click to play, one click for mods. Success = launching Assetto Corsa (+ mods), a DX11/DX12 AAA,
and a plain Windows .exe from one library, with honest status at every step.

## Positioning

A cinematic, console-grade library on top of Whisky, for games AND Windows software, with
non-destructive mod management. Never reimplements Wine/DXMT/DXVK/GPTK.
References named by the user: Netflix Gaming, Steam Deck OLED, Apple TV+, GameHub (xiaoji).

## Capabilities and Constraints

- Steam accounts read locally (loginusers.vdf); passwords/tokens never handled. Optional user-supplied Web API key in Keychain.
- Installed vs owned titles always distinguished; a title is never shown as playable unless prerequisites are met.
- Demo content, while it exists, is always labelled as demo and never presented as a real integration.
- Must degrade gracefully offline / without artwork / without API key.
- Localization: English (base), French, Japanese, Simplified Chinese; language switchable in-app.
- Never modify or delete existing Whisky bottles without explicit user action.
- Open: final product name and icon; Apple Developer account availability.

## Evidence on Hand

None. No testimonials, benchmarks, compatibility scores or user counts may be invented.
Artwork comes from Steam's public CDN per App ID.

## Product Principles

1. Prove before promising: status shown = status verified.
2. Reuse Whisky, add the experience layer.
3. Non-destructive by default (bottles, mods, settings).
4. Keyboard- and controller-first navigation.

## Accessibility & Inclusion

Full keyboard navigation with visible focus; VoiceOver labels on artwork-only controls; respects Reduce Motion
and Increase Contrast; 4 languages including CJK typography.
