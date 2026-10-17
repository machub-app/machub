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

## Reste à faire

- **A3 en pause** (17/10/2026) : la bouteille `Steam` n'existe pas encore pour le fork. `whisky list` est vide et `BottleVM.plist` a `paths = []`, inchangé depuis 23:11. On reprend quand `whisky list` l'affiche : il faudra alors rejouer `games` sur cette bouteille (`TEST_RUNNER_MACHUB_INTEGRATION=1 xcodebuild … test -only-testing:MacHubTests/RealWhiskyTests`).
- B4 : banc d'essai sur une bouteille dédiée `MacHub-Test` (🔒 sur autorisation).
- C, D, E : voir le plan.

## Limites connues

- Le JSON de `games` et de `launch` n'a pas encore été observé sur le vrai fork (aucune bouteille) ; les erreurs, elles, l'ont été.
- `launch` ne rend la main qu'à la fin de `-applaunch` ; l'état « en cours » de l'UI devra s'appuyer sur la détection du processus du jeu (D3).
- Localisation vérifiée au lancement de l'app sur macOS 26 seulement. La bascule à chaud via le sélecteur (même mécanisme `.id`) n'a pas été observée, faute de pilotage de l'UI. macOS 15 n'est pas disponible ici pour test.
- Les textes du diagnostic Whisky ne sont pas encore dans le catalogue (prévu en D6).
- Le runtime n'est vérifié que par la présence de `Libraries/Wine/bin/wine` ; Wine n'a pas été exécuté.
