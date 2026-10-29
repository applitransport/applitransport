"""Récupère la publication en ligne (catalogue + paquets) dans out/public quand elle n'est pas déjà là
(cache GitHub Actions perdu, nouveau poste). Sans elle, l'export ne pourrait pas comparer avec la veille :
toutes les lignes changeraient de version et chaque appli retéléchargerait tout.

Usage : python usine/restore_publication.py [adresse de la publication]
"""
import gzip
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

DEFAULT_URL = "https://applitransport.github.io/applitransport/"
PUBLIC_DIR = Path(__file__).resolve().parent / "out" / "public"


def restore(base_url=DEFAULT_URL, out_dir=PUBLIC_DIR):
    if (out_dir / "catalog.json.gz").exists():
        print("publication précédente déjà présente (cache) : rien à récupérer")
        return
    base = base_url.rstrip("/") + "/"
    with httpx.Client(timeout=60, follow_redirects=True) as client:
        r = client.get(base + "catalog.json.gz")
        if r.status_code == 404:
            print("aucune publication en ligne (premier lancement) : rien à récupérer")
            return
        r.raise_for_status()
        catalog = json.loads(gzip.decompress(r.content))
        files = [line["file"] for line in catalog["lines"]]

        def fetch(path):
            resp = client.get(base + path)
            resp.raise_for_status()
            dest = out_dir / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(resp.content)

        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(fetch, files))
        # le catalogue en dernier : sa présence signifie que la publication est complète
        (out_dir / "catalog.json.gz").write_bytes(r.content)
    print(f"publication en ligne récupérée : {len(files)} paquets")


if __name__ == "__main__":
    restore(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL)
