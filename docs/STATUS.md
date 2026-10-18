# MacHub : état du projet

Dernier audit : 18/10/2026. Règle : rien n'est marqué « vérifié » sans preuve. L'historique des étapes précédentes est dans git (`fad1f69` et antérieurs).
Branche : `steam/library` (commit `fad1f69` + correctifs du profil non commités), base `main` @ `35b3883`.

## Vérifié (preuve à l'appui)

| Fonction | Preuve |
|---|---|
| Compilation (macOS 15, Swift 6) | `xcodebuild` OK, 0 warning Swift |
| Tests | **61/61** unitaires ; **7/7** intégration en direct (5 Steam, 2 Whisky) |
| Connexion Steam OpenID 2.0 | Connexion réelle réussie : compte enregistré avec date de vérification ; SteamID identique au compte du client Steam du Mac (`loginusers.vdf`). Assertions vérifiées localement puis par `check_authentication` |
| Profil public | Lu en direct. Ton profil Communauté n'est **pas configuré** : pas de nom ni d'avatar publiés, affiché comme tel (« Profil Communauté non configuré ») |
| Catalogue | Vitrine, recherche paginée (50 par page), fiches (FR, prix, Metacritic, captures, version Mac native), cache disque, pacing, états 429 / hors ligne |
| Détection Whisky | Fork 3.7.0 `ready`, Wine 3.1.1, DXMT 0.80, DXVK 1.10.3 |
| Erreurs du CLI Whisky | Codes 64 / 1 typés et vérifiés sur le vrai `WhiskyCmd` |
| Localisation | en / fr / ja / zh-Hans, 0 chaîne manquante |

## Spike P0-3 « MacHub Steam » (18/10/2026, en cours)

