# Installation de l'environnement (Whisky, fork frankea)

MacHub ne contient pas Wine. Il pilote **Whisky (fork frankea, `com.franke.Whisky`)** via son outil en ligne de commande `WhiskyCmd`. L'app vérifie elle-même que `WhiskyCmd --help` liste les commandes `games`, `launch` et `run`. Sinon, elle affiche « too old ».

## État constaté le 17/10/2026

- `/Applications/Whisky.app` = Whisky **2.3.5** original (archivé), sans `games`/`launch`, runtime Wine jamais installé.
- `~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/` : 6 dossiers (5 « assetto corsa », 1 « steam »), qui ne contiennent que `Metadata.plist`. Aucun `drive_c`, aucune bouteille enregistrée.
- Le fork frankea **n'est pas installé**.

MacHub ne modifie, ne déplace ni ne supprime jamais ces dossiers.

## DMG téléchargé et vérifié (17/10/2026)

`~/Downloads/Whisky-3.7.0.dmg` provient de la release `app-v3.7.0` publiée par `frankea` le 30/08/2026. Il fait 10 753 689 octets.

| Contrôle | Résultat |
|---|---|
| SHA-256 | `8232b3b9…3fbfee2`, **identique** au digest publié par GitHub |
| Signature du DMG | Valide, Developer ID Application: Adam Franke (Z7JS58F8U3) |
| Gatekeeper sur le DMG | Accepté, « Notarized Developer ID » |
| Ticket agrafé sur le DMG | Présent (`stapler validate` OK) |
| App contenue | `Whisky.app`, `com.franke.Whisky` 3.7.0, macOS 15.0 minimum, même équipe, hardened runtime, signature `--deep --strict` valide, Gatekeeper « Notarized Developer ID » |
| Ticket agrafé sur l'app | Absent, ce qui est normal : le ticket est porté par le DMG et Gatekeeper reconnaît l'app comme notarisée |
| `WhiskyCmd` | `Contents/Resources/WhiskyCmd`, signé par la même équipe, sans Info.plist embarqué : il utilisera donc le repli `com.franke.Whisky` (à confirmer en A3) |

L'image a été montée en lecture seule pour l'inspection, puis démontée. Rien n'a été exécuté ni installé.

## Étapes (manuelles, dans cet ordre)

1. **Préserver l'original.** Dans le Finder, renomme `/Applications/Whisky.app` en `Whisky 2.3.5.app`. Les deux apps portent le même nom ; ce renommage évite que le DMG du fork écrase l'original. Les données de l'original (`com.isaacmarovitz.Whisky`) ne sont pas touchées.
2. Télécharge `Whisky-3.7.0.dmg` (release `app-v3.7.0`) sur https://github.com/frankea/Whisky/releases et glisse `Whisky.app` dans `/Applications`.
3. Ouvre le nouveau Whisky et laisse-le installer son runtime Wine. La télémétrie est désactivée par défaut.
4. *(Optionnel, jeux DX12)* Whisky › Settings › Game Porting Toolkit : importe le GPTK d'Apple.
5. Crée une bouteille nommée exactement `Steam` (Windows 10). Installe-y Steam Windows avec le lanceur intégré, puis connecte-toi toi-même.
6. Dans ce Steam, installe Assetto Corsa.
7. *(Optionnel)* Menu Whisky › « Install Whisky CLI » (crée `/usr/local/bin/whisky`, demande le mot de passe admin).
8. *(Optionnel)* Crée une clé Steam Web API sur https://steamcommunity.com/dev/apikey. Elle permettra d'afficher aussi les jeux possédés mais pas installés.

Vérification : ouvre MacHub (ou lance `MacHub.app/Contents/MacOS/MacHub --diagnose`). La ligne Whisky doit indiquer `ready` et la bouteille `Steam` doit apparaître sous `com.franke.Whisky` comme « registered, drive_c ».

## Étape A3 : résultats (17/10/2026, lecture seule)

Installé : `/Applications/Whisky.app` = `com.franke.Whisky` 3.7.0 ; l'original est préservé sous `/Applications/Whisky 2.3.5.app`, avec ses 6 dossiers de bouteilles intacts.

- [x] **Aide réelle** : capturée telle quelle, elle sert désormais de fixture (`helpFork`). Sous-commandes : `list create add delete remove run games launch shortcut shellenv`. L'aide documente elle-même les codes 64 / 1 / code relayé.
- [x] **Runtime** : `~/Library/Application Support/com.franke.Whisky/Libraries/Wine/bin/wine` (et `wineserver`), plus `DXMT` et `DXVK`. `WhiskyWineVersion.plist` : runtime 3.1.1, DXMT 0.80, DXVK 1.10.3. Le binaire s'appelle `wine`, pas `wine64`.
- [x] **Erreurs** : sur stderr, jamais stdout. `games Nope --json` → code 1, « Error: A bottle with that name doesn't exist. ». Argument manquant → code 64. `launch 244210 --bottle Nope` → code 1 sans rien lancer.
- [ ] **Identifiant de bundle** : pas encore tranché. `whisky list` est vide, mais les registres de l'original et du fork sont vides tous les deux ; il faudra une bouteille dans le fork pour savoir lequel `WhiskyCmd` lit.
- [ ] **Bouteille Steam** : **absente**. `BottleVM.plist` → `paths = []`, pas de dossier `Bottles/`. `games` n'a donc pas pu être rejoué sur un vrai jeu.
- [ ] `launch` sans Steam connecté, et délai entre `launched` et le processus du jeu : nécessitent la bouteille, et un lancement réel (🔒).
