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

- **Dossiers** : ajout (⌘O, bouton, glisser-déposer), analyse récursive, rescan (⌘R) ;
  **Réglages (⌘,) › Dossiers** : liste des dossiers analysés (nombre d'éléments, disque branché ou non),
  ajout, retrait, **exclusion de sous-dossiers** (aussi par clic droit sur un dossier)
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
- **Recherche par contenu** : « plage », « neige », « chien », « gâteau d'anniversaire »… (1 300 catégories
  reconnues par Vision, en français) — analyse en arrière-plan, mise en pause possible, tout reste sur le Mac
- **Lieux** : noms des villes et pays d'après le GPS (géocodage Apple, une zone d'environ 2 km à la fois),
  section « Lieux », recherche par lieu
- **Événements automatiques** : regroupement « Par événement » (coupure après 6 h, ou 1 h et 40 km),
  titrés par le lieu le plus fréquent
- **Photos similaires** : rafales et versions redimensionnées (empreinte perceptive + proximité dans le temps) ;
  « Garder la meilleure de chaque série » (la plus réussie selon Vision et vos annotations)
- **Photos ratées** : floues, trop sombres, surexposées, captures d'écran et documents, peu réussies ;
  « Ce n'est pas raté » pour les écarter de la liste
- **Diaporama** plein écran (fondu, léger zoom, musique au choix ; Espace, ← →, Échap)
- **Export** (taille, qualité, rotation, retrait du GPS) et **Partager** (Mail, Messages, AirDrop…)
- **Retouches non destructives** (visionneuse, touche E) : « J'ai de la chance », exposition, contraste,
  hautes lumières, ombres, saturation, chaleur, filtres (noir et blanc, sépia…), redressement, recadrage
  (libre, carré, 4:3, 3:2, 16:9…) ; appliquées à l'affichage, au diaporama et à l'export ; retouches Picasa reprises
- **Souvenirs** « Il y a N ans aujourd'hui » : bandeau, vue dédiée, diaporama
- **Texte dans les photos** (OCR Vision) : panneaux, documents, captures — cherchable
- **Frise chronologique** sur le bord de la grille et filtre **Période** (depuis / jusqu'à une année)
- **Recherche combinée avec suggestions** : « Sacha plage 2012 » ; propositions de personnes, lieux,
  albums, étiquettes, contenus et années pendant la frappe
- **Lieu des photos sans GPS** : clic droit › Lieu › Définir le lieu… (carte, recherche d'adresse) ou
  « d'après les photos prises juste avant ou après » (≤ 2 h)
- **Fichiers XMP** : import des sidecars existants (Mylio, Lightroom, digiKam : notes, personnes et zones
  des visages, légendes, lieux) ; écriture des annotations (menu Bibliothèque, option désactivée par défaut),
  **fusionnée** dans le XMP existant sans perdre les données des autres logiciels
- **Disque débranché** : la photothèque reste consultable (index + miniatures en cache), rebranchement
  détecté automatiquement ; **surveillance des dossiers** : nouvelles photos prises en compte toutes seules
- **Gestion des personnes** : renommer, fusionner (doublons détectés : casse, accents, prénom seul),
  masquer, photo de profil (portrait dans la barre latérale) — Réglages › Personnes ou clic droit
- **Correction des dates** (clic droit › Corriger la date…) : décalage (appareil mal réglé) ou date
  précise (photos scannées), avec aperçu ; dates d'origine rétablissables ; écrite dans le XMP si activé
- **Sauvegarde** (Réglages › Sauvegarde) : copie incrémentale vers un autre disque (arborescence conservée,
  fichiers manquants ou modifiés seulement, jamais de suppression, copie atomique) + données d'Albumine
- **Intégrité** : détection des fichiers vides, tronqués ou illisibles (vue « Fichiers abîmés »)
- **Recherche** : nom, dossier, personne, album, étiquette, légende, contenu, texte, lieu, appareil, année (sans accents)
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
- `~/Library/Application Support/Albumine/analysis.json` : analyse du contenu (catégories, qualité, empreintes)
- `~/Library/Application Support/Albumine/places.json` : noms des lieux
- `~/Library/Application Support/Albumine/xmp-state.json` : dernier état écrit dans chaque XMP
- `~/Library/Caches/Albumine/Miniatures` : miniatures (peut être supprimé)

Variables utiles au développement : `ALBUMINE_HOME` (autre dossier de données), `ALBUMINE_DEBUG` (journal sur stderr),
`ALBUMINE_AUTOIMPORT` (import Picasa automatique au démarrage).

## Note technique

Le SDK des Command Line Tools déclare `@State` comme macro sans fournir son plugin ;
le code utilise donc l'alias `@Etat` (= `SwiftUI.State`). Avec Xcode, `@State` fonctionne aussi.
