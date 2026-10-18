# Status

Plan : étapes A → E (faisabilité avant interface). Rien n'est marqué « fait » sans preuve.

## Fait (avec preuve)

| Tâche | Preuve |
|---|---|
| A1 Diagnostics de la machine | Plan v2, §1 |
| A2 Procédure d'installation | `docs/SETUP.md` |
| B1 Projet Xcode (macOS 15, Swift 6, non sandboxé, Swift Testing) | `xcodebuild … test` → `** TEST SUCCEEDED **`, 13/13 tests, 0 warning Swift |
| B2 `WhiskyLocator` + contrôle de capacités + lecture des bouteilles (lecture seule) | Tests sur fixtures ; `MacHub --diagnose` sur cette machine affiche « Whisky 2.3.5 too old, missing games, launch », 0 bouteille enregistrée, 6 dossiers orphelins sans `drive_c` ; empreinte du conteneur Whisky identique avant et après ; capture `docs/diagnostics-b2.png` |
| B3 `WhiskyCLI` : `games`, `launch`, `run`, `bottles` + erreurs typées (`invalidInvocation` 64, `failure` 1, `programExit(code, log)`, `timedOut`, `unexpectedOutput`) | 10 tests sur fixtures (JSON du fork, stderr réel « bottle doesn't exist », bruit avant le JSON, séparateur `--`) ; suite complète 23/23 |
| A3 (partiel) Fork réel | `docs/SETUP.md` § A3 ; MacHub le détecte `ready` ; tests d'intégration opt-in `RealWhiskyTests` 2/2 (erreurs typées vérifiées sur le vrai CLI ; le test `games` passe à vide, faute de bouteille) ; suite unitaire 25/25 |
| B5 Spike de localisation (en/fr/ja/zh-Hans) | Captures `docs/spike-l10n/*.png` : `Text("…")` et `LocalizedStringResource` suivent la langue choisie ; `String(localized:)` reste en langue système (« Réglages » partout, ton Mac étant en français). Décision : sélecteur dans l'app → `.environment(\.locale)` + `.id`, `String(localized:)` interdit dans l'UI |
| D (1re tranche) Interface : barre latérale native, accueil (hero + rangées), bibliothèque (grille, filtres, tri), recherche, fiche titre, réglages | App lancée sur ce Mac et capturée : `.impeccable/review/{home,library,detail,settings,home-en,home-ja}.png` ; 30/30 tests (dont `LibraryTests` : les titres de démo ne sont jamais lançables) |
| D6 (partiel) Localisation de l'interface | Toutes les chaînes extraites par le compilateur sont dans le catalogue (vérifié : 0 manquante), y compris 22 genres, en fr / ja / zh-Hans ; captures FR, EN, JA |
| Système visuel documenté | `DESIGN.md` + `.impeccable/design.json` (jetons SwiftUI, composants, règles) écrits à partir du code réel |
| Revue de design Impeccable (2 tours, le maximum) | 1er verdict « fix » (8 points), 2e verdict : 5 résolus, 2 partiels, 2 régressions ; dernier lot appliqué (logo sur plaque claire, un seul repère de démo par carte, identifiant court des bouteilles), vérifié sur les captures |

## Steam (tranche « bibliothèque connectée »)

| Élément | Source réelle | Preuve |
|---|---|---|
| Connexion | Steam **OpenID 2.0** dans le navigateur système → retour sur un récepteur `127.0.0.1:<port aléatoire>` (loopback uniquement, `GET /callback` seulement) → contrôles locaux (state, return_to, op_endpoint, champs signés, nonce < 5 min, `claimed_id == identity`, SteamID64 au format 7656119…) → **vérification directe auprès de Steam** (`check_authentication` → `is_valid:true`). Aucun mot de passe ni jeton ; `loginusers.vdf` n'est jamais traité comme une authentification | `SteamOpenIDTests` (9 assertions altérées refusées), `LoopbackServerTests` (vrai aller-retour HTTP) ; Steam accepte le realm loopback (redirection vers son formulaire, vérifiée par curl). **Connexion de bout en bout non encore faite : elle demande que tu te connectes toi-même** |
| Profil | `steamcommunity.com/profiles/<id>/?xml=1` (public, sans clé) : nom, avatar, visibilité | `RealSteamTests.publicProfile` (en direct) |
| Jeux possédés | `IPlayerService/GetOwnedGames` officiel ; **exige ta clé Web API** (401 sans, vérifié). Clé dans le **Trousseau** uniquement, jamais dans un fichier, un log ni une clé de cache. Profil privé → message explicite | `ownedGamesWithoutKeyIsUnauthorized` (en direct), `ownedGamesAndPrivateProfiles` |
| Catalogue | Recherche du Store (`search/results?json=1`, 50 par page, chargement progressif), `featuredcategories`, `appdetails`. **Aucune API officielle ouverte ne liste tout le catalogue** : `ISteamApps/GetAppList` a été retiré (404), `IStoreService/GetAppList` exige une clé (403). Recherche à la demande, cache disque (1 h vitrine, 15 min recherche, 24 h fiches), espacement de 350 ms par hôte, 429 → message, hors ligne → cache périmé affiché comme tel | `RealSteamTests` (5/5 en direct), `searchPagesDiffer` |
| Installés | `whisky games <bouteille>` + détection des `.exe` (racine + 1 niveau, installateurs exclus) | `executableScannerSkipsInstallers` ; aucune bouteille aujourd'hui |
| Logiciels | Imports manuels (`.exe` + bouteille, `software.json`) et programmes épinglés dans Whisky (`Metadata.plist` → `info.pins`, lecture seule) ; lancement `whisky run` | Code réel, **pas encore exécuté** (aucune bouteille) |
| Récents | Historique local de lancement (`history.json`) | Code réel |
| Jouer | Uniquement si installé + exécutable détecté + Whisky prêt. Sinon : « Installer dans « Steam » » (`steam://install/<id>` dans la bouteille, si Steam Windows y est), ou bouton désactivé + raison + panneau **Prérequis** | `storeAndOwnedTitlesNeverLaunch`, `installedWithoutExecutableIsNotLaunchable` |
| Compatibilité | Toujours « Non vérifiée » pour les vrais titres (aucune source). Seule info réelle : version Mac native signalée par Steam (`platforms.mac`) | Capture Cyberpunk 2077 |
| Démo | Désactivée par défaut, toujours étiquetée si on la réactive | `demoTitlesAreNeverLaunchable` |

Tests : **54/54** unitaires + **5/5** intégration Steam en direct + 2/2 intégration Whisky. Captures : `.impeccable/review/{home,discover,library,software,settings,detail,detail-new,search}.png`.

## Reste à faire

- **A3 en pause** (17/10/2026) : la bouteille `Steam` n'existe pas encore pour le fork. `whisky list` est vide et `BottleVM.plist` a `paths = []`, inchangé depuis 23:11. On reprend quand `whisky list` l'affiche : il faudra alors rejouer `games` sur cette bouteille (`TEST_RUNNER_MACHUB_INTEGRATION=1 xcodebuild … test -only-testing:MacHubTests/RealWhiskyTests`).
- **À faire par toi** : te connecter une fois via « Se connecter avec Steam » (vérifie OpenID de bout en bout), puis, si tu veux tes jeux possédés, coller ta clé Web API dans Réglages et rendre publics les « Détails des jeux ».
- Bloqué par Whisky : la bouteille `Steam` (aucune n'existe dans le fork), donc « Installés », le vrai Jouer, « Installer dans la bouteille », les logiciels, A3 et B4.
- Les endpoints du Store (recherche, vitrine, fiches) ne sont pas documentés par Valve : ils peuvent changer ; les erreurs sont gérées et le cache sert de repli.
- Jaquettes des jeux récents : Steam ne les expose qu'en petit format dans la recherche (231×87, affichées entières sur fond flouté) ; la fiche détaillée charge les grandes images.
- Les messages d'erreur techniques (Whisky, HTTP) restent en anglais.
- D3 : détection du processus du jeu après `launch` (état « en cours »).
- C : comptes Steam locaux, jeux possédés (clé API), métadonnées store, cache hors ligne.
- Écarts relevés par le documenteur Impeccable, non corrigés : fiche titre sans l'ombrage en haut à droite du hero d'accueil (ciel blanc) ; Réglages utilisent `.green/.orange/.red` système au lieu des teintes de compatibilité ; « Augmenter le contraste » promis dans PRODUCT.md mais pas implémenté.
- B4 : banc d'essai sur une bouteille dédiée `MacHub-Test` (🔒 sur autorisation).
- C, D, E : voir le plan.

## Limites connues

- Le JSON de `games` et de `launch` n'a pas encore été observé sur le vrai fork (aucune bouteille) ; les erreurs, elles, l'ont été.
- `launch` ne rend la main qu'à la fin de `-applaunch` ; l'état « en cours » de l'UI devra s'appuyer sur la détection du processus du jeu (D3).
- Localisation vérifiée au lancement de l'app sur macOS 26 seulement. La bascule à chaud via le sélecteur (même mécanisme `.id`) n'a pas été observée, faute de pilotage de l'UI. macOS 15 n'est pas disponible ici pour test.
- Survol, focus clavier et états de lancement non capturés (pas de pilotage de l'UI) ; vérifiés dans le code seulement. Raccourcis présents : ⌘1/⌘2/⌘3, ⌘F, ⌘, ; ←/→ sur le hero ; Entrée = Jouer sur la fiche (pas sur l'accueil, pour ne pas entrer en conflit avec la carte focalisée).
- Le focus clavier des cartes (`.focusable(interactions: .activate)`) n'a pas été testé avec l'Accès clavier complet activé.
- `--open <écran>` est un argument de lancement réservé aux builds Debug (captures).
- Le runtime n'est vérifié que par la présence de `Libraries/Wine/bin/wine` ; Wine n'a pas été exécuté.
