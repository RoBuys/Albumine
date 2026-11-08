# Albumine

Gestionnaire de photos pour macOS (SwiftUI), dans l'esprit des anciens organiseurs « locaux » :
vos photos restent dans vos dossiers, rien n'est déplacé ni modifié.

## Compiler et lancer

```bash
./build.sh && open Albumine.app
```

Fonctionne avec les seuls Command Line Tools (Xcode non requis). macOS 14 minimum.

## Fonctions (v0.1)

- Ajout de dossiers (⌘O, bouton ou glisser-déposer), analyse récursive, rescan (⌘R)
- Grille de miniatures rapide (taille réglable), tri par date de prise de vue ou par nom
- Visionneuse : double-clic ou Entrée/Espace ; ← → pour naviguer, Échap pour fermer
- Notes 0–5 étoiles (touches 0–5, inspecteur, menu contextuel), filtre « note minimale »
- Étiquettes (plusieurs séparées par des virgules), multi-sélection ⌘/⇧-clic
- Recherche : nom, dossier, étiquette, appareil, année (sans tenir compte des accents)
- Inspecteur : EXIF (date, dimensions, appareil, objectif, réglages, GPS → Plans), légende, rotation
- Grandes photothèques : listage immédiat, EXIF lus en arrière-plan, index persistant, cache disque des miniatures

## Import Picasa

Fichier › **Importer depuis Picasa…** (ou le bandeau proposé quand des `.picasa.ini` sont détectés).
Lit les `.picasa.ini` / `Picasa.ini` de chaque dossier et reprend, sans modifier aucun fichier :

| Picasa | Albumine |
|---|---|
| visages nommés (`faces=` + `[Contacts2]`) | **Personnes** (barre latérale, recherche) ; zones des visages conservées |
| albums (`albums=` + `[.album:…]`) | **Albums** |
| `rotate=rotate(n)` | rotation d'affichage |
| `star=yes` | 5 étoiles |
| `caption=` | légende |

L'import ne fait qu'ajouter : il peut être relancé sans risque. Non repris pour l'instant :
retouches (`filters=`), dossiers cachés `Originals` (copies avant retouche), données des vidéos.

## Données

- `~/Library/Application Support/Albumine/library.json` : dossiers suivis, notes, étiquettes, personnes, albums…
- `~/Library/Application Support/Albumine/index.json` : index des fichiers et EXIF
- `~/Library/Caches/Albumine/Miniatures` : miniatures (peut être supprimé)

Variables utiles au développement : `ALBUMINE_HOME` (autre dossier de données), `ALBUMINE_DEBUG` (journal sur stderr),
`ALBUMINE_AUTOIMPORT` (import Picasa automatique au démarrage).

## Note technique

Le SDK des Command Line Tools déclare `@State` comme macro sans fournir son plugin ;
le code utilise donc l'alias `@Etat` (= `SwiftUI.State`). Avec Xcode, `@State` fonctionne aussi.
