"""Communes des arrêts, d'après le référentiel des arrêts IDFM (open data, sans compte) :
  - « Arrêts »          : quai (arrid) → commune ; quais de bus = IDFM:<arrid> dans le GTFS
  - « Zones d'arrêts »  : zone (zdaid) → commune ; gares SNCF = IDFM:monomodalStopPlace:<zdaid>

Le GTFS ne donne pas la commune : sans elle, impossible de distinguer les arrêts homonymes
(« Le Hameau » existe dans plusieurs villes).
"""
import csv
from pathlib import Path

import httpx

BASE = "https://data.iledefrance-mobilites.fr/api/explore/v2.1/catalog/datasets"
DIR = Path(__file__).resolve().parent / "out" / "referentiel"
FILES = {
    "arrets.csv": f"{BASE}/arrets/exports/csv?select=arrid,arrtown&delimiter=%3B",
    "zones-d-arrets.csv": f"{BASE}/zones-d-arrets/exports/csv?select=zdaid,zdatown&delimiter=%3B",
}


def download():
    DIR.mkdir(parents=True, exist_ok=True)
    for name, url in FILES.items():
        r = httpx.get(url, timeout=120, follow_redirects=True)
        r.raise_for_status()
        tmp = DIR / f"{name}.part"
        tmp.write_bytes(r.content)
        tmp.replace(DIR / name)


def towns():
    """{identifiant GTFS du quai : commune} ; vide si le référentiel n'a pas été téléchargé."""
    out = {}
    for name, prefix, id_col, town_col in [
        ("arrets.csv", "IDFM:", "arrid", "arrtown"),
        ("zones-d-arrets.csv", "IDFM:monomodalStopPlace:", "zdaid", "zdatown"),
    ]:
        path = DIR / name
        if not path.exists():
            continue
        with path.open(encoding="utf-8-sig") as f:
            for r in csv.DictReader(f, delimiter=";"):
                if r.get(town_col):
                    out[prefix + r[id_col]] = r[town_col]
    return out


if __name__ == "__main__":
    download()
    print(f"{len(towns())} quais avec commune")
