"""Vérifie la couverture temps réel PRIM des lignes 5104/5105 et la présence du GPS.

Usage : .venv/bin/python scripts/check_realtime.py
"""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import realtime  # noqa: E402
from app.gtfs import Gtfs  # noqa: E402


async def main():
    if not realtime.api_key():
        sys.exit("Pas de clé PRIM (.prim_key ou PRIM_API_KEY)")
    gtfs = Gtfs()
    sample = None
    for line in gtfs.lines():
        for d in line["directions"]:
            trip = max((t for t in gtfs.trips.values()
                        if t["route_id"] == line["route_id"] and t["direction_id"] == d["direction_id"]),
                       key=lambda t: len(t["stops"]))
            # 3 arrêts répartis sur le parcours, pour limiter le nombre de requêtes
            ids = [s[0] for s in trip["stops"]]
            for sid in (ids[1], ids[len(ids) // 2], ids[-2]):
                data = await realtime.stop_monitoring_raw(sid)
                visits = data["Siri"]["ServiceDelivery"]["StopMonitoringDelivery"][0].get("MonitoredStopVisit", [])
                mine = [v for v in visits
                        if line["route_id"].split(":")[-1] in v["MonitoredVehicleJourney"].get("LineRef", {}).get("value", "")]
                gps = sum("VehicleLocation" in v["MonitoredVehicleJourney"] for v in mine)
                print(f"{line['name']} → {d['label']:<25} {gtfs.stops[sid]['name']:<30} "
                      f"{len(mine):>2} passage(s), {gps} avec GPS")
                if mine and sample is None:
                    sample = mine[0]
    if sample:
        out = Path(__file__).resolve().parent.parent / "data" / "sample_realtime.json"
        out.write_text(json.dumps(sample, ensure_ascii=False, indent=1))
        print(f"\nExemple de passage enregistré dans {out}")
    else:
        print("\nAucun passage temps réel trouvé (hors service, ou lignes non couvertes).")


asyncio.run(main())
