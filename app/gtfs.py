"""Accès aux données GTFS extraites (data/lines.json) et calcul de position théorique."""
import json
import math
from datetime import date, datetime, timedelta
from pathlib import Path

DATA_FILE = Path(__file__).resolve().parent.parent / "data" / "lines.json"
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def _dist(a, b):
    """Distance approximative en mètres entre deux points [lat, lon]."""
    lat = math.radians((a[0] + b[0]) / 2)
    dx = math.radians(b[1] - a[1]) * math.cos(lat)
    dy = math.radians(b[0] - a[0])
    return 6371000 * math.hypot(dx, dy)


class Gtfs:
    def __init__(self, path=DATA_FILE):
        d = json.loads(Path(path).read_text())
        self.routes = d["routes"]
        self.stops = d["stops"]
        self.shapes = d["shapes"]
        self.trips = d["trips"]
        self.calendar = d["calendar"]
        self.exceptions = {}
        for c in d["calendar_dates"]:
            self.exceptions[(c["service_id"], c["date"])] = c["exception_type"] == "1"
        self._shape_cum = {sid: self._cumulative(pts) for sid, pts in self.shapes.items()}
        self._stop_pos_cache = {}
        # numéro de course SIRI (fin du trip_id) -> trip_id
        self.trip_by_number = {tid.split("-")[-1]: tid for tid in self.trips}

    # --- calendrier -------------------------------------------------------
    def service_active(self, service_id, day: date):
        key = day.strftime("%Y%m%d")
        if (service_id, key) in self.exceptions:
            return self.exceptions[(service_id, key)]
        c = self.calendar.get(service_id)
        if not c or not (c["start_date"] <= key <= c["end_date"]):
            return False
        return c[WEEKDAYS[day.weekday()]] == "1"

    # --- lignes / directions / arrêts ---------------------------------------
    def stop_key(self, stop_id):
        """Regroupe les quais d'un même arrêt via la zone d'arrêt parente."""
        s = self.stops[stop_id]
        return s["parent"] or stop_id

    def lines(self):
        out = []
        for rid, r in sorted(self.routes.items(), key=lambda x: x[1]["name"]):
            directions = []
            for direction in (0, 1):
                trips = [t for t in self.trips.values() if t["route_id"] == rid and t["direction_id"] == direction]
                if not trips:
                    continue
                ref = max(trips, key=lambda t: len(t["stops"]))
                headsigns = sorted({t["headsign"] for t in trips}, key=lambda h: -sum(t["headsign"] == h for t in trips))
                directions.append({
                    "direction_id": direction,
                    "label": headsigns[0],
                    "headsigns": headsigns,
                    "stops": [{"key": self.stop_key(sid), "name": self.stops[sid]["name"]} for sid, _, _ in ref["stops"]],
                })
            out.append({"route_id": rid, "name": r["name"], "color": r["color"], "directions": directions})
        return out

    def line_geometry(self, route_id, direction_id):
        trips = [t for t in self.trips.values() if t["route_id"] == route_id and t["direction_id"] == direction_id]
        shape_ids = sorted({t["shape_id"] for t in trips if t["shape_id"]})
        stop_ids = {sid for t in trips for sid, _, _ in t["stops"]}
        return {
            "shapes": [self.shapes[s] for s in shape_ids],
            "stops": [{"id": sid, "key": self.stop_key(sid), **self.stops[sid]} for sid in stop_ids],
        }

    def active_trips(self, route_id, day: date):
        return [tid for tid, t in self.trips.items()
                if t["route_id"] == route_id and self.service_active(t["service_id"], day)]

    def departures(self, route_id, direction_id, stop_key, day: date):
        out = []
        for tid, t in self.trips.items():
            if t["route_id"] != route_id or t["direction_id"] != direction_id:
                continue
            if not self.service_active(t["service_id"], day):
                continue
            for k, (sid, arr, dep) in enumerate(t["stops"][:-1]):  # pas de départ au terminus
                if self.stop_key(sid) == stop_key:
                    out.append({"trip_id": tid, "stop_id": sid, "stop_index": k, "time": dep, "headsign": t["headsign"],
                                "terminus": self.stops[t["stops"][-1][0]]["name"]})
                    break
        return sorted(out, key=lambda d: d["time"])

    # --- position théorique ------------------------------------------------
    @staticmethod
    def _cumulative(pts):
        cum = [0.0]
        for a, b in zip(pts, pts[1:]):
            cum.append(cum[-1] + _dist(a, b))
        return cum

    def _stop_positions(self, trip_id):
        """Abscisse curviligne (m) de chaque arrêt de la course sur son tracé."""
        t = self.trips[trip_id]
        key = (t["shape_id"], tuple(s[0] for s in t["stops"]))
        if key in self._stop_pos_cache:
            return self._stop_pos_cache[key]
        pts = self.shapes.get(t["shape_id"])
        if not pts:
            return None
        cum = self._shape_cum[t["shape_id"]]
        result, start = [], 0
        for sid, _, _ in t["stops"]:
            s = self.stops[sid]
            p = [s["lat"], s["lon"]]
            # recherche du point de tracé le plus proche, sans revenir en arrière
            best = min(range(start, len(pts)), key=lambda i: _dist(pts[i], p))
            result.append(cum[best])
            start = best
        self._stop_pos_cache[key] = result
        return result

    def _point_at(self, shape_id, d):
        pts, cum = self.shapes[shape_id], self._shape_cum[shape_id]
        for i in range(1, len(cum)):
            if cum[i] >= d:
                seg = cum[i] - cum[i - 1]
                f = 0 if seg == 0 else (d - cum[i - 1]) / seg
                a, b = pts[i - 1], pts[i]
                return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f]
        return pts[-1]

    def stop_delays(self, trip_id, rt=None):
        """Retard (s) à chaque arrêt de la course. rt["delays"] = {index d'arrêt: retard} donné par
        le temps réel ; les arrêts sans info prennent le retard de l'arrêt connu suivant, sinon du précédent."""
        n = len(self.trips[trip_id]["stops"])
        known = (rt or {}).get("delays", {})
        if not known:
            return [0] * n
        out, nxt = [None] * n, None
        for i in range(n - 1, -1, -1):
            nxt = known.get(i, nxt)
            out[i] = nxt
        prev = None
        for i in range(n):
            prev = known.get(i, prev)
            if out[i] is None:
                out[i] = prev
        return out

    def trip_status(self, trip_id, now_sec, rt=None):
        """État de la course à l'instant now_sec (secondes depuis minuit du jour de service).

        rt (temps réel, optionnel) : {"delays": {index: retard}, "next_index": prochain arrêt non desservi}.
        """
        t = self.trips[trip_id]
        delays = self.stop_delays(trip_id, rt)
        times = [(sid, arr + d, dep + d) for (sid, arr, dep), d in zip(t["stops"], delays)]
        names = [self.stops[sid]["name"] for sid, _, _ in times]
        next_index = (rt or {}).get("next_index")
        # retard « courant » : celui au prochain arrêt du bus
        cur = next_index if next_index is not None and next_index < len(times) else 0
        base = {"trip_id": trip_id, "headsign": t["headsign"], "direction_id": t["direction_id"],
                "delay_sec": delays[cur],
                "stops": [{"id": sid, "name": n, "lat": self.stops[sid]["lat"], "lon": self.stops[sid]["lon"],
                           "time": dep} for (sid, _, dep), n in zip(times, names)],
                "shape": self.shapes.get(t["shape_id"], [])}

        if next_index == 0 or (next_index is None and now_sec < times[0][2]):
            return {**base, "state": "not_started", "starts_in_sec": max(0, times[0][2] - now_sec),
                    "position": [self.stops[times[0][0]]["lat"], self.stops[times[0][0]]["lon"]]}
        if next_index is None and now_sec >= times[-1][1]:
            return {**base, "state": "finished", "last_stop_index": len(times) - 1,
                    "since_sec": now_sec - times[-1][1],
                    "position": [self.stops[times[-1][0]]["lat"], self.stops[times[-1][0]]["lon"]]}

        if next_index is not None:
            # le temps réel dit quel arrêt le bus n'a pas encore atteint
            i = next_index - 1
        else:
            # dernier arrêt dont le départ est passé
            i = max(k for k, (_, _, dep) in enumerate(times) if dep <= now_sec)
        dep_i, arr_next = times[i][2], times[i + 1][1]
        # bornée à [0, 1] : avec le temps réel, les heures estimées peuvent contredire l'arrêt annoncé
        frac = 1.0 if arr_next <= dep_i else max(0.0, min(1.0, (now_sec - dep_i) / (arr_next - dep_i)))
        positions = self._stop_positions(trip_id)
        if positions:
            pos = self._point_at(t["shape_id"], positions[i] + frac * (positions[i + 1] - positions[i]))
        else:
            a, b = self.stops[times[i][0]], self.stops[times[i + 1][0]]
            pos = [a["lat"] + (b["lat"] - a["lat"]) * frac, a["lon"] + (b["lon"] - a["lon"]) * frac]
        return {**base, "state": "running", "last_stop_index": i, "since_sec": max(0, now_sec - dep_i),
                "next_stop_index": i + 1, "next_in_sec": max(0, arr_next - now_sec), "position": pos}


def service_day_and_seconds(now: datetime):
    """Jour de service et secondes écoulées depuis son minuit (les courses après minuit
    sont rattachées au jour précédent, avec des heures > 24:00)."""
    sec = now.hour * 3600 + now.minute * 60 + now.second
    if now.hour < 4:
        return (now - timedelta(days=1)).date(), sec + 86400
    return now.date(), sec
