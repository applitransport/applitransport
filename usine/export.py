"""Fabrique, depuis la base SQLite, les fichiers téléchargés par l'appli :

  out/public/catalog.json.gz        catalogue : réseaux, lignes (avec version), zones d'arrêt et lignes qui y passent
  out/public/lines/<ligne>.json.gz  un paquet par ligne : arrêts, tracés, parcours types, courses, calendriers

out/public/ est exactement ce qui est publié (GitHub Pages, ou serveur local pendant le développement).

Format des paquets (FORMAT = 1) :
  stops     {stop_id: [nom, lat, lon, zone_d_arret]}
  shapes    {id local "s0", "s1"… : polyligne encodée (algorithme Google, précision 1e-5)}
  patterns  [{"direction_id", "headsign", "shape_id", "stops": [stop_id, ...]}]  (suite d'arrêts partagée par des courses)
  trips     [[trip_id, n° de pattern, service_id, départ au 1er arrêt (s), [écarts entre départs successifs (s)],
              (optionnel) [temps d'arrêt à chaque arrêt (s) : arrivée = départ - temps d'arrêt]]]
  calendar  {service_id: ["lmmjvsd" en 0/1, début AAAAMMJJ, fin AAAAMMJJ]}
  calendar_dates {service_id: [[AAAAMMJJ, 1 = ajouté | 2 = supprimé], ...]}

La version d'un paquet est l'empreinte de son contenu : l'appli ne retélécharge que les lignes modifiées.

Usage : python usine/export.py
"""
import gzip
import hashlib
import json
import sqlite3
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import referentiel  # noqa: E402

OUT_DIR = Path(__file__).resolve().parent / "out"
DB_FILE = OUT_DIR / "idfm.sqlite"
PUBLIC_DIR = OUT_DIR / "public"
FORMAT = 1
ROUTE_TYPES = {0: "tram", 1: "metro", 2: "train", 3: "bus", 6: "telepherique", 7: "funiculaire"}


def encode_polyline(points):
    """Encodage « Google polyline » : compact et facile à décoder en Dart."""
    out, prev_lat, prev_lon = [], 0, 0
    for lat, lon in points:
        ilat, ilon = round(lat * 1e5), round(lon * 1e5)
        for v in (ilat - prev_lat, ilon - prev_lon):
            v = ~(v << 1) if v < 0 else v << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev_lat, prev_lon = ilat, ilon
    return "".join(out)


def file_name(route_id):
    # IDFM:C01527 -> C01527
    return route_id.split(":")[-1]


def write_gz(path, obj):
    data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
    path.write_bytes(gzip.compress(data, compresslevel=9, mtime=0))
    return len(data)


def build_line(db, route):
    route_id = route["route_id"]
    trips = db.execute("SELECT trip_id, service_id, headsign, direction_id, shape_id FROM trips "
                       "WHERE route_id = ?", (route_id,)).fetchall()
    times = defaultdict(list)
    for trip_id, stop_id, arr, dep in db.execute(
            "SELECT st.trip_id, st.stop_id, st.arrival, st.departure FROM trips t "
            "JOIN stop_times st ON st.trip_id = t.trip_id WHERE t.route_id = ? "
            "ORDER BY st.trip_id, st.stop_sequence", (route_id,)):
        times[trip_id].append((stop_id, arr, dep))

    patterns, pattern_index, out_trips = [], {}, []
    # ordre déterministe (sens, heure de départ, id) : la version du paquet ne dépend que du contenu
    for trip_id, service_id, headsign, direction_id, shape_id in sorted(
            trips, key=lambda t: (t[3], times[t[0]][0][2] if times[t[0]] and times[t[0]][0][2] is not None else 0, t[0])):
        st = times.get(trip_id)
        # transport à la demande : créneaux de réservation sans horaire fixe, non suivable
        if not st or len(st) < 2 or any(s[1] is None or s[2] is None for s in st):
            continue
        key = (direction_id, headsign, shape_id, tuple(s[0] for s in st))
        if key not in pattern_index:
            pattern_index[key] = len(patterns)
            patterns.append({"direction_id": direction_id, "headsign": headsign, "shape_id": shape_id,
                             "stops": list(key[3])})
        deps = [s[2] for s in st]
        entry = [trip_id, pattern_index[key], service_id, deps[0], [b - a for a, b in zip(deps, deps[1:])]]
        dwell = [d - a for _, a, d in st]
        if any(dwell):
            entry.append(dwell)
        out_trips.append(entry)

    if not out_trips:
        return None, set()

    stop_ids = {s for p in patterns for s in p["stops"]}
    stops = {}
    for stop_id, name, lat, lon, parent in db.execute(
            f"SELECT stop_id, name, lat, lon, parent_station FROM stops WHERE stop_id IN "
            f"({','.join('?' * len(stop_ids))})", tuple(stop_ids)):
        stops[stop_id] = [name, round(lat, 6), round(lon, 6), parent]

    shape_ids = {p["shape_id"] for p in patterns if p["shape_id"]}
    pts = defaultdict(list)
    if shape_ids:
        for shape_id, lat, lon in db.execute(
                f"SELECT shape_id, lat, lon FROM shapes WHERE shape_id IN ({','.join('?' * len(shape_ids))}) "
                f"ORDER BY shape_id, seq", tuple(shape_ids)):
            pts[shape_id].append((lat, lon))

    service_ids = {t[2] for t in out_trips}
    q = ",".join("?" * len(service_ids))
    calendar = {r[0]: ["".join(str(x) for x in r[1:8]), r[8], r[9]]
                for r in db.execute(f"SELECT * FROM calendar WHERE service_id IN ({q})", tuple(service_ids))}
    calendar_dates = defaultdict(list)
    for sid, d, typ in db.execute(f"SELECT service_id, date, exception_type FROM calendar_dates "
                                  f"WHERE service_id IN ({q}) ORDER BY date", tuple(service_ids)):
        calendar_dates[sid].append([d, typ])

    # IDFM renumérote ses tracés à chaque publication sans les modifier : numérotation locale stable
    local_shape = {}
    for p in patterns:
        if p["shape_id"] and p["shape_id"] not in local_shape:
            local_shape[p["shape_id"]] = f"s{len(local_shape)}"
        p["shape_id"] = local_shape.get(p["shape_id"])

    package = {
        "format": FORMAT, "route_id": route_id,
        "line": {k: route[k] for k in ("short_name", "long_name", "type", "network", "color", "text_color")},
        "stops": stops,
        "shapes": {local_shape[sid]: encode_polyline(p) for sid, p in pts.items() if sid in local_shape},
        "patterns": patterns, "trips": out_trips,
        "calendar": calendar, "calendar_dates": dict(calendar_dates),
    }
    package["version"] = hashlib.sha256(json.dumps(package, sort_keys=True).encode()).hexdigest()[:16]
    return package, stop_ids


