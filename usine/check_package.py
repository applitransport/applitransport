"""Contrôle un paquet de ligne en le décodant comme le fera l'appli, et le compare aux données
du POC (data/lines.json) quand la ligne y figure.

Usage : python usine/check_package.py C01527 [C01528 ...]
"""
import gzip
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
POC = ROOT.parent / "data" / "lines.json"


def decode_polyline(s):
    pts, i, lat, lon = [], 0, 0, 0
    while i < len(s):
        vals = []
        for _ in range(2):
            shift = result = 0
            while True:
                b = ord(s[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            vals.append(~(result >> 1) if result & 1 else result >> 1)
        lat += vals[0]
        lon += vals[1]
        pts.append((lat / 1e5, lon / 1e5))
    return pts


def decode_trips(pkg):
    """{trip_id: [(stop_id, arrivée, départ), ...]}"""
    out = {}
    for entry in pkg["trips"]:
        trip_id, pattern, _, first, deltas = entry[:5]
        dwell = entry[5] if len(entry) > 5 else [0] * (len(deltas) + 1)
        deps = [first]
        for d in deltas:
            deps.append(deps[-1] + d)
        stops = pkg["patterns"][pattern]["stops"]
        out[trip_id] = [(s, dep - w, dep) for s, dep, w in zip(stops, deps, dwell)]
    return out


def check(code, poc):
    pkg = json.loads(gzip.decompress((ROOT / "out" / "public" / "lines" / f"{code}.json.gz").read_bytes()))
    trips = decode_trips(pkg)
    print(f"{code} ({pkg['line']['short_name']}, {pkg['line']['type']}) : {len(pkg['patterns'])} parcours types, "
          f"{len(trips)} courses, {len(pkg['stops'])} arrêts, {len(pkg['shapes'])} tracés, version {pkg['version']}")
    route_id = pkg["route_id"]
    ref = {tid: t for tid, t in poc.get("trips", {}).items() if t["route_id"] == route_id}
    if not ref:
        return True
    ok = True
    if set(ref) != set(trips):
        print(f"  ✗ courses différentes : {len(set(ref) ^ set(trips))}")
        ok = False
    bad = [tid for tid in ref if tid in trips and [tuple(s) for s in ref[tid]["stops"]] != trips[tid]]
    print(f"  {'✓' if not bad else '✗'} horaires identiques au POC ({len(ref) - len(bad)}/{len(ref)} courses)")
    # IDFM renumérote ses tracés : on compare les géométries, pas les identifiants
    route_shapes = [poc["shapes"][t["shape_id"]] for t in ref.values() if t["shape_id"] in poc["shapes"]]
    for sid, pts in pkg["shapes"].items():
        mine = decode_polyline(pts)
        if not any(len(mine) == len(o) and all(abs(a[0] - b[0]) < 2e-5 and abs(a[1] - b[1]) < 2e-5
                                               for a, b in zip(mine, o)) for o in route_shapes):
            print(f"  ✗ tracé {sid} ({len(mine)} points) introuvable dans le POC")
            ok = False
    print(f"  {'✓' if ok else '✗'} tracés identiques (à 1 m près)")
    return ok and not bad


if __name__ == "__main__":
    poc = json.loads(POC.read_text()) if POC.exists() else {}
    results = [check(code, poc) for code in sys.argv[1:]]
    sys.exit(0 if all(results) else 1)
