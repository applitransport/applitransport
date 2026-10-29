"""Surveillance PRIM : relève régulièrement le temps réel (requête « ligne ») et l'Info Trafic de
quelques lignes, et garde tout ce qui sort de l'ordinaire, pour corriger l'appli plus tard
(trains supprimés, statuts inhabituels, gros retards, bus fantômes, perturbations).

Usage : python scripts/surveillance.py [--hours 24] [--every 15]
Résultats dans data/surveillance/<date de lancement>/ :
  resume.csv          une ligne par relevé et par ligne surveillée
  anomalies.jsonl     courses inhabituelles, avec leur contenu SIRI complet
  perturbations.jsonl perturbations Info Trafic (une seule fois chacune)
  brut/               réponses SIRI complètes des relevés qui contiennent une anomalie
"""
import argparse
import csv
import gzip
import json
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent.parent
KEY_FILE = ROOT / ".prim_key"  # relu à chaque requête : un jeton régénéré est pris en compte sans redémarrer
BASE = "https://prim.iledefrance-mobilites.fr/marketplace"
LINES = {"C01736": "Transilien N", "C01527": "Bus 5104"}
NORMAL_STATUSES = {"ON_TIME", "ONTIME", "ARRIVED", ""}
BIG_DELAY_SEC = 5 * 60
STALE_SEC = 15 * 60
MAX_REQUESTS = {"ligne": 300, "trafic": 300}  # garde-fou, bien sous les quotas (1000 / 4000)


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None


