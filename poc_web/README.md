# POC web (archive)

Premier prototype (FastAPI + Leaflet) qui a validé les données IDFM, le temps réel PRIM et le calcul
de position des bus avant l'appli Flutter (`../appli`). Gardé comme référence, plus maintenu.

```bash
cd ..   # racine du projet ; le jeton est lu dans .prim_key, les données dans data/
.venv/bin/pip install -r poc_web/requirements.txt
.venv/bin/python poc_web/extract_gtfs.py data/gtfs_raw/IDFM-gtfs.zip   # → data/lines.json (5104, 5105)
cd poc_web && ../.venv/bin/python -m uvicorn app.main:app --port 8000
```
