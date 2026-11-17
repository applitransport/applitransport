# Usine à données

Transforme le GTFS IDFM (≈150 Mo, publié chaque jour) en fichiers légers pour l'appli.

```bash
.venv/bin/python usine/update.py          # vérifie, et ne refait tout que si le GTFS a changé (~3 min)
.venv/bin/python usine/update.py --force  # force la reconstruction
.venv/bin/python usine/check_package.py C01527 C01528   # contrôle de paquets
```

Produit dans `usine/out/` (seul `public/` est publié) :
- `idfm.sqlite` (≈2 Go) : base complète, usage interne à l'usine
- `public/catalog.json.gz` (≈0,5 Mo) : réseaux, lignes (type, réseau, couleur, version), zones d'arrêt + alias + lignes desservies
- `public/lines/<code>.json.gz` (quelques Ko à 170 Ko) : un paquet par ligne, format décrit en tête de `export.py`
- `state.json` : en-têtes HTTP du dernier GTFS traité

Les lignes de transport à la demande (sans horaires fixes) sont ignorées.
La version d'un paquet est l'empreinte de son contenu ; tracés et calendriers sont renumérotés
localement car IDFM les renumérote à chaque publication. Une ligne n'est **republiée** que si ses horaires
effectifs changent (comparés jour par jour avec la publication précédente) ou si la version en place
couvre moins de 21 jours : IDFM décale sa période d'un jour à chaque publication. L'appli ne retélécharge
donc que les lignes réellement modifiées.

## Lieux d'Île-de-France (OpenStreetMap)

`python usine/lieux.py [--force]` : une fois par semaine (rien à faire si la base a moins de 6 jours),
télécharge l'extrait Île-de-France de Geofabrik (≈ 340 Mo, supprimé ensuite), garde les lieux nommés qui
sont des destinations (≈ 170 000 : commerces, restaurants, santé, culture, loisirs, gares), fusionne les
doublons et publie `out/public/lieux/lieux.db.xz` (SQLite + index plein texte FTS5, ≈ 8 Mo) et
`lieux.json` (date, nombre, taille, empreinte). ≈ 3 min et 600 Mo de mémoire. Données © contributeurs
OpenStreetMap, licence ODbL.

