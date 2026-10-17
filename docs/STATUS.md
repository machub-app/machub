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

## Ce qui est réel vs démo dans l'interface

| Élément | Réel | Démo |
|---|---|---|
| Statut Whisky (pied de barre latérale, Réglages) | ✅ lu en direct via `WhiskyLocator` / `DiagnosticsReport` | |
| Rangée « Installés dans Whisky » | ✅ alimentée par `whisky games <bouteille>` ; aujourd'hui un état vide réel (aucune bouteille) | |
| Bouton Jouer sur un jeu installé | ⚠️ code réel (`whisky launch`), **jamais exécuté** faute de bouteille ; affiche « Envoyé à Steam », jamais « en cours » | |
| Jaquettes, héros, logos | ✅ CDN public Steam par App ID (vérifié 200 pour les 18 App ID utilisés) | |
| Les 21 titres affichés aujourd'hui | | 🧪 `DemoLibrary` : noms, studios et années réels ; compatibilité **indicative** ; badge « Données de démo » partout ; Jouer désactivé ; masquables dans Réglages |
| Résumés des titres de démo | | 🧪 rédigés pour la démo, en anglais (contenu, pas interface) |
| Compatibilité | | 🧪 aucune source de données ; les vrais jeux affichent « Non testé » |
| Mods, profils de bouteille, import d'.exe | ❌ pas encore construits (phases suivantes) | |

## Reste à faire

- **A3 en pause** (17/10/2026) : la bouteille `Steam` n'existe pas encore pour le fork. `whisky list` est vide et `BottleVM.plist` a `paths = []`, inchangé depuis 23:11. On reprend quand `whisky list` l'affiche : il faudra alors rejouer `games` sur cette bouteille (`TEST_RUNNER_MACHUB_INTEGRATION=1 xcodebuild … test -only-testing:MacHubTests/RealWhiskyTests`).
- Bloqué par Whisky : la bouteille `Steam` (aucune n'existe dans le fork), donc la rangée « Installés », le vrai Jouer, A3 et B4.
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
