# Moteur Windows intégré

MacHub exécute les programmes Windows avec **son propre Wine**, compilé à partir des sources officielles de WineHQ (Wine 11.0) avec quelques correctifs maison (`tools/wine-patches/`), plus DXMT et DXVK. Moteur par défaut : **1.0.5**. Whisky n'est plus nécessaire ; il reste utilisable comme moteur de secours pour les bouteilles qui existent déjà.

## Architecture (`MacHub/Engine/`)

| Fichier | Rôle |
|---|---|
| `WineRuntime.swift` | `RuntimeManifest`, `RuntimeInfo` (`runtime.json`), `RuntimeManager` : installation vérifiée (SHA-256, extraction dans un dossier temporaire, puis déplacement atomique), téléchargement, versions côte à côte, détection de Rosetta |
| `WinePrefix.swift` | `PrefixStore` (création, réparation `wineboot -u`, clés du pilote Mac), `WineEnvironment` (variables de chaque processus Wine) |
| `EngineSettings.swift` | Réglages globaux (synchronisation msync/esync, AVX, mémoire 4 Go, journaux, overlays, Retina, clavier, plein écran) et `GraphicsChoice` |
| `GraphicsDetection.swift` | Lecture des imports PE (`d3d9/d3d11/d3d12/vulkan-1/opengl32`), choix de la couche, `TitleSettings` par jeu |
| `GraphicsLayer.swift` | Installation par programme de DXMT ou DXVK (DLL à côté de l'exécutable + `AppDefaults\<exe>\DllOverrides`), registre des fichiers posés (`machub-graphics.json`) : une DLL fournie par le jeu n'est jamais remplacée |
| `GPTKStore.swift` | Import guidé de D3DMetal depuis le Game Porting Toolkit téléchargé par l'utilisateur chez Apple |
| `SteamSetup.swift` | Installation silencieuse de Steam pour Windows, environnement nécessaire à Chromium, mise au premier plan des fenêtres Wine |
| `CompatibilityEngine.swift` | Protocole commun ; `EmbeddedWineEngine` (moteur intégré) et `WhiskyEngine` (secours) |
| `PerformanceLog.swift` | Résumé de performances d'une session (FPS moyen, creux, pire, mémoire) lu dans le journal du compteur Metal (`MTL_HUD_LOG_ENABLED`), sans rien injecter dans le jeu ; 10 sessions gardées par jeu (`performance.json`) |

Autour du moteur :
- `Steam/SteamLibrary.swift` lit `libraryfolders.vdf` et `appmanifest_*.acf`, et suit la progression des téléchargements.
- `LibraryStore` choisit le moteur de chaque environnement et gère l'installation, le lancement et l'arrêt.
- `UI/EngineSettingsView.swift` et `UI/SettingsView.swift` affichent les Réglages par catégories.
- La page de chaque jeu a un panneau « Launch & Graphics » (options de lancement, Direct3D, dernier résumé de performances) et un menu « … » (aussi en clic droit dans la Bibliothèque) : Mettre à jour, Vérifier les fichiers, Afficher le dossier, Propriétés Steam, Arrêter, Désinstaller. Ces actions passent par les liens `steam://` de Steam pour Windows.
- `Mods/NexusMods.swift`, `Mods/NexusModInstaller.swift`, `UI/NexusModsView.swift` : catalogue Nexus Mods pour BeamNG.drive, Cyberpunk 2077 et Dead Island 2 (voir plus bas).

## Emplacements

- Moteurs : `~/Library/Application Support/app.machub.MacHub/Runtimes/<version>/`
- Environnements : `~/Library/Application Support/app.machub.MacHub/Prefixes/<uuid>/` (préfixe Wine + `prefix.json`)
- D3DMetal importé : `~/Library/Application Support/app.machub.MacHub/GPTK/lib/`
- Réglages : `engine-settings.json`, `title-settings.json` dans `app.machub.MacHub/`
- Journaux Wine : `~/Library/Logs/app.machub.MacHub/Wine/`

## Construire le moteur

```bash
MACOS_LIBS=<dossier wine/lib du paquet WineHQ 11.0> scripts/build-wine.sh <wine-11.0.tar.xz> <dossier de travail> <dossier d'installation>
VARIANT=source WINE_BUILD=<dossier d'installation> WINE_SOURCES=<wine-11.0.tar.xz> VERSION_OVERRIDE=1.0.5 LLVM_MINGW=<dossier llvm-mingw> scripts/build-runtime.sh <cache> <sortie>
```

`build-wine.sh` applique les correctifs de `tools/wine-patches/` : `0001` (pas d'icône Dock pour les processus d'arrière-plan listés dans `MACHUB_NO_DOCK_ICON`, vérifié sur `argv[0]` et `argv[1]`) et `0002` (export de `macdrv_functions` et vue cliente pour DXMT). Les scripts `build-winecx.sh` et la variante `cx-source` restent pour mémoire (essais CrossOver abandonnés).

Prérequis :
- Xcode ;
- Homebrew, avec `bison pkgconf freetype gnutls sdl2` ;
- llvm-mingw (version macOS universelle), extrait dans le dossier de travail.

La compilation prend environ 15 minutes sur un Mac à puce M. Copiez ensuite `runtime-manifest.json` dans `MacHub/Engine/`.

Le workflow `.github/workflows/runtime.yml` doit publier l'archive avec ses sources. Il utilise la variante `source` (comme le moteur 1.0.5) mais n'a **jamais été exécuté** (pas encore de dépôt distant).

Problèmes de compilation résolus (détaillés dans les commentaires du script) :
- le compilateur d'Xcode est appelé par son chemin complet, car llvm-mingw a son propre `clang` ;
- le chemin du SDK macOS est passé explicitement ;
- un lien sans espace mène aux bibliothèques (« Application Support » cassait les options du compilateur) ;
- pas de `--with-opengl`, car le test EGL ne concerne que X11 et Wayland ;
- les noms de freetype et gnutls sont donnés explicitement ;
- un lien vers freetype est placé dans le dossier de compilation, car SIP supprime les variables `DYLD_*`.

## Prérequis : Rosetta 2

Ce Wine est compilé pour Intel (x86_64) et passe donc par Rosetta 2. MacHub détecte son absence et affiche la commande `softwareupdate --install-rosetta --agree-to-license`.

Apple garde Rosetta pour tous les usages jusqu'à macOS 27, puis seulement une partie destinée aux jeux. Le moteur est interchangeable, pour pouvoir passer à un Wine natif ARM64 dès qu'il existera.

## Tests

**Unitaires** (84 tests, sans réseau ni Wine) :

```bash
xcodebuild test -scheme MacHub -skip-testing:MacHubTests/RealSteamTests -skip-testing:MacHubTests/RealWhiskyTests -skip-testing:MacHubTests/RealEngineTests -skip-testing:MacHubTests/RealSteamEngineTests
```

**Réels, sur ce Mac** :
- `TEST_RUNNER_MACHUB_ENGINE_ARCHIVE=<archive> … -only-testing:MacHubTests/RealEngineTests` installe le moteur, crée un environnement et ouvre le Bloc-notes.
- `TEST_RUNNER_MACHUB_ENGINE_STEAM=1 … -only-testing:MacHubTests/RealSteamEngineTests` installe et démarre Steam.

## Historique des essais du 18/10/2026

1. **Wine 11 (paquet WineHQ, moteur 1.0.0).** Installation, environnement et Bloc-notes fonctionnent sans Whisky. Steam s'installe, mais sa fenêtre de connexion reste noire. Essayés sans succès :
   - DXVK pour `steamwebhelper` (dans system32 + AppDefaults) ;
   - rendu logiciel de Chromium ;
   - variables d'environnement de Whisky ;
   - rendu Vulkan de wined3d.
2. **WineCX 24, build Gcenx (1.1.0).** Les fenêtres de Steam s'affichent, mais Steam boucle sur « Unexpected Transport Error (0x3008) » : `WebUITransport: Connection rejected`. C'est un défaut connu des versions antérieures à CrossOver 25.
3. **WineCX 26.2 compilé par MacHub (1.2.0).** Le Bloc-notes fonctionne, Steam s'installe, et **l'erreur 0x3008 a disparu** (la connexion locale est acceptée). Sur mes captures, la fenêtre de connexion paraît encore noire, mais ces captures ne sont pas fiables pour les surfaces dessinées par la carte graphique. **À vérifier à l'œil.**

## État

| Fonction | État |
|---|---|
| Moteur intégré : installation, versions, environnements, Bloc-notes, sans Whisky | ✅ vérifié |
| Steam pour Windows : installation silencieuse, mise à jour, démarrage | ✅ vérifié |
| Fenêtre de connexion de Steam | ✅ **affichée** (moteur 1.2.2) grâce au relais `tools/steam-cef-shim` (`--disable-gpu --single-process` injecté dans `steamwebhelper.exe` seulement). `--in-process-gpu` seul ne suffisait pas |
| Connexion de Steam à ses serveurs | ✅ avec le moteur **1.0.1** (Wine 11 officiel + relais) : mise à jour en quelques secondes, serveurs joints, vrai QR code affiché, CPU au repos ~2 %. ❌ avec les Wine CrossOver (24 et 26.2) : Steam ne lance jamais sa connexion (`EConnect called` en boucle, cause non trouvée). ❌ avec `ROSETTA_ADVERTISE_AVX=1` + `WINE_LARGE_ADDRESS_AWARE=1` : mise à jour figée à 100 % CPU (ces options sont désormais désactivées par défaut) |
| Connexion du compte Steam (même SteamID que MacHub), installation de BeamNG.drive (19,5 Go, ~89 Mbit/s) | ✅ vérifié, progression affichée dans MacHub |
| Moteur 1.0.2 : notre Wine 11.0 compilé (`scripts/build-wine.sh`) + relais Steam + correctif Dock | ✅ Steam y tourne, une seule icône |
| **BeamNG.drive lancé depuis MacHub, rendu Direct3D 11 via DXMT** (moteur 1.0.4) | ✅ menu, réglages et plusieurs minutes de jeu (rapport utilisateur, 18/10/2026). Il a fallu le correctif `0002` : exporter `macdrv_functions` dans winemac au format attendu par DXMT, et créer une vue cliente (`macdrv_client_surface_create`) pour les fenêtres Direct3D, qui n'en ont pas dans le Wine officiel (cf. ticket DXMT n°170) |
| Lanceur de BeamNG resté ouvert à 100 % CPU après la fin du jeu | ✅ corrigé : MacHub arrête après 20 s les processus d'un jeu restés seuls après la fermeture du jeu, et un bouton « Stop » ferme tous ses processus |
| Réglages (compteur d'images, synchronisation…) appliqués aux jeux | ✅ MacHub redémarre Steam avant un lancement si Steam tourne avec d'anciens réglages (les jeux héritent de l'environnement de Steam) |
| Graphismes par jeu : détection, DXMT, DXVK, wined3d, AppDefaults, panneau sur la page du jeu | ✅ code et tests ; ⏳ aucun jeu lancé avec |
| DXMT : `winemetal` intégré au moteur 1.2.1 | ✅ archive construite ; ⏳ non installée ni testée |
| D3DMetal : import guidé | ✅ code et tests. L'acheminement des jeux DirectX 12 vers D3DMetal reste désactivé tant qu'il n'est pas testé |
| Réglages par catégories | ✅ vérifié sur captures |
| CI GitHub | ⏳ écrite, jamais exécutée |
| Traductions des nouveaux textes | ✅ français complet (724 textes) ; ❌ japonais et chinois pas à jour |
| Une seule icône Steam dans le Dock, même lancé depuis un terminal | ✅ moteur 1.0.5 (correctif `0001` qui regarde aussi `argv[1]`) |
| Raccourcis `.desktop`/`.url` créés par Steam sur le Bureau du Mac | ✅ corrigé : dossiers utilisateur du préfixe isolés du Mac, `winemenubuilder` désactivé |
| Processus Wine restés ouverts après un arrêt forcé | ✅ corrigé : « Force Quit All Windows Programs » (Réglages › Moteur) arrête `wineserver` puis les processus orphelins du moteur |
| Options de lancement par jeu (`-gfx dx11` pour BeamNG, qui saute le lanceur) | ✅ vérifié |
| Résumé de performances après une session | ✅ lecture du journal vérifiée ; ⏳ mesure propre à refaire (la première a été faite pendant que d'autres programmes chargeaient le Mac) |
| Mettre à jour / Vérifier / Désinstaller / Propriétés depuis MacHub | ✅ code et tests ; ⏳ pas encore essayé sur un vrai jeu |
| Catalogue Nexus Mods (recherche, fiche, installation, activation, suppression) | ✅ recherche vérifiée en réel ; ⏳ téléchargement et installation à essayer avec une clé de l'utilisateur |
| Installation automatique de Steam Service sur un nouvel environnement | ⏳ code écrit, pas vérifié sur un environnement neuf |
| Comparatif de performances Whisky / moteur intégré | ⏳ à faire sur un Mac au repos |

## Limites connues

- Une icône par processus Windows dans le Dock : **corrigé** dans le moteur 1.0.2 (Wine 11.0 WineHQ compilé par MacHub avec les correctifs Gcenx et `tools/wine-patches/0001-winemac-no-dock-icon-for-listed-helpers.patch`). MacHub passe `MACHUB_NO_DOCK_ICON=steam.exe;…` : Steam n'a plus qu'une icône (celle de sa fenêtre, `steamwebhelper.exe`). Vérifié le 18/10/2026.

- L'interface de Steam est rendue par logiciel (processeur) : un peu plus de charge CPU que sous Windows, sans effet sur les jeux eux-mêmes.
- Le Wine compilé n'inclut pas GStreamer (`--without-gstreamer`) : les vidéos d'introduction de certains jeux (Unity, H.264) peuvent les bloquer. Il reste à l'ajouter.
- Les jeux protégés par un anti-triche au niveau du noyau ne fonctionnent pas sous Wine.
- Les emojis du lanceur de BeamNG s'affichent en « □□ » : Wine ne rend pas les emojis couleur (cosmétique).
- BeamNG signale des « bibliothèques tierces » (d3d11.dll, dxgi.dll) : ce sont les DLL de DXMT posées par MacHub, l'avertissement est sans danger.

## Mods Nexus Mods

- Navigation : API GraphQL publique de Nexus (`api.nexusmods.com/v2/graphql`), sans clé.
- Fichiers et téléchargements : API REST v1 avec la **clé API personnelle** de l'utilisateur (gratuite, nexusmods.com › Settings › API keys), gardée dans le Trousseau (service `app.machub.MacHub.nexus-api`), jamais dans un fichier ni un journal.
- Compte gratuit : MacHub ouvre la page des fichiers ; l'utilisateur clique « Mod Manager Download » ; Nexus ouvre un lien `nxm://` déclaré dans `MacHub-Info.plist` ; MacHub télécharge avec la clé temporaire du lien. Compte Premium : téléchargement direct. Aucun contournement du Premium.
- Installation (archives `.zip` seulement, contrôles zip-slip et liens symboliques, sauvegarde de tout fichier remplacé) :
  - BeamNG.drive : le `.zip` tel quel dans `AppData/Local/BeamNG/BeamNG.drive/current/mods` du préfixe ;
  - Cyberpunk 2077 : fusion dans le dossier du jeu (`archive`, `bin`, `r6`, `red4ext`…) ;
  - Dead Island 2 : `.pak/.utoc/.ucas` dans `DeadIsland/Content/Paks/~mods`.
- Désactiver déplace les fichiers dans les données de MacHub ; supprimer les met à la Corbeille et remet les fichiers d'origine. Registre : `mods/nexus/<domaine>/installed.json`.
