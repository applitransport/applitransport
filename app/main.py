"""Serveur du POC SQYBUS : python -m uvicorn app.main:app --reload"""
from datetime import date, datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import realtime
from .gtfs import Gtfs, service_day_and_seconds

TZ = ZoneInfo("Europe/Paris")
WEB = Path(__file__).resolve().parent.parent / "web"

gtfs = Gtfs()
app = FastAPI(title="POC SQYBUS")


def resolve_now(day: str | None, at: str | None):
    """Instant de référence : maintenant, ou un jour/heure simulés (utile pour tester la nuit)."""
    now = datetime.now(TZ)
    if day or at:
        d = date.fromisoformat(day) if day else now.date()
        t = time.fromisoformat(at) if at else now.time()
        now = datetime.combine(d, t, tzinfo=TZ)
    return now


def midnight_of(service_day: date):
    return datetime.combine(service_day, time(0), tzinfo=TZ)


def realtime_enabled(day, at, rt):
    """PRIM n'est appelé que si l'utilisateur l'a autorisé (rt) et hors simulation."""
    return rt and bool(realtime.api_key()) and not (day or at)


STALE_SEC = 15 * 60


async def line_realtime(route_id):
    """Temps réel de la ligne par course GTFS : {trip_id: {"delays": {index: retard}, "next_index"}}.

    Une seule requête PRIM « ligne » (mise en cache) couvre tous les bus de la ligne.
    """
    now = datetime.now(TZ)
    out = {}
    for number, journey in (await realtime.line_journeys(route_id)).items():
        trip_id = gtfs.trip_by_number.get(number)
        if not trip_id:
            continue
        calls = journey["calls"]
        # course censée rouler mais sans nouvelles depuis longtemps : donnée périmée (bus fantôme),
        # on retombe sur l'horaire théorique. Une course à venir peut garder une vieille prévision.
        service_day, now_sec = service_day_and_seconds(now)
        started = gtfs.trips[trip_id]["stops"][0][2] < now_sec
        recorded = journey["recorded_at"]
        if started and recorded and (now - recorded).total_seconds() > STALE_SEC:
            continue
        index_of = {sid: k for k, (sid, _, _) in enumerate(gtfs.trips[trip_id]["stops"])}
        delays = {}
        for c in calls:
            k = index_of.get(c["stop_id"])
            if k is not None:
                delays[k] = int((c["expected"] - c["aimed"]).total_seconds())
        if delays:
            # PRIM ne liste que les arrêts restants : le premier est le prochain arrêt du bus
            out[trip_id] = {"delays": delays, "next_index": min(delays)}
    return out


async def safe_line_realtime(route_id, enabled):
    """(temps réel, erreur) — le POC doit rester utilisable si PRIM ne répond pas."""
    if not enabled:
        return {}, None
    try:
        return await line_realtime(route_id), None
    except Exception as e:
        return {}, str(e)


@app.get("/api/lines")
def lines():
    return {"lines": gtfs.lines(), "realtime": bool(realtime.api_key())}


@app.get("/api/prim-usage")
def prim_usage():
    return {"counts": realtime.usage(), "cache_ttl_sec": realtime.CACHE_TTL, "daily_limit": realtime.DAILY_LIMIT}


@app.get("/api/geometry")
def geometry(route_id: str, direction_id: int):
    return gtfs.line_geometry(route_id, direction_id)


@app.get("/api/departures")
async def departures(route_id: str, direction_id: int, stop_key: str, day: str | None = None, at: str | None = None,
                     rt: bool = False):
    service_day, now_sec = service_day_and_seconds(resolve_now(day, at))
    deps = gtfs.departures(route_id, direction_id, stop_key, service_day)
    rtmap, rt_error = await safe_line_realtime(route_id, realtime_enabled(day, at, rt))
    for d in deps:
        info = rtmap.get(d["trip_id"])
        if not info:
            continue
        if d["stop_index"] < info["next_index"]:
            d["passed"] = True  # le bus a déjà desservi cet arrêt
        else:
            d["delay_sec"] = gtfs.stop_delays(d["trip_id"], info)[d["stop_index"]]
            d["expected"] = d["time"] + d["delay_sec"]
    return {"service_day": service_day.isoformat(), "now_sec": now_sec,
            "departures": deps, "realtime_error": rt_error}


@app.get("/api/trip/{trip_id:path}")
async def trip(trip_id: str, service_day: str, day: str | None = None, at: str | None = None, rt: bool = False):
    if trip_id not in gtfs.trips:
        raise HTTPException(404, "course inconnue")
    now = resolve_now(day, at)
    now_sec = int((now - midnight_of(date.fromisoformat(service_day))).total_seconds())
    route_id = gtfs.trips[trip_id]["route_id"]
    enabled = realtime_enabled(day, at, rt)
    rtmap, rt_error = await safe_line_realtime(route_id, enabled)
    info = rtmap.get(trip_id)

    status = gtfs.trip_status(trip_id, now_sec, info)
    status["source"] = "temps_reel" if info else "theorique"
    status["now_sec"] = now_sec
    if enabled and not info and not rt_error:
        status["realtime_note"] = "course absente du temps réel (pas encore partie, terminée ou non suivie)"
    if info:
        status["realtime_age_sec"] = realtime.cache_age("ligne", route_id)
    if rt_error:
        status["realtime_error"] = rt_error
    return status


@app.get("/api/vehicles")
async def vehicles(route_id: str, day: str | None = None, at: str | None = None, rt: bool = False):
    """Tous les bus en circulation sur la ligne (les deux sens), en version allégée."""
    service_day, now_sec = service_day_and_seconds(resolve_now(day, at))
    rtmap, rt_error = await safe_line_realtime(route_id, realtime_enabled(day, at, rt))
    out = []
    for trip_id in gtfs.active_trips(route_id, service_day):
        info = rtmap.get(trip_id)
        s = gtfs.trip_status(trip_id, now_sec, info)
        if s["state"] != "running":
            continue
        out.append({
            "trip_id": trip_id, "direction_id": s["direction_id"], "headsign": s["headsign"],
            "source": "temps_reel" if info else "theorique", "delay_sec": s["delay_sec"],
            "position": s["position"], "last_stop": s["stops"][s["last_stop_index"]]["name"],
            "since_sec": s["since_sec"], "next_stop": s["stops"][s["next_stop_index"]]["name"],
            "next_in_sec": s["next_in_sec"], "first_time": s["stops"][0]["time"] - s["delay_sec"],
        })
    return {"service_day": service_day.isoformat(), "now_sec": now_sec, "vehicles": out,
            "realtime_error": rt_error}


@app.get("/api/realtime/raw")
async def realtime_raw(stop_id: str):
    """Réponse brute de PRIM (requête unitaire) pour un arrêt — diagnostic."""
    if not realtime.api_key():
        raise HTTPException(400, "PRIM_API_KEY non définie")
    return await realtime.stop_monitoring_raw(stop_id)


@app.get("/")
def index():
    return FileResponse(WEB / "index.html")


app.mount("/static", StaticFiles(directory=WEB), name="static")
