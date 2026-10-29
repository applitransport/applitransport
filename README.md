# AppliTransport

Suivi des transports en commun d'Île-de-France sur téléphone : horaires hors ligne, position estimée
des bus, temps réel et perturbations, itinéraires. Données Île-de-France Mobilités (licence ODbL).

| Dossier | Rôle |
|---|---|
| `usine/` | **Usine à données** (Python) : GTFS IDFM → catalogue + un paquet par ligne, publiés chaque jour sur GitHub Pages ([README](usine/README.md)) |
| `appli/` | **Appli** Flutter (Android, et Linux pour les tests sur PC) ([README](appli/README.md)) |
| `.github/workflows/usine.yml` | Tâche quotidienne de l'usine et publication |
| `scripts/` | Outils : surveillance du temps réel PRIM, génération des données de référence des tests |
| `app/`, `web/` | Premier POC web (FastAPI + Leaflet), gardé comme référence |

## Fonctionnement
```
IDFM (GTFS quotidien) ──► usine (GitHub Actions, 1×/jour) ──► GitHub Pages : catalog.json.gz + lines/*.json.gz
                                                                   │ téléchargés par l'appli (lignes à la carte ou tout, ~13 Mo)
téléphone : horaires hors ligne + temps réel PRIM appelé directement avec le jeton de l'utilisateur
```
Chaque utilisateur crée son compte gratuit sur https://prim.iledefrance-mobilites.fr et saisit son jeton
dans l'appli (Configuration › Jeton PRIM). Le jeton n'est jamais publié.

## Usine en local
```bash
python3 -m venv .venv && .venv/bin/pip install -r usine/requirements.txt
.venv/bin/python usine/update.py          # ne refait tout que si IDFM a publié un nouveau GTFS
.venv/bin/python -m http.server 8080 --bind 127.0.0.1 --directory usine/out/public
```

## Licence
Code : [PolyForm Strict 1.0.0](LICENSE.md) — utilisation gratuite à des fins non commerciales, sans
modification ni redistribution. Données : © Île-de-France Mobilités, ODbL ; carte : © OpenStreetMap.
Détails et bibliothèques tierces : [NOTICE.md](NOTICE.md).
