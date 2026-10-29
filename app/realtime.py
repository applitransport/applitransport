"""Temps réel via les API PRIM d'Île-de-France Mobilités (SIRI Lite).

- « requête ligne » (estimated-timetable) : pour chaque bus en circulation sur la ligne, ses
  arrêts restant à desservir avec l'heure estimée. C'est la source utilisée par l'appli.
- « requête unitaire » (stop-monitoring) : prochains passages à un arrêt, gardée pour le diagnostic.

Clé lue dans la variable d'environnement PRIM_API_KEY, sinon dans le fichier .prim_key
à la racine du projet. Sans clé, l'appli reste en mode théorique.

Chaque ressource n'est interrogée qu'une fois par CACHE_TTL secondes, et chaque API au plus
DAILY_LIMIT fois par jour (quota PRIM : 1000/jour par API).
"""
import json
import os
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

BASE_URL = "https://prim.iledefrance-mobilites.fr/marketplace"
ROOT = Path(__file__).resolve().parent.parent
KEY_FILE = ROOT / ".prim_key"
USAGE_FILE = ROOT / "data" / "prim_usage.json"
TZ = ZoneInfo("Europe/Paris")
CACHE_TTL = 60
DAILY_LIMIT = 900  # marge sous le quota de 1000, qui compte aussi les appels faits hors de l'appli
APIS = ("ligne", "unitaire")

_cache = {}  # (api, identifiant) -> (instant, réponse)


class QuotaExceeded(Exception):
    pass


def api_key():
    if os.environ.get("PRIM_API_KEY"):
        return os.environ["PRIM_API_KEY"]
    if KEY_FILE.exists():
        return KEY_FILE.read_text().strip() or None
    return None


# --- compteur d'appels, conservé entre redémarrages ---------------------------
def _load_usage():
    try:
        u = json.loads(USAGE_FILE.read_text())
    except (OSError, ValueError):
        u = {}
    return {"day": u.get("day"), "counts": u.get("counts") or {"unitaire": u.get("count", 0)}}


calls = _load_usage()


def usage():
    today = datetime.now(TZ).date().isoformat()
    counts = calls["counts"] if calls["day"] == today else {}
    return {api: counts.get(api, 0) for api in APIS}


def _count_call(api):
    today = datetime.now(TZ).date().isoformat()
    if calls["day"] != today:
        calls.update(day=today, counts={})
    if calls["counts"].get(api, 0) >= DAILY_LIMIT:
        raise QuotaExceeded(f"limite de {DAILY_LIMIT} appels PRIM « {api} » atteinte aujourd'hui")
    calls["counts"][api] = calls["counts"].get(api, 0) + 1
    USAGE_FILE.write_text(json.dumps(calls))


async def _get(api, path, params, cache_key):
    cached = _cache.get((api, cache_key))
    if cached and time.monotonic() - cached[0] < CACHE_TTL:
        return cached[1]
    _count_call(api)
    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.get(f"{BASE_URL}/{path}", params=params,
                             headers={"apikey": api_key(), "Accept": "application/json"})
        r.raise_for_status()
        data = r.json()
    _cache[(api, cache_key)] = (time.monotonic(), data)
    return data


def cache_age(api, cache_key):
    cached = _cache.get((api, cache_key))
    return int(time.monotonic() - cached[0]) if cached else None


def _parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(TZ) if ts else None


def _journey_number(ref):
    # "529FSQY:VehicleJourney::8747417:LOC" -> "8747417"
    parts = [p for p in ref.split(":") if p]
    return parts[-2] if len(parts) >= 2 else ref


def _gtfs_stop_id(ref):
    # "STIF:StopPoint:Q:20612:" -> "IDFM:20612" ; les références propres à l'exploitant sont ignorées
    if not ref.startswith("STIF:StopPoint:Q:"):
        return None
    return "IDFM:" + ref.split(":")[3]


# --- requête ligne -------------------------------------------------------------
def line_ref(route_id):
    # IDFM:C01527 -> STIF:Line::C01527:
    return f"STIF:Line::{route_id.split(':')[-1]}:"


async def line_journeys(route_id):
    """Courses de la ligne connues du temps réel :
    {numéro de course: {"recorded_at": dernière mise à jour,
                        "calls": [{"stop_id", "aimed", "expected"}, ...] (arrêts restants, dans le désordre)}}."""
    data = await _get("ligne", "estimated-timetable", {"LineRef": line_ref(route_id)}, route_id)
    out = {}
    for delivery in data["Siri"]["ServiceDelivery"].get("EstimatedTimetableDelivery", []):
        for frame in delivery.get("EstimatedJourneyVersionFrame", []):
            for j in frame.get("EstimatedVehicleJourney", []):
                number = _journey_number(j.get("DatedVehicleJourneyRef", {}).get("value", ""))
                calls_ = []
                for c in j.get("EstimatedCalls", {}).get("EstimatedCall", []):
                    aimed = _parse(c.get("AimedDepartureTime") or c.get("AimedArrivalTime"))
                    expected = _parse(c.get("ExpectedDepartureTime") or c.get("ExpectedArrivalTime"))
                    if aimed and expected:
                        calls_.append({"stop_id": _gtfs_stop_id(c.get("StopPointRef", {}).get("value", "")),
                                       "aimed": aimed, "expected": expected})
                out[number] = {"recorded_at": _parse(j.get("RecordedAtTime")), "calls": calls_}
    return out


# --- requête unitaire (diagnostic) ------------------------------------------------
def monitoring_ref(gtfs_stop_id):
    # IDFM:20612 -> STIF:StopPoint:Q:20612:
    return f"STIF:StopPoint:Q:{gtfs_stop_id.split(':')[-1]}:"


async def stop_monitoring_raw(gtfs_stop_id):
    return await _get("unitaire", "stop-monitoring", {"MonitoringRef": monitoring_ref(gtfs_stop_id)}, gtfs_stop_id)
