"""Extrait du GTFS IDFM les données des lignes SQYBUS ciblées vers data/lines.json.

Usage : python scripts/extract_gtfs.py data/gtfs_raw/IDFM-gtfs.zip
"""
import csv
import io
import json
import sys
import zipfile
from pathlib import Path

LINES = {"5104", "5105"}
OUT = Path(__file__).resolve().parent.parent / "data" / "lines.json"


def rows(zf, name):
    with zf.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


def hms_to_sec(t):
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def main(zip_path):
    zf = zipfile.ZipFile(zip_path)

    routes = {r["route_id"]: r for r in rows(zf, "routes.txt") if r["route_short_name"] in LINES}
    print("routes:", {r["route_short_name"]: rid for rid, r in routes.items()})

    trips = {t["trip_id"]: t for t in rows(zf, "trips.txt") if t["route_id"] in routes}
    print("trips:", len(trips))

    stop_times = {tid: [] for tid in trips}
    for st in rows(zf, "stop_times.txt"):
        lst = stop_times.get(st["trip_id"])
        if lst is not None:
            lst.append((int(st["stop_sequence"]), st["stop_id"],
                        hms_to_sec(st["arrival_time"]), hms_to_sec(st["departure_time"])))
    for lst in stop_times.values():
        lst.sort()

    stop_ids = {s[1] for lst in stop_times.values() for s in lst}
    stops = {}
    for s in rows(zf, "stops.txt"):
        if s["stop_id"] in stop_ids:
            stops[s["stop_id"]] = {"name": s["stop_name"], "lat": float(s["stop_lat"]),
                                   "lon": float(s["stop_lon"]), "parent": s["parent_station"]}

    shape_ids = {t["shape_id"] for t in trips.values() if t["shape_id"]}
    shapes = {sid: [] for sid in shape_ids}
    for p in rows(zf, "shapes.txt"):
        lst = shapes.get(p["shape_id"])
        if lst is not None:
            lst.append((int(p["shape_pt_sequence"]), float(p["shape_pt_lat"]), float(p["shape_pt_lon"])))
    shapes = {sid: [[lat, lon] for _, lat, lon in sorted(pts)] for sid, pts in shapes.items()}

    service_ids = {t["service_id"] for t in trips.values()}
    calendar = {c["service_id"]: c for c in rows(zf, "calendar.txt") if c["service_id"] in service_ids}
    calendar_dates = [c for c in rows(zf, "calendar_dates.txt") if c["service_id"] in service_ids]

    data = {
        "routes": {rid: {"name": r["route_short_name"], "color": r["route_color"]} for rid, r in routes.items()},
        "stops": stops,
        "shapes": shapes,
        "trips": {
            tid: {
                "route_id": t["route_id"], "service_id": t["service_id"],
                "direction_id": int(t["direction_id"] or 0), "headsign": t["trip_headsign"],
                "shape_id": t["shape_id"],
                # [stop_id, arrivée (s), départ (s)] — secondes depuis minuit du jour de service
                "stops": [[sid, arr, dep] for _, sid, arr, dep in stop_times[tid]],
            }
            for tid, t in trips.items()
        },
        "calendar": calendar,
        "calendar_dates": calendar_dates,
    }
    OUT.write_text(json.dumps(data, ensure_ascii=False))
    print(f"stops: {len(stops)}, shapes: {len(shapes)}, services: {len(service_ids)} -> {OUT}")


if __name__ == "__main__":
    main(sys.argv[1])
