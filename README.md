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
- Inspecteur : EXIF (date, dimensions, appareil, objectif, réglages, GPS → Plans)

## Données

Notes, étiquettes et dossiers suivis : `~/Library/Application Support/Albumine/library.json`.

## Note technique

Le SDK des Command Line Tools déclare `@State` comme macro sans fournir son plugin ;
le code utilise donc l'alias `@Etat` (= `SwiftUI.State`). Avec Xcode, `@State` fonctionne aussi.
