"""Importe le GTFS IDFM complet dans une base SQLite (usine/out/idfm.sqlite).

Usage : python usine/build_db.py data/gtfs_raw/IDFM-gtfs.zip
Les heures sont stockées en secondes depuis minuit du jour de service (peuvent dépasser 24 h).
"""
import csv
import io
import sqlite3
import sys
import time
import zipfile
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent / "out"
DB_FILE = OUT_DIR / "idfm.sqlite"

SCHEMA = """
CREATE TABLE agency (agency_id TEXT PRIMARY KEY, agency_name TEXT);
CREATE TABLE routes (route_id TEXT PRIMARY KEY, agency_id TEXT, short_name TEXT, long_name TEXT,
                     route_type INTEGER, color TEXT, text_color TEXT);
CREATE TABLE stops (stop_id TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL, location_type INTEGER,
                    parent_station TEXT);
CREATE TABLE trips (trip_id TEXT PRIMARY KEY, route_id TEXT, service_id TEXT, headsign TEXT,
                    direction_id INTEGER, shape_id TEXT);
CREATE TABLE stop_times (trip_id TEXT, stop_sequence INTEGER, stop_id TEXT, arrival INTEGER, departure INTEGER);
CREATE TABLE shapes (shape_id TEXT, seq INTEGER, lat REAL, lon REAL);
CREATE TABLE calendar (service_id TEXT PRIMARY KEY, monday INTEGER, tuesday INTEGER, wednesday INTEGER,
                       thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
                       start_date TEXT, end_date TEXT);
CREATE TABLE calendar_dates (service_id TEXT, date TEXT, exception_type INTEGER);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""

INDEXES = """
CREATE INDEX idx_trips_route ON trips(route_id);
CREATE INDEX idx_st_trip ON stop_times(trip_id, stop_sequence);
CREATE INDEX idx_st_stop ON stop_times(stop_id);
CREATE INDEX idx_shapes ON shapes(shape_id, seq);
CREATE INDEX idx_cd_service ON calendar_dates(service_id);
CREATE INDEX idx_stops_parent ON stops(parent_station);
"""


def hms(t):
    if not t:
        return None
    h, m, s = t.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def rows(zf, name):
    with zf.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


def load(db, zf, name, sql, convert, batch=50000):
    start, n, buf = time.time(), 0, []
    for r in rows(zf, name):
        buf.append(convert(r))
        if len(buf) >= batch:
            db.executemany(sql, buf)
            n += len(buf)
            buf.clear()
    db.executemany(sql, buf)
    n += len(buf)
    print(f"  {name:<20} {n:>10} lignes  {time.time() - start:6.1f} s", flush=True)


def build(zip_path, db_file=DB_FILE):
    OUT_DIR.mkdir(exist_ok=True)
    tmp = db_file.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;" + SCHEMA)
    zf = zipfile.ZipFile(zip_path)
    t0 = time.time()

    load(db, zf, "agency.txt", "INSERT INTO agency VALUES (?,?)", lambda r: (r["agency_id"], r["agency_name"]))
    load(db, zf, "routes.txt", "INSERT INTO routes VALUES (?,?,?,?,?,?,?)",
         lambda r: (r["route_id"], r["agency_id"], r["route_short_name"], r["route_long_name"],
                    int(r["route_type"]), r["route_color"], r["route_text_color"]))
    load(db, zf, "stops.txt", "INSERT INTO stops VALUES (?,?,?,?,?,?)",
         lambda r: (r["stop_id"], r["stop_name"], float(r["stop_lat"]), float(r["stop_lon"]),
                    int(r["location_type"] or 0), r["parent_station"] or None))
    load(db, zf, "trips.txt", "INSERT INTO trips VALUES (?,?,?,?,?,?)",
         lambda r: (r["trip_id"], r["route_id"], r["service_id"], r["trip_headsign"],
                    int(r["direction_id"] or 0), r["shape_id"] or None))
    load(db, zf, "stop_times.txt", "INSERT INTO stop_times VALUES (?,?,?,?,?)",
         lambda r: (r["trip_id"], int(r["stop_sequence"]), r["stop_id"],
                    hms(r["arrival_time"]), hms(r["departure_time"])))
    load(db, zf, "shapes.txt", "INSERT INTO shapes VALUES (?,?,?,?)",
         lambda r: (r["shape_id"], int(r["shape_pt_sequence"]), float(r["shape_pt_lat"]), float(r["shape_pt_lon"])))
    load(db, zf, "calendar.txt", "INSERT INTO calendar VALUES (?,?,?,?,?,?,?,?,?,?)",
         lambda r: (r["service_id"], *(int(r[d]) for d in ("monday", "tuesday", "wednesday", "thursday",
                                                           "friday", "saturday", "sunday")),
                    r["start_date"], r["end_date"]))
    load(db, zf, "calendar_dates.txt", "INSERT INTO calendar_dates VALUES (?,?,?)",
         lambda r: (r["service_id"], r["date"], int(r["exception_type"])))

    t1 = time.time()
    db.executescript(INDEXES)
    print(f"  index                          {time.time() - t1:6.1f} s")
    db.commit()
    db.close()
    tmp.replace(db_file)  # remplacement atomique : l'ancienne base reste valide jusqu'au bout
    print(f"Base {db_file} : {db_file.stat().st_size / 1e9:.2f} Go en {time.time() - t0:.0f} s")


if __name__ == "__main__":
    build(Path(sys.argv[1]))
