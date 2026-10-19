# Licences et obligations de redistribution

MacHub est distribué sous **GPLv3** (fichier `LICENSE`). Il est gratuit et open source.

## Composants du moteur Windows (archive `MacHubRuntime-<version>.tar.xz`)

Chaque composant reste sous sa propre licence. Le moteur est un ensemble de programmes séparés que MacHub lance comme processus : il n'est jamais lié au code de MacHub.

| Composant | Version (moteur 1.2.1) | Licence | Source | Obligations |
|---|---|---|---|---|
| Wine, sources CrossOver de CodeWeavers, compilé par MacHub (`scripts/build-winecx.sh`) | 26.2.0 (Wine 11.0) | LGPL-2.1-or-later | media.codeweavers.com/pub/crossover/source/crossover-sources-26.2.0.tar.gz | Publier les sources exactes et les scripts de compilation avec chaque archive (fait par `.github/workflows/runtime.yml`) ; conserver les avis de licence ; permettre de remplacer Wine (il est dans son propre dossier) |
| Bibliothèques macOS x86_64 du paquet WineHQ (freetype, gnutls, MoltenVK, SDL2, libpng, nettle…) | issues de wine-stable 11.0_1 | FreeType License / GPLv2, LGPL-2.1+, Apache-2.0, Zlib… (licence propre à chaque bibliothèque) | github.com/Gcenx/macOS_Wine_builds | Conserver les avis ; sources disponibles chez Gcenx/MacPorts (à joindre aux releases avant toute distribution publique) |
| Wine Mono, Wine Gecko | 10.4.1, Gecko du paquet WineHQ | MIT et divers (Mono), MPL-2.0 (Gecko) | WineHQ | Conserver les avis |
| DXMT | 0.80 | MIT (LGPL-2.1 à partir de la 1.0) | github.com/3Shain/dxmt | Conserver l'avis de licence |
| DXVK-macOS | 1.10.3-20230507 (async) | Zlib | github.com/Gcenx/DXVK-macOS | Conserver l'avis de licence |

## Ce que MacHub n'inclut pas

- **D3DMetal (Game Porting Toolkit d'Apple)** : sa licence ne permet que l'évaluation et le développement, sans droit de redistribution. L'utilisateur le télécharge chez Apple avec son propre compte ; MacHub en copie seulement les bibliothèques sur son Mac (`GPTKStore`). Rien n'est publié ni téléchargé chez un tiers.
- **Steam pour Windows** : installé depuis le CDN officiel de Valve (`SteamSetup.exe`), à la demande de l'utilisateur, qui accepte lui-même les conditions de Steam dans la fenêtre de Steam.
- **Code de Whisky** (GPLv3) : aucune ligne copiée à ce jour. Ses choix techniques ont servi de référence documentée (variables d'environnement pour Steam, marqueur « Wine builtin DLL »), et une reprise de code resterait compatible avec la GPLv3 de MacHub.

## Marques

« CrossOver » est une marque de CodeWeavers. MacHub mentionne seulement l'origine des sources (« Wine, sources CrossOver de CodeWeavers ») et ne se présente jamais comme CrossOver.
