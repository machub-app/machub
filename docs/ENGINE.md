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
WINE_BUILD=<dossier d'installation> WINE_SOURCES=<wine-11.0.tar.xz> VERSION=1.0.6 LLVM_MINGW=<dossier llvm-mingw> scripts/build-runtime.sh <cache> <sortie>
```

`build-wine.sh` applique les correctifs de `tools/wine-patches/` : `0001` (pas d'icône Dock pour les processus d'arrière-plan listés dans `MACHUB_NO_DOCK_ICON`, vérifié sur `argv[0]` et `argv[1]`) et `0002` (export de `macdrv_functions` et vue cliente pour DXMT). Le manifeste produit contient déjà l'adresse de téléchargement (`releases/download/runtime-<version>/…`) : publier l'archive sous ce tag, puis copier le manifeste dans `MacHub/Engine/runtime-manifest.json`. Les essais CrossOver (WineCX) ont été abandonnés et retirés du dépôt (voir l'historique plus bas).

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

**Unitaires** (sans réseau ni Wine) :

```bash
xcodebuild test -scheme MacHub -skip-testing:MacHubTests/RealSteamTests -skip-testing:MacHubTests/RealWhiskyTests -skip-testing:MacHubTests/RealEngineTests -skip-testing:MacHubTests/RealSteamEngineTests -skip-testing:MacHubTests/FreshInstallTests -skip-testing:MacHubTests/RealUpdateTests
```

**Réels, sur ce Mac** :
- `TEST_RUNNER_MACHUB_ENGINE_ARCHIVE=<archive> … -only-testing:MacHubTests/RealEngineTests` installe le moteur, crée un environnement et ouvre le Bloc-notes.
- `TEST_RUNNER_MACHUB_ENGINE_STEAM=1 … -only-testing:MacHubTests/RealSteamEngineTests` installe et démarre Steam.
- `TEST_RUNNER_MACHUB_FRESH_INSTALL=1 … -only-testing:MacHubTests/FreshInstallTests` télécharge le moteur publié dans un dossier vide et crée un environnement (premier lancement).
- `TEST_RUNNER_MACHUB_UPDATE_CHECK=1 … -only-testing:MacHubTests/RealUpdateTests` trouve la dernière release sur GitHub et la prépare comme une mise à jour.
- `TEST_RUNNER_MACHUB_SHORTCUT_APP_ID=284160 … -only-testing:MacHubTests/RealShortcutTests` crée le raccourci Mac d'un jeu installé dans `~/Applications/MacHub Games` (comme le menu « … » du jeu).

## Historique des essais du 18/10/2026 (pour mémoire)

1. **Wine 11 (paquet WineHQ, moteur 1.0.0).** Installation, environnement et Bloc-notes fonctionnent sans Whisky. Steam s'installe, mais sa fenêtre de connexion reste noire. Essayés sans succès :
   - DXVK pour `steamwebhelper` (dans system32 + AppDefaults) ;
   - rendu logiciel de Chromium ;
   - variables d'environnement de Whisky ;
   - rendu Vulkan de wined3d.
2. **WineCX 24, build Gcenx (1.1.0).** Les fenêtres de Steam s'affichent, mais Steam boucle sur « Unexpected Transport Error (0x3008) » : `WebUITransport: Connection rejected`. C'est un défaut connu des versions antérieures à CrossOver 25.
3. **WineCX 26.2 compilé par MacHub (1.2.0).** Le Bloc-notes fonctionne, Steam s'installe, et **l'erreur 0x3008 a disparu** (la connexion locale est acceptée). Sur mes captures, la fenêtre de connexion paraît encore noire, mais ces captures ne sont pas fiables pour les surfaces dessinées par la carte graphique. **À vérifier à l'œil.**

## État (moteur 1.0.5, MacHub 0.3.1, 20/10/2026)

| Fonction | État |
|---|---|
| Moteur intégré : installation vérifiée (SHA-256), versions côte à côte, environnements, sans Whisky | ✅ vérifié, y compris un premier téléchargement depuis GitHub dans un dossier vide (`FreshInstallTests`) |
| Steam pour Windows : installation silencieuse, connexion du compte, téléchargements, mises à jour | ✅ vérifié (fenêtre de Steam affichée grâce au relais `tools/steam-cef-shim`, une seule icône dans le Dock grâce au correctif `0001`) |
| **BeamNG.drive** en Direct3D 11 via DXMT | ✅ joué plusieurs minutes (correctif `0002` pour DXMT) ; `-gfx dx11` saute le lanceur |
| Graphismes par jeu (DXMT, DXVK, wined3d), options de lancement, résumé de performances | ✅ code et tests ; seul BeamNG a été lancé |
| Menu d'un jeu (mettre à jour, vérifier, dossier, propriétés, arrêter, désinstaller), arrêt forcé | ✅ code et tests ; ⏳ désinstaller / vérifier pas encore essayés sur un vrai jeu |
| Échec de création d'un environnement chez Johan (message vide) | ⏳ non reproduit ici ; depuis 0.2.0, nouvelle tentative automatique, journal `wineboot-*.log` et code de sortie affichés |
| Bibliothèque sans clé, lue dans le cache de Steam pour Windows (jeux de la Famille Steam compris) | ✅ vérifié sur ce Mac (5 jeux, outils filtrés) |
| Estimation de compatibilité (tests MacHub, version Mac, anti-triche, DirectX 12, ProtonDB) | ✅ vérifiée sur Découvrir |
| Mods Nexus (recherche, installation, activation, suppression) | ✅ recherche ; ⏳ installation jamais essayée (il faut la clé API de l'utilisateur) |
| **DirectX 12 / D3DMetal** | ⏳ import guidé seulement ; l'envoi des jeux DX12 vers D3DMetal reste désactivé (`GPTKStore.canRunDirectX12 = false`) : D3DMetal vise le Wine de CrossOver, son fonctionnement avec notre Wine 11 officiel reste à vérifier |
| Mises à jour automatiques de l'app (releases GitHub) | ✅ vérifiées de bout en bout (0.1.9 → 0.2.0 en 6 s) |
| Données highball-db (verdict, rendu, options, problèmes connus) et recommandations appliquées | ✅ vérifié sur BeamNG (`-gfx dx11`) et Subnautica 2 |
| Recettes highball-db (correctifs en un clic, composants Windows) | ✅ vcrun2022 installe le vrai `msvcp140.dll` de Microsoft (`RealRecipeTests`) ; ⏳ pas encore essayé sur la recette d'un vrai jeu |
| Signalement d'un jeu (formulaires pré-remplis highball-db / MacHub) | ✅ liens testés ; ⏳ pas encore envoyé pour de vrai |
| Réglages avancés par jeu (synchro, AVX, 4 Go, HUD, résolution, DLL, variables) | ✅ code et tests ; ⏳ pas essayé en jeu |
| Raccourci Mac par jeu (`machub://play/<id>`) | ✅ vérifié : le raccourci BeamNG lance le jeu, MacHub fermé |
| Réglages › Stockage (espace disque, dossier de jeux externe, désinstallation) | ✅ tests ; ⏳ ajout d'un dossier externe pas vérifié avec Steam |
| Bibliothèque Epic (Legendary 0.21.1) | ✅ binaire téléchargé, vérifié et lancé ; ⏳ connexion, liste, installation et lancement non vérifiés (compte Epic nécessaire) |
| Statut Discord | ⏳ code et trames testés ; désactivé tant que l'Application ID Discord de MacHub n'est pas renseigné |
| CI GitHub (`runtime.yml`, `release.yml`) | ⏳ écrite, jamais exécutée |
| Traductions | ✅ anglais et français complets ; ❌ japonais et chinois pas à jour |

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
