---
name: MacHub
description: A screening room for your Windows game library on the Mac. The artwork is the interface; the chrome recedes into a dark theatre.
colors:
  theatre-ground: "#0B0B0D"
  house-surface: "rgba(255, 255, 255, 0.06)"
  house-surface-raised: "rgba(255, 255, 255, 0.10)"
  house-stroke: "rgba(255, 255, 255, 0.10)"
  screen-white: "#F5F5F5"
  aisle-grey: "#A8A8A8"
  projector-red: "#E50914"
  graphite: "#6B6866"
  compat-great: "#30D159"
  compat-playable: "#FFD60A"
  compat-issues: "#FF9E0A"
  compat-unsupported: "#FF453B"
  compat-unknown: "#A8A8A8"
  logo-plate: "rgba(237, 237, 237, 0.90)"
typography:
  display:
    fontFamily: "SF Pro Expanded"
    fontSize: "52pt"
    fontWeight: 800
  headline:
    fontFamily: "SF Pro Expanded"
    fontSize: "34pt"
    fontWeight: 800
  title:
    fontFamily: "SF Pro"
    fontSize: "17pt"
    fontWeight: 700
  summary:
    fontFamily: "SF Pro"
    fontSize: "15pt"
    fontWeight: 400
  action:
    fontFamily: "SF Pro"
    fontSize: "15pt"
    fontWeight: 600
  card-name:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 400
  meta:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro"
    fontSize: "10pt"
    fontWeight: 600
rounded:
  chip: "6pt"
  thumb: "7pt"
  card: "10pt"
  panel-sm: "12pt"
  panel: "14pt"
  capsule: "999pt"
spacing:
  gutter: "44pt"
  section: "40pt"
  hero-stack: "18pt"
  card-gap: "18pt"
  grid-column: "22pt"
  grid-row: "30pt"
  action-gap: "12pt"
  meta-gap: "10pt"
components:
  button-play:
    backgroundColor: "{colors.projector-red}"
    textColor: "#FFFFFF"
    typography: "{typography.action}"
    rounded: "{rounded.capsule}"
    padding: "0 22pt"
    height: "44pt"
  button-secondary:
    backgroundColor: "{colors.house-surface-raised}"
    textColor: "{colors.screen-white}"
    typography: "{typography.action}"
    rounded: "{rounded.capsule}"
    padding: "0 22pt"
    height: "44pt"
  badge-compat-verified:
    backgroundColor: "rgba(48, 209, 89, 0.14)"
    textColor: "{colors.compat-great}"
    rounded: "{rounded.capsule}"
    padding: "5pt 10pt"
  badge-compat-demo:
    backgroundColor: "transparent"
    textColor: "{colors.compat-great}"
    rounded: "{rounded.capsule}"
    padding: "5pt 10pt"
  badge-compat-compact:
    textColor: "{colors.compat-great}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    padding: "3pt 7pt"
  tag-demo:
    backgroundColor: "transparent"
    textColor: "{colors.aisle-grey}"
    typography: "{typography.label}"
    rounded: "{rounded.capsule}"
    padding: "3pt 8pt"
  card-landscape:
    rounded: "{rounded.card}"
    width: "296pt"
    height: "138pt"
  card-portrait:
    rounded: "{rounded.card}"
    width: "176pt"
    height: "264pt"
  panel:
    backgroundColor: "{colors.house-surface}"
    rounded: "{rounded.panel}"
    padding: "20pt"
  row-pager:
    backgroundColor: "{colors.house-surface-raised}"
    textColor: "{colors.screen-white}"
    rounded: "{rounded.capsule}"
    size: "32pt"
---

# Design System: MacHub

## Overview

**Creative North Star: "The Screening Room"**

MacHub is a dark theatre for a game library. The house lights are down: a warm near-black ground, surfaces that are nothing more than white breathed onto it at 6 to 10 percent, and native macOS chrome that stays out of the way. The colour in the room comes from the screen, which is each title's own Steam artwork: full-bleed in the hero, cropped into cards in the rows, and blurred into the whole window ground behind everything. The interface supplies only one colour of its own, the projector red of Play, and a set of honest compatibility signals.

