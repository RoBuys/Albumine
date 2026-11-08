# Albumine

Gestionnaire de photos pour macOS (SwiftUI), dans l'esprit des anciens organiseurs « locaux » :
vos photos restent dans vos dossiers, rien n'est déplacé ni modifié.

## Compiler et lancer

```bash
./build.sh && open Albumine.app
```

L'icône est générée par `Resources/make-icon.swift` (relancer `swift Resources/make-icon.swift` après modification).

Fonctionne avec les seuls Command Line Tools (Xcode non requis). macOS 14 minimum.

## Fonctions

- **Dossiers** : ajout (⌘O, bouton, glisser-déposer), analyse récursive, rescan (⌘R)
- **Grille** : miniatures rapides (taille réglable), **regroupement par dossier, par mois ou par année**
  (en-têtes épinglés, « Tout sélectionner »), tri par date de prise de vue ou par nom
- **Vidéos** (MOV, MP4, M4V, 3GP… ; AVI/WMV listés et ouverts dans l'application par défaut) :
  miniature, lecture dans la visionneuse, date et lieu lus dans les métadonnées
- **Visionneuse** : double-clic ou Entrée/Espace ; ← → ; F affiche les cadres des visages ; Échap
- **Notes** 0–5 étoiles (touches 0–5), **étiquettes**, **légendes**, **rotation** d'affichage
- **Albums virtuels** : une photo dans plusieurs albums sans copie ; créer (+), glisser des photos
  sur un album, clic droit › Ajouter à l'album, renommer, supprimer (les photos restent)
- **Personnes / visages** : détection et reconnaissance avec Vision (sur le Mac, rien n'est envoyé).
  Les visages déjà nommés servent d'exemples ; les nouveaux visages reçoivent un nom *proposé*
  à confirmer dans « Visages à nommer » ou dans l'inspecteur
- **Carte** : photos géolocalisées regroupées selon le zoom ; clic : bande de photos, double-clic : visionneuse
- **Doublons** : copies identiques (même taille + empreinte, puis comparaison octet par octet avant
  suppression) ; la copie la plus annotée est gardée, les autres vont **à la corbeille** (récupérables)
  et leurs notes, personnes et albums sont reportés
- **Recherche** : nom, dossier, personne, album, étiquette, légende, appareil, année (sans accents)
- **Inspecteur** : EXIF (date, dimensions, appareil, objectif, réglages, GPS → Plans), visages, personnes, albums
- **Grandes photothèques** : listage immédiat, métadonnées lues en arrière-plan, index persistant,
  cache disque des miniatures, lecture du disque limitée pour garder la grille fluide

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
retouches (`filters=`) et dossiers cachés `Originals` (copies avant retouche).

## Données

- `~/Library/Application Support/Albumine/library.json` : dossiers suivis, notes, étiquettes, personnes, albums…
- `~/Library/Application Support/Albumine/index.json` : index des fichiers et EXIF
- `~/Library/Application Support/Albumine/faceprints.dat` : empreintes des visages d'exemple
- `~/Library/Caches/Albumine/Miniatures` : miniatures (peut être supprimé)

Variables utiles au développement : `ALBUMINE_HOME` (autre dossier de données), `ALBUMINE_DEBUG` (journal sur stderr),
`ALBUMINE_AUTOIMPORT` (import Picasa automatique au démarrage).

## Note technique

Le SDK des Command Line Tools déclare `@State` comme macro sans fournir son plugin ;
le code utilise donc l'alias `@Etat` (= `SwiftUI.State`). Avec Xcode, `@State` fonctionne aussi.
