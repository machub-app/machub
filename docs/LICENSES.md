# Licences et obligations de redistribution

MacHub est distribué sous **GPLv3** (fichier `LICENSE`). Il est gratuit et open source.

## Composants du moteur Windows (archive `MacHubRuntime-<version>.tar.xz`)

Chaque composant reste sous sa propre licence. Le moteur est un ensemble de programmes séparés que MacHub lance comme processus : il n'est jamais lié au code de MacHub.

| Composant | Version (moteur 1.0.5) | Licence | Source | Obligations |
|---|---|---|---|---|
| Wine, sources officielles de WineHQ + correctifs Gcenx et MacHub, compilé par MacHub (`scripts/build-wine.sh`, `tools/wine-patches/`) | 11.0 | LGPL-2.1-or-later | dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz | Publier les sources exactes, les correctifs et les scripts de compilation avec chaque archive (fait par `.github/workflows/runtime.yml`) ; conserver les avis de licence ; permettre de remplacer Wine (il est dans son propre dossier) |
| Relais Steam `winmm.dll` (`tools/steam-cef-shim`) | moteur 1.0.5 | GPLv3 (code MacHub) | ce dépôt | Aucune au-delà de la GPLv3 |
| Bibliothèques macOS x86_64 du paquet WineHQ (freetype, gnutls, MoltenVK, SDL2, libpng, nettle…) | issues de wine-stable 11.0_1 | FreeType License / GPLv2, LGPL-2.1+, Apache-2.0, Zlib… (licence propre à chaque bibliothèque) | github.com/Gcenx/macOS_Wine_builds | Conserver les avis ; sources disponibles chez Gcenx/MacPorts (à joindre aux releases avant toute distribution publique) |
| Wine Mono, Wine Gecko | 10.4.1, Gecko du paquet WineHQ | MIT et divers (Mono), MPL-2.0 (Gecko) | WineHQ | Conserver les avis |
| DXMT | 0.80 | MIT (LGPL-2.1 à partir de la 1.0) | github.com/3Shain/dxmt | Conserver l'avis de licence |
| DXVK-macOS | 1.10.3-20230507 (async) | Zlib | github.com/Gcenx/DXVK-macOS | Conserver l'avis de licence |

## Ce que MacHub n'inclut pas

- **D3DMetal (Game Porting Toolkit d'Apple)** : sa licence ne permet que l'évaluation et le développement, sans droit de redistribution. L'utilisateur le télécharge chez Apple avec son propre compte ; MacHub en copie seulement les bibliothèques sur son Mac (`GPTKStore`). Rien n'est publié ni téléchargé chez un tiers.
- **Steam pour Windows** : installé depuis le CDN officiel de Valve (`SteamSetup.exe`), à la demande de l'utilisateur, qui accepte lui-même les conditions de Steam dans la fenêtre de Steam.
- **Code de Whisky** (GPLv3) : aucune ligne copiée à ce jour. Ses choix techniques ont servi de référence documentée (variables d'environnement pour Steam, marqueur « Wine builtin DLL »), et une reprise de code resterait compatible avec la GPLv3 de MacHub.

## Données de compatibilité (lues en ligne, non redistribuées)

| Source | Licence | Utilisation |
|---|---|---|
| highball-db, fiches curées et recettes (github.com/gauthierpiarrette/highball-db, via gethighball.com/data) | CC0-1.0 | Verdict, rendu et options recommandés, problèmes connus, affichés avec leur source |
| highball-db, prédictions (dérivées de ProtonDB) | ODbL-1.0 | Affichées avec l'attribution « ProtonDB via highball-db » |
| AreWeAntiCheatYet | MIT | Anti-triche, en secours quand highball-db n'a pas la fiche |
| ProtonDB (résumés) | conditions de ProtonDB | Palier Wine/Proton, seulement pour les jeux absents de highball-db |

## Marques

Steam est une marque de Valve, Nexus Mods de Black Tree Gaming, Metal, macOS et Rosetta d'Apple, CrossOver de CodeWeavers. MacHub n'est affilié à aucune de ces sociétés et cite ces noms seulement pour décrire la compatibilité.