def export(db_file=DB_FILE, out_dir=PUBLIC_DIR, feed_info=None):
    t0 = time.time()
    db = sqlite3.connect(db_file)
    lines_dir = out_dir / "lines"
    lines_dir.mkdir(parents=True, exist_ok=True)

    networks = dict(db.execute("SELECT agency_id, agency_name FROM agency"))
    stop_parent = {sid: parent or sid for sid, parent in db.execute("SELECT stop_id, parent_station FROM stops")}

    catalog_lines, area_lines, total_raw, total_gz = [], defaultdict(set), 0, 0
    routes = db.execute("SELECT route_id, agency_id, short_name, long_name, route_type, color, text_color "
                        "FROM routes ORDER BY route_type, agency_id, short_name").fetchall()
    for i, (route_id, agency_id, short, long_, rtype, color, text_color) in enumerate(routes, 1):
        route = {"route_id": route_id, "short_name": short, "long_name": long_,
                 "type": ROUTE_TYPES.get(rtype, str(rtype)), "network": agency_id,
                 "color": color, "text_color": text_color}
        package, stop_ids = build_line(db, route)
        if not package:
            continue
        path = lines_dir / f"{file_name(route_id)}.json.gz"
        total_raw += write_gz(path, package)
        size = path.stat().st_size
        total_gz += size
        catalog_lines.append({**route, "file": f"lines/{path.name}", "version": package["version"], "size": size})
        for sid in stop_ids:
            area_lines[stop_parent.get(sid, sid)].add(route_id)
        if i % 200 == 0:
            print(f"  {i}/{len(routes)} lignes ({time.time() - t0:.0f} s)", flush=True)

    # les quais portent souvent un nom plus précis que leur zone (« Trappes Gare » dans la zone « Trappes ») :
    # on les garde comme alias pour la recherche
    # commune de la zone : celle de la majorité de ses quais (référentiel des arrêts IDFM)
    aliases = defaultdict(set)
    quay_town, area_towns = referentiel.towns(), defaultdict(Counter)
    for stop_id, parent, name in db.execute(
            "SELECT stop_id, parent_station, name FROM stops WHERE parent_station IS NOT NULL"):
        aliases[parent].add(name)
        if stop_id in quay_town:
            area_towns[parent][quay_town[stop_id]] += 1
    areas = []
    for area_id, name, lat, lon in db.execute(
            f"SELECT stop_id, name, lat, lon FROM stops WHERE stop_id IN ({','.join('?' * len(area_lines))})",
            tuple(area_lines)):
        area = {"id": area_id, "name": name, "lat": round(lat, 6), "lon": round(lon, 6),
                "lines": sorted(area_lines[area_id])}
        other = sorted(aliases[area_id] - {name})
        if other:
            area["aliases"] = other
        if area_towns[area_id]:
            area["town"] = area_towns[area_id].most_common(1)[0][0]
        areas.append(area)

    catalog = {"format": FORMAT, "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
               "license": {"name": "ODbL 1.0", "url": "https://opendatacommons.org/licenses/odbl/1-0/",
                           "attribution": "Île-de-France Mobilités"},
               "feed": feed_info or {}, "networks": networks, "lines": catalog_lines,
               "stop_areas": sorted(areas, key=lambda a: a["name"])}
    # paquets de lignes disparues du GTFS : retirés de la publication
    for old in set(lines_dir.glob("*.json.gz")) - {out_dir / l["file"] for l in catalog_lines}:
        old.unlink()
    write_gz(out_dir / "catalog.json.gz", catalog)
    (out_dir / "LICENCE.txt").write_text(
        "Données : © Île-de-France Mobilités, Open Database License (ODbL) 1.0\n"
        "https://opendatacommons.org/licenses/odbl/1-0/\n\n"
        "Base de données dérivée (catalogue et paquets de lignes) produite par l'usine d'AppliTransport :\n"
        "https://github.com/applitransport/applitransport\n", encoding="utf-8")
    print(f"{len(catalog_lines)} paquets : {total_raw / 1e6:.0f} Mo bruts, {total_gz / 1e6:.0f} Mo compressés ; "
          f"catalogue {(out_dir / 'catalog.json.gz').stat().st_size / 1e6:.1f} Mo ({len(areas)} zones d'arrêt, "
          f"{sum('town' in a for a in areas)} avec commune) "
          f"en {time.time() - t0:.0f} s")


if __name__ == "__main__":
    export()