The system is native first. It is a SwiftUI `NavigationSplitView` with the system floating sidebar, system pickers, a grouped `Form` for Settings, SF Symbols for every icon, and the graphite accent for every system control. The custom layer is narrow and deliberate: the hero, the cards, the compatibility badge, the demo treatment, and the ambient backdrop. The app forces dark appearance (`.preferredColorScheme(.dark)`), because light would wash the artwork out.

Honesty is visual. Demo content is always outlined and marked with a flask; it is never filled the way a verified state is filled. Play is only red when it can really launch something; otherwise it dims and a plain sentence beneath it says why.

**Key Characteristics:**
- Near-black warm ground; white-alpha surfaces; no tinted greys.
- The artwork carries the colour. Each title's Steam logo art is the display voice.
- One interface colour, projector red, reserved for Play.
- Five compatibility states, each a colour plus an SF Symbol plus a word.
- Demo data is outlined, flasked and tagged, never filled.
- Liquid Glass only on controls floating over artwork.
- The ambient backdrop: the focused title's art bleeds, blurred, into the whole window.

## Colors

A theatre palette: one dark ground, white at low alpha for every surface and line, one red for the action, and a semantic set reserved for compatibility. Everything else is borrowed from the artwork. Tokens live in `MacHub/UI/Theme.swift`; the accent lives in `Assets.xcassets/AccentColor`.

