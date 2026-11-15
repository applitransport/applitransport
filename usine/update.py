"""Mise à jour quotidienne : si le GTFS IDFM a changé, le télécharge puis refait la base et les paquets.

Usage : python usine/update.py [--force]
Le changement est détecté par les en-têtes HTTP (ETag, Last-Modified, taille) comparés à out/state.json.
"""
import gzip
import json
import sys
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_db  # noqa: E402
import export  # noqa: E402
import referentiel  # noqa: E402

GTFS_URL = "https://eu.ftp.opendatasoft.com/stif/GTFS/IDFM-gtfs.zip"
ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "out"
STATE_FILE = OUT_DIR / "state.json"
ZIP_FILE = ROOT.parent / "data" / "gtfs_raw" / "IDFM-gtfs.zip"


def remote_info():
    r = httpx.head(GTFS_URL, follow_redirects=True, timeout=30)
    r.raise_for_status()
    return {k: r.headers.get(k) for k in ("etag", "last-modified", "content-length")}


def download(dest):
    tmp = dest.with_suffix(".part")
    with httpx.stream("GET", GTFS_URL, follow_redirects=True, timeout=120) as r:
        r.raise_for_status()
        with tmp.open("wb") as f:
            for chunk in r.iter_bytes(1 << 20):
                f.write(chunk)
    with zipfile.ZipFile(tmp) as zf:  # fichier tronqué ou corrompu : on garde l'ancien
        bad = zf.testzip()
        if bad:
            raise RuntimeError(f"archive corrompue ({bad})")
    tmp.replace(dest)


def line_versions():
    try:
        catalog = json.loads(gzip.decompress((export.PUBLIC_DIR / "catalog.json.gz").read_bytes()))
    except OSError:
        return {}
    return {line["route_id"]: line["version"] for line in catalog["lines"]}


def main(force=False):
    OUT_DIR.mkdir(exist_ok=True)
    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    info = remote_info()
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    if not force and info == state.get("remote"):
        print(f"{now} GTFS inchangé ({info['last-modified']}), rien à faire")
        state["last_check"] = now
        STATE_FILE.write_text(json.dumps(state, indent=1))
        return

    print(f"{now} nouveau GTFS ({info['last-modified']}, {int(info['content-length'] or 0) / 1e6:.0f} Mo)")
    t0 = time.time()
    ZIP_FILE.parent.mkdir(parents=True, exist_ok=True)
    download(ZIP_FILE)
    print(f"  téléchargé en {time.time() - t0:.0f} s")
    before = line_versions()
    try:
        referentiel.download()  # communes des arrêts
    except httpx.HTTPError as e:
        print(f"  référentiel des arrêts indisponible ({e}) : communes de la publication précédente")
    build_db.build(ZIP_FILE)
    export.export(feed_info={"last_modified": info["last-modified"], "etag": info["etag"]})
    after = line_versions()
    changed = sorted(k for k in after if before.get(k) != after[k])
    print(f"  {len(changed)} ligne(s) modifiée(s) sur {len(after)}, {len(set(before) - set(after))} supprimée(s)")
    STATE_FILE.write_text(json.dumps({"remote": info, "last_check": now, "last_update": now}, indent=1))
    print(f"  mise à jour terminée en {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main(force="--force" in sys.argv)
