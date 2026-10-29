"""Génère appli/assets/poc_data.json : données réalistes mais figées pour le POC IHM Flutter.

Source : les paquets et le catalogue de l'usine (usine/out). Pour chaque ligne de démonstration et
chaque sens, on garde toutes les variantes de parcours du jour choisi, avec tracé (allégé) et horaires.

Usage : python scripts/gen_poc_ihm_data.py [AAAA-MM-JJ]
"""
import gzip
import json
import sys
from collections import Counter
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "appli" / "test" / "fixtures" / "poc_data_reference.json"  # référence des tests du décodeur
DEMO_NETWORK = "IDFM:1068"  # Saint-Quentin-en-Yvelines
DEMO_TRAINS = {"N", "U"}  # Transilien desservant Saint-Quentin
# Lignes avec horaires de démo : réseau SQY, lignes qui partagent un de ses arrêts, trains N et U.
# Le catalogue (recherche, téléchargement) contient lui toutes les lignes d'Île-de-France.

sys.path.insert(0, str(ROOT / "usine"))
from check_package import decode_polyline, decode_trips  # noqa: E402


def load(path):
    return json.loads(gzip.decompress(path.read_bytes()))


def active(pkg, service_id, day):
    key = day.strftime("%Y%m%d")
    for d, typ in pkg["calendar_dates"].get(service_id, []):
        if d == key:
            return typ == 1
    c = pkg["calendar"].get(service_id)
    return bool(c) and c[1] <= key <= c[2] and c[0][day.weekday()] == "1"


def thin(points, max_points=150):
    step = max(1, len(points) // max_points)
    return [[round(a, 5), round(b, 5)] for a, b in points[::step]] + [[round(points[-1][0], 5), round(points[-1][1], 5)]]


def demo_line(code, day):
    pkg = load(ROOT / "usine" / "out" / "public" / "lines" / f"{code}.json.gz")
    trips = decode_trips(pkg)
    pattern_of = {e[0]: e[1] for e in pkg["trips"]}
    service_of = {e[0]: e[2] for e in pkg["trips"]}
    directions = []
    for direction in (0, 1):
        today = [tid for tid in trips if pkg["patterns"][pattern_of[tid]]["direction_id"] == direction
                 and active(pkg, service_of[tid], day)]
        if not today:
            continue
        variants = []
        # une variante par parcours type, la plus fréquente en premier
        for pattern_index, _ in Counter(pattern_of[t] for t in today).most_common():
            pattern = pkg["patterns"][pattern_index]
            selected = sorted((t for t in today if pattern_of[t] == pattern_index), key=lambda t: trips[t][0][2])
            variants.append({
                "headsign": pattern["headsign"],
                # [nom, lat, lon, zone d'arrêt] : la zone regroupe les quais d'un même lieu
                "stops": [[pkg["stops"][s][0], pkg["stops"][s][1], pkg["stops"][s][2], pkg["stops"][s][3] or s]
                          for s in pattern["stops"]],
                "shape": thin(decode_polyline(pkg["shapes"][pattern["shape_id"]])) if pattern["shape_id"] else [],
                # départ (s depuis minuit) à chaque arrêt, pour chaque course
                "trips": [[dep for _, _, dep in trips[t]] for t in selected],
            })
        directions.append({"direction_id": direction, "label": variants[0]["headsign"], "variants": variants})
    if not directions:
        return None
    return {"id": code, "name": pkg["line"]["short_name"], "color": pkg["line"]["color"],
            "text_color": pkg["line"]["text_color"], "type": pkg["line"]["type"],
            "network": pkg["line"]["network"], "directions": directions}


def main(day):
    catalog = load(ROOT / "usine" / "out" / "public" / "catalog.json.gz")
    sqy = {l["route_id"] for l in catalog["lines"] if l["network"] == DEMO_NETWORK}
    demo = set(sqy) | {l["route_id"] for l in catalog["lines"]
                       if l["type"] == "train" and l["short_name"] in DEMO_TRAINS}
    for a in catalog["stop_areas"]:
        if set(a["lines"]) & sqy:
            demo |= set(a["lines"])
    demo_lines = [x for x in (demo_line(r.split(":")[-1], day) for r in sorted(demo)) if x]
    data = {
        "generated_for": day.isoformat(),
        "networks": catalog["networks"],
        "catalog": [{"id": l["route_id"].split(":")[-1], "name": l["short_name"], "long_name": l["long_name"],
                     "type": l["type"], "network": l["network"], "color": l["color"], "text_color": l["text_color"],
                     "size": l["size"]} for l in catalog["lines"]],
        "stop_areas": [{"id": a["id"], "name": a["name"], "aliases": a.get("aliases", []), "lines": a["lines"]}
                       for a in catalog["stop_areas"]],
        "demo_lines": demo_lines,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    # seules la 5104 et la 5105 servent de référence aux tests du décodeur Dart
    ref = {"generated_for": data["generated_for"],
           "demo_lines": [l for l in demo_lines if l["id"] in ("C01527", "C01528")]}
    OUT.write_text(json.dumps(ref, ensure_ascii=False, separators=(",", ":")))
    print(f"{OUT} : {OUT.stat().st_size / 1e6:.1f} Mo, {len(data['catalog'])} lignes au catalogue, "
          f"{len(data['stop_areas'])} zones d'arrêt, {len(demo_lines)} lignes avec horaires de démo "
          f"({sum(1 for l in demo_lines if l['network'] == DEMO_NETWORK)} SQY)")


if __name__ == "__main__":
    main(date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else date.today())