### Primary
- **Projector Red** (`Color(red: 0.898, green: 0.035, blue: 0.078)`, #E50914): the fill of the Play button and nothing else. White label, capsule shape. When Play cannot launch (demo title, no Whisky, software not yet supported) the fill drops to 35% and the whole control to 55% opacity, so it reads as a dim maroon rather than a live action.

### Secondary
- **Graphite** (`AccentColor` asset, sRGB 0.420 / 0.408 / 0.400, #6B6866): the app accent colour, so it is what native controls pick up: sidebar selection, segmented picker selection, toggles, focus in system controls. It is deliberately colourless so system chrome never competes with Projector Red or the artwork.

### Tertiary: compatibility states
Each state is defined in `Compatibility` (Theme.swift) as a tint, an SF Symbol and a localised label. The three always travel together; colour is never the only signal.
- **Runs great** (`Color(red: 0.19, green: 0.82, blue: 0.35)`, #30D159), symbol `checkmark.seal.fill`.
- **Playable** (`Color(red: 1.0, green: 0.84, blue: 0.04)`, #FFD60A), symbol `checkmark.circle.fill`.
- **Known issues** (`Color(red: 1.0, green: 0.62, blue: 0.04)`, #FF9E0A), symbol `exclamationmark.triangle.fill`. Also the colour of launch-failure captions and load errors.
- **Won't run** (`Color(red: 1.0, green: 0.27, blue: 0.23)`, #FF453B), symbol `xmark.octagon.fill`.
- **Untested** (Aisle Grey, #A8A8A8), symbol `questionmark.circle`.

The Whisky status dot at the foot of the sidebar reuses these tints: great for ready with bottles, issues for ready without bottles, unsupported for missing or outdated Whisky, Aisle Grey while checking.

### Neutral
- **Theatre Ground** (`Color(red: 0.043, green: 0.043, blue: 0.051)`, #0B0B0D): the window ground under the ambient backdrop, and the colour the backdrop's top-to-bottom gradient fades back into.
- **House Surface** (`Color.white.opacity(0.06)`): panels on the ground: the installed-empty-state panel, the compatibility panel, the detail info panel, the sidebar Whisky status chip.
- **House Surface Raised** (`Color.white.opacity(0.10)`): the secondary button fill, the row pager discs, the search suggestion chips.
- **House Stroke** (`Color.white.opacity(0.10)`): the 1 pt dividers between info-panel rows and the outline of the Demo data tag.
- **Screen White** (`Color(white: 0.96)`, #F5F5F5): primary text: headings, card names, values. Hero summary runs it at 88% and the About text at 85%.
- **Aisle Grey** (`Color(white: 0.66)`, #A8A8A8): secondary text: counts, year and genres, labels in the info panel, captions, the Untested state. About 8:1 on the ground.
- **Logo Plate** (`Color(white: 0.93).opacity(0.9)`): the light neutral backing behind dark logo art (see Typography).

### Named Rules
**The One Red Rule.** Projector Red fills the Play button and nothing else. No red headings, red badges, red focus rings or red hover states. "Won't run" uses its own warmer red-orange (#FF453B), never #E50914.

**The House Lights Rule.** Surfaces are white at 6% or 10% over the ground, never an opaque grey and never tinted. Depth in the content area comes from alpha, the artwork and the scrims.

**The Three-Part Signal Rule.** A compatibility state is always tint plus SF Symbol plus label. If one of the three is missing, it is not a compatibility state.

## Typography

**Display Voice:** each title's own Steam logo art (`logo.png` from the Steam CDN), shown by `LogoArt`.
**Title Font:** SF Pro, Expanded width, Heavy (`Theme.titleFont(_:)` = `.system(size:, weight: .heavy).width(.expanded)`).
**Body Font:** SF Pro through the system text styles.
**Mono:** SF Mono (`.callout.monospaced()`, `.caption.monospaced()`) for install paths and bottle IDs only.

**Character:** the game supplies the headline in its own lettering; MacHub supplies a wide, heavy SF Pro for the few titles it owns and standard SF Pro text styles for everything else, so all four languages (including Japanese and Simplified Chinese) fall back cleanly through the system font.

### Hierarchy
- **Display** (logo art, max 460 × 140 pt in the hero, 120 pt tall on detail): the title's identity in the hero and on the detail page. When there is no App ID or the logo fails to load, the name is set in SF Pro Expanded Heavy at 52 pt, up to 2 lines, scaling down to 60%. Monogram plates use the same face at 64 pt for initials.
- **Headline** (SF Pro Expanded Heavy, 34 pt): page titles of the custom pages, Library and Search, followed by the count in `.title2` Aisle Grey.
- **Title** (`.title2.weight(.bold)`, 17 pt): row headings ("Installed in Whisky", "Sample games"), detail section headings (About, Compatibility), the empty-state panel heading. The row count follows in `.title3` Aisle Grey.
- **Summary** (`.title3`, 15 pt): the hero summary (up to 3 lines, max 520 pt wide) and the detail About text (line spacing +4 pt, max 640 pt column).
- **Action** (SF Pro 15 pt Semibold): every label inside the Play and secondary capsule buttons.
- **Card name** (`.headline`, 13 pt bold): one line under each card, truncated.
- **Meta** (`.callout`, 12 pt): the meta line (badge, year, genres, demo tag), Play status captions, info panel. The full compatibility badge is `.callout.weight(.semibold)`.
- **Label** (`.caption.weight(.semibold)`, 10 pt): compact badges on cards, the Demo data tag, the sidebar status headline. Bottle chips on cards use `.caption2.weight(.semibold)`.

### Named Rules
**The Borrowed Marquee Rule.** A title's name is shown in its own logo art wherever the hero or detail page names it. SF Pro Expanded is the fallback and the voice of MacHub's own page titles, never a replacement for available logo art.

**The Light Plate Rule.** Logo art whose visible pixels average below 0.35 luminance (alpha-weighted, sampled on a 24 × 24 grid) sits on the Logo Plate: 18 pt × 12 pt padding, 14 pt corners, soft shadow. Light logos sit directly on the art with a soft drop shadow. Dark two-tone wordmarks such as Assetto Corsa's must stay readable over any artwork.

## Layout

The window is a `NavigationSplitView`: the native floating sidebar (190 to 260 pt wide, 210 ideal) with Home, Library, Search, then Settings in its own section, and the Whisky status chip pinned to its foot with 12 pt padding. The window opens at 1440 × 900 and has a minimum of 1100 × 720. The toolbar title is removed and the toolbar background hidden on every custom page, so the artwork runs up under the traffic lights.

Every content edge aligns to a single **44 pt gutter** (`Theme.gutter`): hero text, row headings, the first card of each row, page headings, panels.

- **Home** is a vertical stack with 40 pt between sections. The hero takes 62% of the viewport height, clamped to 480 to 720 pt, edge to edge. The hero text column is at most 560 pt wide (18 pt between logo, meta, summary, actions, status) and sits bottom-left with 64 pt bottom padding. The featured thumbnail strip sits bottom-right. Rows follow: heading line, then a horizontal snap-scrolling row with 18 pt between cards and 14 pt vertical breathing room for the hover lift. The first row peeks below the hero.
- **Title detail** repeats the hero at 60% of the viewport (440 to 660 pt) with 36 pt bottom padding, then a two-column body: About and Compatibility at most 640 pt wide, 48 pt gap, a 330 pt info panel. "More like this" closes the page.
- **Library and Search** use a 28 pt top and bottom inset and an adaptive portrait grid: columns 168 to 210 pt wide, 22 pt between columns, 30 pt between rows.
- **Settings** is a native grouped `Form` with its scroll background hidden, so it sits directly on the ground.

**Responsive behaviour.** The featured strip uses `ViewThatFits`: 112 × 52 pt thumbnails, then 84 × 39 pt, then page dots at narrow widths. Row pagers jump 3 landscape cards or 5 portrait cards per click.

### Named Rules
**The One Gutter Rule.** Content aligns to the 44 pt gutter. A custom page with a second left edge is off-system.

## Elevation & Depth

Depth comes from light, not from cards stacked on cards. At rest the content is flat: panels are House Surface fills with no shadow and no border. Depth comes from three sources: the artwork with its legibility scrims, the ambient backdrop behind everything, and a shadow that appears only when a card is lifted.

**Hero scrims** are legibility devices, not decoration: a left-to-right black gradient (82% at the edge, 45% at 40%, clear by 72%) under the text column, a top-right radial shade (50% black, radius 760 pt) so bright skies do not read as a white field, and a bottom fade mask (opaque to 55%, clear at 100%) that melts the art into the backdrop. The detail hero uses a shorter scrim (80% to clear at 62%) and fades from 50%.

### Shadow Vocabulary
- **Card lift** (`.shadow(color: .black.opacity(0.55), radius: 18, y: 10)`): only while a card is hovered or keyboard-focused, and only when Reduce Motion is off.
- **Logo on art** (`.shadow(color: .black.opacity(0.5), radius: 12, y: 4)`): light logo art directly over artwork.
- **Logo plate** (`.shadow(color: .black.opacity(0.35), radius: 16, y: 6)`): under the Logo Plate.

### Material
**Liquid Glass** (`.glassEffect(.regular, in: .rect(cornerRadius:))` on macOS 26) with an `.ultraThinMaterial` fallback on macOS 15 to 25, via `floatingGlass(cornerRadius:)`. It is used only for controls that float over artwork: the featured thumbnail strip (14 pt corners), the page dots (12 pt), the flask disc on demo cards (24 pt circle), and the bottle chip on installed cards (6 pt).

### Named Rules
**The Glass Over Art Rule.** Glass is for controls sitting on artwork. Panels on the ground use House Surface; glass never fills a plain panel.

**The Lift Is a Response Rule.** Cards and panels cast no shadow at rest. The card shadow exists only while the card is lifted; the only resting shadows are the soft ones that separate logo art from the artwork behind it.

## Shapes

The vocabulary is soft rectangles and capsules.

- **Capsules** for anything you press or read as a token: Play and secondary buttons, compatibility badges, the Demo data tag, the thumbnail progress bar, page dots. Row pagers are 32 pt circles.
- **Card corners** are 10 pt (`Theme.cardRadius`) on all artwork. The keyboard focus ring follows at 13 pt, 5 pt outside the art.
- **Panels** use 12 pt corners (compatibility panel) or 14 pt (empty-state panel, info panel, Logo Plate, featured strip). The sidebar status chip uses 10 pt; featured thumbnails 7 pt; card glass chips 6 pt.
- **Artwork is always clipped** to its shape. Missing artwork never shows a broken image. It falls back to a **Monogram Plate**: a solid field whose hue is derived stably from the title's name (saturation 0.45, brightness 0.28), initials in SF Pro Expanded Heavy 64 pt at 90% white, and a `gamecontroller` or `macwindow` symbol bottom-left at 60% white.

## Components

### Buttons
A capsule with a confident fill: one red, one house grey.
- **Shape:** capsule, minimum height 44 pt, 22 pt horizontal padding, SF Pro 15 pt Semibold, SF Symbol leading (`play.fill`, `info.circle`, `arrow.up.right.square`, `folder`).
- **Play (primary):** Projector Red fill, white label. Labels change with launch state: "Play", then a white small spinner plus "Starting…", then "Sent to Steam" with a checkmark. Play is the default action (Return) on the detail page.
- **Secondary:** House Surface Raised fill, Screen White label (Details, Steam page, Show files).
- **Hover / Press / Focus:** fill to 88% on hover; scale to 0.97 while pressed (ease-out 0.15 s); keyboard focus draws a 2.5 pt white capsule ring 4 pt outside the button.
- **Disabled:** fill at 35%, whole control at 55%. **PlayStatus** always sits beneath the action row: one `.callout` line with `info.circle` in Aisle Grey (demo, software not supported yet, handed to Steam) or `exclamationmark.triangle.fill` in Known-issues orange for a failure, max 520 pt wide.

### Compatibility Badge
- **Verified (filled):** tint at 14% capsule fill, tint text, symbol and label, `.callout` semibold, 10 × 5 pt padding.
- **Demo (outlined):** no fill, a 1 pt capsule stroke in the tint at 45%, and a leading `flask` symbol in Aisle Grey. Tooltip: illustrative value, no compatibility data source yet.
- **Compact (on cards):** `.caption` semibold, 7 × 3 pt padding. On demo cards it is outlined without the flask, because the card's flask disc already says "demo".

### Demo Treatment
Three devices, always together while demo content exists:
- **Outlined badge** (above).
- **Flask disc:** a 24 pt Liquid Glass circle with `flask.fill` (11 pt semibold), top-right of every demo card, 8 pt inset, tooltip "Sample content. Not installed and not launchable."
- **"Demo data" tag:** `Label("Demo data", systemImage: "flask")` in `.caption` semibold Aisle Grey, 8 × 3 pt padding, 1 pt House Stroke capsule outline. It appears in the hero meta line, after the heading of every demo row, after the Library heading, and the detail info panel's Source row reads "Demo data".

### Cards
- **Landscape** (296 × 138 pt, Steam `header.jpg`) for Installed, themed rows and "More like this". **Portrait** (176 × 264 pt, Steam `library_600x900.jpg`) for Sample games and every grid; in grids the width flexes with the column and keeps the 176:264 ratio.
- **Corner style:** 10 pt; artwork clipped.
- **Below the art** (10 pt gap): card name (`.headline`, one line), then the compact badge (6 pt gap). No container behind the text.
- **Overlays:** flask disc top-right on demo cards; on installed cards, a Liquid Glass bottle chip top-left (`shippingbox.fill` plus bottle name, `.caption2` semibold).
- **States** (`CardButtonStyle`): hover or focus lifts the card to 1.035 scale, anchored at the bottom, with the card-lift shadow; keyboard focus adds a 3 pt white ring (TV-style); pressing dims to 80%. Hovering a card also spotlights it for the ambient backdrop.

### Hero Carousel
- Full-bleed `library_hero.jpg` with the scrims described in Elevation & Depth; logo art, meta line, 3-line summary, Play + Details, PlayStatus.
- **Featured strip:** Liquid Glass tray (8 pt padding, 10 pt between thumbnails); the current thumbnail is full opacity with a 2 pt white border, the others at 60%. The current thumbnail carries a progress bar: a 3 pt capsule, 25% white track, white fill scaled from the left over the dwell.
- **Behaviour:** 9 s dwell per slide, then auto-advance; hovering the hero pauses and rewinds the dwell; ← and → step; slides cross-fade (ease-in-out 0.6 s). Reduce Motion turns auto-advance off.

### Rows
Heading (`.title2` bold), count (`.title3` Aisle Grey), Demo data tag when relevant, and two 32 pt pager discs on the right (House Surface Raised, 13 pt bold chevrons). Cards snap to their leading edge; paging animates ease-in-out 0.45 s.

### Panels
House Surface fill, no stroke, no shadow: the installed-empty-state panel (20 pt padding, 14 pt corners, 26 pt `shippingbox` symbol, heading plus the real reason in Aisle Grey), the compatibility panel (16 pt padding, 12 pt corners, 26 pt state symbol), and the info panel (18 × 6 pt padding, 14 pt corners, rows of 12 pt vertical padding divided by 1 pt House Stroke lines, labels Aisle Grey, values Screen White and selectable).

### Navigation
The native macOS sidebar, untouched: SF Symbol labels (`house`, `square.grid.2x2`, `magnifyingglass`, `gearshape`), graphite selection, Settings separated into its own section. At its foot, the **Whisky status chip**: 8 pt state dot, `.caption` semibold headline and `.caption2` Aisle Grey detail, House Surface, 10 pt padding and corners; clicking it opens Settings. ⌘1 to ⌘3, ⌘F and ⌘, drive the selection. Search uses the native toolbar search field; suggestion chips are House Surface Raised capsules (14 × 8 pt padding).

### Ambient Backdrop (signature)
The spotlighted title's hero art fills the whole detail column behind the content: blurred at radius 80 (opaque), saturation 1.25, brightness −0.15, at 22% opacity over Theatre Ground, under a vertical gradient (ground at 70%, clear, ground at 85%, solid ground). Focus changes cross-fade over 0.8 s ease-in-out. The spotlight follows the hero's current slide, any hovered card, and the open detail page. Settings clears it to bare ground. Titles without a Steam App ID leave the ground plain. It is decorative and hidden from accessibility.

## Do's and Don'ts

### Do:
- **Do** reserve Projector Red (#E50914) for the Play button's fill.
- **Do** build every surface as white at 6% (House Surface) or 10% (House Surface Raised) over Theatre Ground, and every hairline as white at 10%.
- **Do** show compatibility as tint + SF Symbol + label, using the five `Compatibility` cases and nothing else.
- **Do** mark every piece of demo content with all three demo devices: outlined badge, flask disc on the card, "Demo data" tag on the row or page.
- **Do** let each title's Steam logo art carry its name in the hero and on detail, on the Logo Plate when it is dark.
- **Do** use the two card sizes (landscape 296 × 138 pt, portrait 176 × 264 pt) with 10 pt corners, and align content to the 44 pt gutter.
- **Do** use `floatingGlass(cornerRadius:)` (Liquid Glass on macOS 26, `.ultraThinMaterial` before) for controls over artwork.
- **Do** honour Reduce Motion: no card lift, no hero auto-advance; the focus ring still shows.
- **Do** keep native controls native (sidebar, pickers, grouped Form, toolbar search) and let them take the graphite accent.
- **Do** put the reason under a disabled Play button in plain words.

### Don't:
- **Don't** use #E50914 for anything but Play: not for "Won't run", errors, focus, headings or brand marks.
- **Don't** give demo values a filled badge; filled means verified.
- **Don't** introduce opaque or tinted grey panels, borders around cards, or resting shadows on cards and panels.
- **Don't** put Liquid Glass or material on panels that sit on the ground.
- **Don't** replace available logo art with typeset names, or set dark logo art straight onto dark artwork.
- **Don't** add a light appearance; the window is dark by design.
- **Don't** convey compatibility with colour alone.