class Monitor:
    def __init__(self, out_dir):
        self.out = out_dir
        (out_dir / "brut").mkdir(parents=True, exist_ok=True)
        self.client = httpx.Client(timeout=30, headers={"Accept": "application/json"})
        self.requests = Counter()
        self.seen_disruptions = set()
        new = not (out_dir / "resume.csv").exists()
        self.summary = (out_dir / "resume.csv").open("a", newline="")
        self.csv = csv.writer(self.summary)
        if new:
            self.csv.writerow(["heure", "ligne", "courses", "supprimees", "statuts_inhabituels",
                               "retard_5min_ou_plus", "retard_max_s", "fantomes", "statuts"])

    def get(self, kind, path, params=None):
        if self.requests[kind] >= MAX_REQUESTS[kind]:
            raise RuntimeError(f"garde-fou : {MAX_REQUESTS[kind]} requêtes « {kind} » atteintes")
        self.requests[kind] += 1
        r = self.client.get(f"{BASE}/{path}", params=params, headers={"apikey": KEY_FILE.read_text().strip()})
        r.raise_for_status()
        return r.json()

    def append(self, name, obj):
        with (self.out / name).open("a") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")

    def check_line(self, code, now):
        data = self.get("ligne", "estimated-timetable", {"LineRef": f"STIF:Line::{code}:"})
        journeys = [j for d in data["Siri"]["ServiceDelivery"].get("EstimatedTimetableDelivery", [])
                    for f in d.get("EstimatedJourneyVersionFrame", []) for j in f.get("EstimatedVehicleJourney", [])]
        statuses, anomalies = Counter(), []
        cancelled = unusual = delayed = ghosts = 0
        max_delay = 0
        for j in journeys:
            calls = j.get("EstimatedCalls", {}).get("EstimatedCall", [])
            reasons = []
            if j.get("Cancellation"):
                cancelled += 1
                reasons.append("course supprimée")
            odd = set()
            for c in calls:
                for k in ("ArrivalStatus", "DepartureStatus"):
                    s = (c.get(k) or "").upper()
                    statuses[s or "-"] += 1
                    if s not in NORMAL_STATUSES:
                        odd.add(s)
                aimed = parse(c.get("AimedDepartureTime") or c.get("AimedArrivalTime"))
                expected = parse(c.get("ExpectedDepartureTime") or c.get("ExpectedArrivalTime"))
                if aimed and expected:
                    max_delay = max(max_delay, int((expected - aimed).total_seconds()))
            if odd:
                unusual += 1
                reasons.append("statuts " + ",".join(sorted(odd)))
            delays = [int((parse(c.get("ExpectedDepartureTime") or c.get("ExpectedArrivalTime"))
                           - parse(c.get("AimedDepartureTime") or c.get("AimedArrivalTime"))).total_seconds())
                      for c in calls if (c.get("ExpectedDepartureTime") or c.get("ExpectedArrivalTime"))
                      and (c.get("AimedDepartureTime") or c.get("AimedArrivalTime"))]
            if delays and max(abs(x) for x in delays) >= BIG_DELAY_SEC:
                delayed += 1
                reasons.append(f"retard {max(delays, key=abs) // 60} min")
            recorded = parse(j.get("RecordedAtTime"))
            if recorded and (now - recorded).total_seconds() > STALE_SEC and delays and \
                    min(parse(c.get("AimedDepartureTime") or c.get("AimedArrivalTime"))
                        for c in calls if c.get("AimedDepartureTime") or c.get("AimedArrivalTime")) < now:
                ghosts += 1
                reasons.append(f"pas de mise à jour depuis {int((now - recorded).total_seconds() // 60)} min")
            if reasons:
                anomalies.append({"heure": now.isoformat(timespec="seconds"), "ligne": code,
                                  "raisons": reasons, "course": j})
        for a in anomalies:
            self.append("anomalies.jsonl", a)
        if anomalies:
            stamp = now.strftime("%H%M")
            (self.out / "brut" / f"{code}_{stamp}.json.gz").write_bytes(gzip.compress(json.dumps(data).encode()))
        self.csv.writerow([now.astimezone().strftime("%Y-%m-%d %H:%M"), LINES[code], len(journeys), cancelled,
                           unusual, delayed, max_delay, ghosts, " ".join(f"{k}:{v}" for k, v in statuses.items())])
        self.summary.flush()
        return len(journeys), len(anomalies)

    def check_traffic(self, code, now):
        data = self.get("trafic", f"v2/navitia/lines/line:IDFM:{code}/line_reports")
        new = 0
        for d in data.get("disruptions", []):
            if d["id"] in self.seen_disruptions:
                continue
            self.seen_disruptions.add(d["id"])
            new += 1
            self.append("perturbations.jsonl", {
                "vue_a": now.isoformat(timespec="seconds"), "ligne": code, "id": d["id"],
                "statut": d.get("status"), "effet": d.get("severity", {}).get("effect"),
                "cause": d.get("cause"), "periodes": d.get("application_periods"),
                "textes": [m.get("text") for m in d.get("messages", [])],
                "objets": [o.get("pt_object", {}).get("embedded_type") for o in d.get("impacted_objects", [])],
                "brut": d,
            })
        return len(data.get("disruptions", [])), new

    def cycle(self):
        now = datetime.now(timezone.utc)
        parts = []
        for code, name in LINES.items():
            try:
                n, a = self.check_line(code, now)
                t, new = self.check_traffic(code, now)
                parts.append(f"{name}: {n} courses, {a} anomalie(s), {t} perturbation(s) dont {new} nouvelle(s)")
            except Exception as e:  # on continue au relevé suivant
                parts.append(f"{name}: ERREUR {e}")
        print(f"{now.astimezone():%H:%M} | " + " | ".join(parts)
              + f" | requêtes ligne={self.requests['ligne']} trafic={self.requests['trafic']}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--every", type=float, default=15, help="minutes entre deux relevés")
    args = ap.parse_args()
    start = datetime.now()
    out = ROOT / "data" / "surveillance" / start.strftime("%Y-%m-%d_%Hh%M")
    m = Monitor(out)
    end = start + timedelta(hours=args.hours)
    print(f"Surveillance de {', '.join(LINES.values())} toutes les {args.every:g} min jusqu'à {end:%d/%m %H:%M} → {out}",
          flush=True)
    while datetime.now() < end:
        m.cycle()
        time.sleep(args.every * 60)
    print("Surveillance terminée", flush=True)


if __name__ == "__main__":
    main()