| Étape | Résultat |
|---|---|
| `whisky create "MacHub Steam"` | ✅ bouteille enregistrée (Windows 10) ; WhiskyCmd lit bien le registre `com.franke.Whisky` |
| Téléchargement de `SteamSetup.exe` (CDN Valve) | ✅ 2 380 800 octets, exécutable PE avec bloc Authenticode « Valve Corp. » / DigiCert (signature non vérifiée cryptographiquement sur macOS) |
| 1er `whisky run … /S` | ❌ « d3d11.dll n'existe pas » : **`create` n'initialise pas le préfixe Wine** (le message de Whisky dit d'ouvrir l'app) |
| Initialisation du préfixe | ✅ `wine64 wineboot --init` avec l'environnement de `whisky shellenv` (800 fichiers dans `system32`). **Bug WhiskyCmd** : le `PATH` de `shellenv` contient `Application\ Support` entre guillemets, donc inutilisable ; contournement : chemin absolu de `wine64` |
| `SteamSetup.exe /S` | ✅ `Steam.exe` installé ; mise à jour automatique de 238 Mo terminée (« Verification complete ») |
| Ouverture de Steam | ✅ fenêtre « Se connecter à Steam » créée et rendue (capturée), mais **ouverte en arrière-plan** : macOS ne laisse pas un processus d'arrière-plan prendre le focus |
| Connexion de l'utilisateur | ✅ Steam pour Windows connecté (`Success`) avec **un seul compte, identique au SteamID vérifié par OpenID** (`loginusers.vdf` + `userdata` de la bouteille). Fenêtre ramenée au premier plan via System Events |
| `steam://install/244210` | ✅ dialogue d'installation de Steam (42,08 Go annoncés), confirmé par toi ; Steam proposer l'installation prouve que **le jeu est possédé** |
| Téléchargement | ✅ 14,37 Go téléchargés, 44,95 Go sur disque, `StateFlags = 4` à 11:10 (≈ 30 min, jusqu'à 106 Mbps). **Leçon** : le manifest n'est pas mis à jour pendant le téléchargement ; la progression se lit dans `steamapps/downloading/<id>` + `logs/content_log.txt` (débit) |
| Détection par MacHub | ✅ `whisky games` → `244210 Assetto Corsa` ; `.exe` détectés (`AssettoCorsa.exe`, `acs.exe`, …) ; fiche : « Installé », « Exécutable détecté », **Jouer activé**. **Bug réel corrigé** : WhiskyCmd renvoie `appId` sous forme de chaîne (`"244210"`), et MacHub attendait un nombre (test d'intégration en échec puis vert) |
| Lancement vérifié (P1-3) | ✅ implémenté : MacHub surveille les processus Wine (exécutable au chemin Windows situé dans le dossier du jeu ; Steam, web helper et `_CommonRedist` exclus). États : En cours / Fermé / **Planté au lancement** (< 15 s) / Aucun processus en 3 min, avec un lien vers le log Wine |
| **Bug WhiskyCmd `launch`** | ❌ renvoie `{"status":"launched"}` (exit 0), mais **Steam ne reçoit jamais `-applaunch`** (absent de `console_log.txt` ; le log Whisky ne contient qu'un `reg import`). MacHub passe désormais par `whisky run … steam.exe -- -applaunch <id>` : vérifié, Steam journalise `LaunchApp` → `Game process added` |
| Faux positif corrigé | Le premier détecteur acceptait mon propre shell de surveillance (dont les arguments contenaient « \\assettocorsa\\ » et « .exe ») et affichait « En cours » à tort. Il exige maintenant que l'exécutable lui-même soit un chemin Windows. Test de régression ajouté |
| **Premier lancement réel** | ⚠️ `AssettoCorsa.exe` (le lanceur) démarre puis s'arrête au bout de **2 s** (journal de Steam : 10:23:01 → 10:23:03). MacHub affiche « planté au lancement ». Cause capturée avec `run --follow` : `System.TypeLoadException: Could not load file or assembly 'CEF3, Version=49.0.0.0'`. Le lanceur est une app **.NET** (en-tête CLR) avec un assembly mixte C++/CLI, que **Wine-Mono 10.4.1 ne sait pas charger**. `acs.exe` (le jeu) n'est pas .NET |
| .NET Framework 4.8 | ✅ installé avec ton accord (`winetricks -q dotnet48`, celui de Whisky, 11:24 → 11:28, exit 0). Registre : `Version 4.8.03761`, `Release 528049`. Steam pour Windows arrêté proprement avant (`-shutdown`). winetricks avait laissé la bouteille en Windows 7 ; **remise en Windows 10** (`winecfg -v win10`), conforme au réglage Whisky |
| **Lancement d'Assetto Corsa depuis MacHub** | ✅ **le lanceur tourne** : MacHub affiche « En cours : macOS voit AssettoCorsa.exe », confirmé par `ps` (2 processus, > 28 s), par Steam (`Game process added` sans `removed`) et par une fenêtre « Assetto Corsa Launcher » visible (capture `.impeccable/review/ac-launcher.png`). Steam était arrêté : la requête `-applaunch` l'a démarré, reconnecté automatiquement, puis a lancé le jeu |
| Jeu en piste (`acs.exe`) | ⏳ **non vérifié**. Tu as indiqué qu'une course avait démarré, mais à 11:31:42 aucun processus `acs.exe` n'existait et aucun `Documents/Assetto Corsa/logs/log.txt` (écrit par `acs.exe` dès le lancement) n'était présent ; le lanceur venait d'être prêt (« UI Ready » à 11:31:28). Surveillance en cours (`build/acs-watch.log`) |

Leçons pour P1-1 : enchaîner `create` → `wineboot --init` → installation silencieuse → lancement de Steam ; rappeler à l'utilisateur d'amener l'app « wine » au premier plan.

## Implémenté, jamais exécuté en conditions réelles (faute de bouteille)

`whisky games` → jeux installés ; détection des `.exe` ; Jouer (`whisky launch`) ; Installer (`steam://install` dans une bouteille Steam) ; logiciels importés (`whisky run`) ; épingles Whisky ; historique local.

## Partiel

- **Jeux possédés** : seulement avec ta clé Web API, et aucune clé n'est enregistrée. Sans clé, la liste complète est impossible (voir les décisions).
- **Lancement** : chaîne complète vérifiée jusqu'au processus du jeu ; Assetto Corsa plante encore au lancement (cause connue, voir le spike). Les logs Whisky ne contiennent que des en-têtes : la vraie erreur ne s'obtient qu'avec `run --follow` (à intégrer à MacHub, P2).
- **Trousseau** : en développement, la signature ad hoc change à chaque build, donc macOS peut redemander l'accès.

## Démo

`DemoLibrary` (21 titres, compatibilité indicative) : **désactivée par défaut**, toujours étiquetée.

## Bloqué

| Blocage | Cause exacte | Débloqué par |
|---|---|---|
| Session de jeu non vérifiée | Le lanceur fonctionne ; la course (`acs.exe`, DX11 via DXMT) reste à essayer | Toi : lancer une session depuis le lanceur |
| Liste complète des jeux possédés | Seule API officielle : `GetOwnedGames`, avec clé ; OAuth Steam réservé aux partenaires Valve ; la page publique des jeux exige une connexion | Ta clé (facultative), ou un proxy serveur (P3, profils publics uniquement) |

## Décisions d'architecture

1. **Identité** : OpenID 2.0 avec récepteur loopback ; jamais de mot de passe ni de jeton ; `loginusers.vdf` n'est pas une preuve d'identité.
2. **Clé Web API** : facultative, propre à l'utilisateur, stockée dans le Trousseau. D'après la doc de Valve, Steam renvoie les jeux « visibles pour vous », donc le propriétaire de la clé voit ses propres jeux. Pas de clé dans l'app : les conditions de Valve exigent qu'elle reste confidentielle. Pas de serveur pour l'instant.
3. **Fichiers de jeu et licences** : uniquement via **Steam pour Windows dans une bouteille gérée par MacHub** (« MacHub Steam »). Pas de SteamCMD (il faudrait manipuler tes identifiants), pas de téléchargement direct. Jeux Mac natifs → Steam pour Mac.
4. **Progression d'installation** : lue dans `appmanifest_<id>.acf` (`StateFlags`, octets) ; désinstallation via `steam://uninstall` (MacHub ne supprime rien lui-même).
5. **Compatibilité** : « Non vérifiée » tant qu'aucune source n'existe. Les limites (anti-triche, DX12 / GPTK, lanceurs tiers) sont affichées, jamais cachées.

## Tests de l'audit (18/10/2026)

- **Réussis** :
  - unitaires 55/55 ;
  - intégration Steam 5/5 (vitrine, pages de recherche distinctes, fiche d'Assetto Corsa, profil public, 401 sans clé) ;
  - intégration Whisky 2/2 (erreurs typées) ;
  - compte OpenID enregistré = compte du Mac ;
  - XML du profil « not set up » ;
  - page publique des jeux → redirection vers la connexion (alternative sans clé inexistante) ;
  - CDN `SteamSetup.exe` → 200 (2,38 Mo) ;
  - `whisky run --command` disponible ;
  - données locales : 5 apps lancées avec ce compte, dont **Assetto Corsa (244210)**.
- **Échoués** : aucun.
- **Impossibles (prérequis manquants)** : installation, lancement et vérification d'un jeu ; logiciels et épingles ; liste des jeux possédés (pas de clé).

## Actions qui te reviennent

1. Autoriser le spike P0-3 : création de la bouteille « MacHub Steam » + téléchargement de `SteamSetup.exe` officiel.
2. Te connecter dans la **fenêtre de Steam pour Windows** que MacHub ouvrira (jamais dans MacHub).
3. Valider l'installation d'Assetto Corsa (≈ 15 Go ; 237 Go libres) et confirmer que la fenêtre du jeu s'affiche.
4. *(Facultatif)* Créer une clé sur steamcommunity.com/dev/apikey et la coller dans Réglages.
5. *(Facultatif)* Configurer ton profil Communauté Steam (nom, avatar).

## Prochaines tâches

**P0**
- P0-3 : spike « MacHub Steam » avec Assetto Corsa : bouteille, Steam silencieux, ta connexion, installation, lancement.

**P1**
- P1-1 : assistant « Préparer l'environnement ».
- P1-2 : installer avec progression réelle (parseur ACF).
- P1-3 : **lancement vérifié** (surveillance du processus).
- P1-4 : rangée sans clé « Lancés avec ce compte sur ce Mac » + clé guidée avec bouton « Tester ».
- P1-5 : jeux Mac natifs via Steam pour Mac.
- P1-6 : désinstaller via Steam.

**P2**
- Log Wine accessible.
- Erreurs techniques localisées.
- Notifications.
- Developer ID et notarisation.
- Profils de compatibilité curés.
- Manette.
- Bascule de langue à chaud.

**P3**
- Mods d'Assetto Corsa non destructifs.
- Proxy serveur.
- Epic / GOG.
- Assistant GPTK.
- Sparkle.

**Reportés volontairement** : mods, proxy et sources de compatibilité, tant qu'un jeu n'a pas été lancé et vérifié.
