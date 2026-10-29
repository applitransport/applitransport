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
La version d'un paquet est l'empreinte de son contenu (identifiants de tracés IDFM renumérotés localement,
car ils changent à chaque publication) : l'appli ne retélécharge que les lignes réellement modifiées.
