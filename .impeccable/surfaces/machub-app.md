---
version: 1
slug: "machub-app"
primary_target: "MacHub/App"
related_targets: []
---

Scope: MacHub main window (Home, Library, Search, Title detail, Settings). Mode: Operate.
Audience/job: Mac players find a title and launch it through Whisky; see honestly whether it can run.
Constraints: native macOS 15+ SwiftUI controls and navigation; demo data always labelled; Play enabled only when a real Whisky install exists.

## Direction contract

THESIS: A screening room for your library: the artwork is the interface and the chrome recedes into a dark theatre. It refuses the category's default grid of identical cards on a flat grey dashboard.
OWN-WORLD: Near-black warm ground (#0B0B0D), surfaces as white at 6–10% over the ground, SF Pro (Expanded width for titles; each game's own Steam logo art is the display voice), one projector-red action colour (#E50914) used only for Play and "running", and compatibility state colours (green/yellow/orange/red/grey), each with an icon and label.
STORY: The visitor sees what is featured, what is really installed versus demo, what runs well, and presses Play or opens the detail.
FIRST VIEWPORT: Native floating sidebar on the left. A full-bleed hero at about 60% of the height, with the artwork filling it, a scrim to the left and bottom, the logo art at the left, then compatibility, genres and year, a 2-line summary, and Play (red) plus Details. A strip of featured thumbnails at the bottom right; the first row peeks below.
FORM: pinned by the user brief (Netflix Gaming / GameHub screenshots); the signature move is ambient marquee light, where the focused title's artwork bleeds, blurred, into the whole window ground and cross-fades as focus moves. seed:5228707b9d05d127 (roll recorded; the user-pinned brief outranks it, per new-work)
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
