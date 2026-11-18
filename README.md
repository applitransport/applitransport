# AppliTransport

Suivi des transports en commun d'Île-de-France sur téléphone : horaires hors ligne, position des
véhicules, temps réel et perturbations, itinéraires, et un mode communauté (positions et signalements
des voyageurs). Données Île-de-France Mobilités (licence ODbL). Site : https://applitransport.cypherlux.fr

| Dossier | Rôle |
|---|---|
| `usine/` | **Usine à données** (Python) : GTFS IDFM → catalogue + un paquet par ligne, publiés chaque jour ([README](usine/README.md)) |
| `appli/` | **Appli** Flutter (Android, et Linux pour les tests sur PC) ([README](appli/README.md)) |
| `communaute/` | **Serveur communautaire** (Python) : positions et signalements des voyageurs, en mémoire ([README](communaute/README.md)) |
| `.github/workflows/tests.yml` | Vérifications à chaque envoi : analyse et tests de l'appli, tests du serveur, compilation de l'usine |
| `scripts/` | Outils : surveillance du temps réel PRIM, icône de l'appli, données de référence des tests |
| `poc_web/` | Premier POC web (FastAPI + Leaflet), archivé comme référence ([README](poc_web/README.md)) |

## Fonctionnement
```
IDFM (GTFS quotidien) ──► usine (serveur, 1×/jour) ──► dépôt applitransport/donnees (GitHub Pages)
                                                          │ catalog.json.gz + lines/*.json.gz, téléchargés par l'appli
téléphone : horaires hors ligne + temps réel PRIM appelé directement avec le jeton de l'utilisateur
          ◄──► serveur communautaire (positions et signalements, facultatif)
```
Chaque utilisateur crée son compte gratuit sur PRIM et saisit son jeton dans l'appli (Configuration ›
Jeton PRIM) : voir https://applitransport.cypherlux.fr/prim.html. Le jeton n'est jamais publié.

## Usine en local
```bash
python3 -m venv .venv && .venv/bin/pip install -r usine/requirements.txt
.venv/bin/python usine/update.py          # ne refait tout que si IDFM a publié un nouveau GTFS
.venv/bin/python -m http.server 8080 --bind 127.0.0.1 --directory usine/out/public
```

## Licence
Code : [PolyForm Strict 1.0.0](LICENSE.md) — utilisation gratuite à des fins non commerciales, sans
modification ni redistribution. Données : © Île-de-France Mobilités, ODbL ; carte : OpenFreeMap, © OpenMapTiles, © contributeurs OpenStreetMap.
Détails et bibliothèques tierces : [NOTICE.md](NOTICE.md).
