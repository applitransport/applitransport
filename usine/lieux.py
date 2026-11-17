"""Lieux d'Île-de-France (OpenStreetMap) pour la recherche de l'appli, sans connexion.

Une fois par semaine : télécharge l'extrait Île-de-France de Geofabrik, garde les lieux nommés qui sont des
destinations (commerces, restaurants, santé, culture, loisirs, gares…), fusionne les doublons, et publie :
  out/public/lieux/lieux.db.xz   base SQLite (table lieux + index plein texte FTS5 « recherche »)
  out/public/lieux/lieux.json    date, nombre de lieux, taille et empreinte du fichier

Usage : python usine/lieux.py [--force]   (sans --force : rien à faire si la base a moins de 6 jours)
Données © contributeurs OpenStreetMap, licence ODbL.
"""
import hashlib
import json
import lzma
import math
import sqlite3
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import httpx
import osmium

HERE = Path(__file__).resolve().parent
PBF_URL = "https://download.geofabrik.de/europe/france/ile-de-france-latest.osm.pbf"
PBF = HERE.parent / "data" / "ile-de-france.osm.pbf"
OUT_DIR = HERE / "out" / "public" / "lieux"
WORK_DB = HERE / "out" / "lieux.db"
MAX_AGE_DAYS = 6

# clés retenues et valeurs exclues (mobilier, stationnement… : pas des destinations)
KEYS = ["shop", "amenity", "tourism", "leisure", "office", "healthcare", "craft", "historic", "sport", "railway", "aeroway"]
SKIP = {
    "amenity": {"bench", "parking", "parking_space", "parking_entrance", "bicycle_parking", "waste_basket", "recycling",
                "vending_machine", "telephone", "post_box", "drinking_water", "toilets", "shelter", "atm", "charging_station",
                "motorcycle_parking", "waste_disposal", "fountain", "clock", "hunting_stand", "bbq", "grit_bin", "loading_dock",
                "bicycle_rental", "car_sharing", "taxi", "bus_station", "letter_box", "water_point", "compressed_air"},
    "leisure": {"pitch", "playground", "picnic_table", "swimming_pool", "outdoor_seating", "firepit", "slipway"},
    "shop": {"vacant", "yes"}, "office": {"yes"}, "tourism": {"information", "viewpoint", "artwork", "picnic_site", "apartment"},
    "railway": None, "aeroway": None, "sport": None,
    "historic": {"tomb", "memorial", "wayside_cross", "boundary_stone", "milestone"},
}
# pour railway et aeroway, on ne garde que les gares et aérogares
ONLY = {"railway": {"station"}, "aeroway": {"terminal", "aerodrome"}}

FR = {
    "bakery": "boulangerie", "supermarket": "supermarché", "restaurant": "restaurant", "cafe": "café", "bar": "bar",
    "pharmacy": "pharmacie", "hospital": "hôpital", "clinic": "clinique", "doctors": "médecin", "dentist": "dentiste",
    "school": "école", "college": "lycée", "university": "université", "kindergarten": "maternelle", "library": "bibliothèque",
    "townhall": "mairie", "police": "police", "post_office": "bureau de poste", "bank": "banque", "cinema": "cinéma",
    "theatre": "théâtre", "museum": "musée", "hotel": "hôtel", "park": "parc", "sports_centre": "centre sportif",
    "fast_food": "restauration rapide", "clothes": "vêtements", "hairdresser": "coiffeur", "convenience": "supérette",
    "butcher": "boucherie", "books": "librairie", "place_of_worship": "lieu de culte", "fitness_centre": "salle de sport",
    "stadium": "stade", "marketplace": "marché", "fuel": "station-service", "station": "gare", "terminal": "aérogare",
    "company": "entreprise", "mall": "centre commercial", "department_store": "grand magasin", "garden": "jardin",
    "estate_agent": "agence immobilière", "beauty": "institut de beauté", "optician": "opticien",
    "social_facility": "établissement social", "car_repair": "garage", "community_centre": "salle municipale",
    "climbing": "escalade", "jewelry": "bijouterie", "insurance": "assurance", "government": "administration",
    "florist": "fleuriste", "car": "concession auto", "laundry": "laverie", "shoes": "chaussures",
    "mobile_phone": "téléphonie", "driving_school": "auto-école", "attraction": "attraction", "greengrocer": "primeur",
    "association": "association", "alcohol": "cave", "furniture": "meubles", "gallery": "galerie", "tobacco": "tabac",
    "dry_cleaning": "pressing", "interior_decoration": "décoration", "chocolate": "chocolatier", "gift": "cadeaux",
    "cosmetics": "cosmétiques", "deli": "épicerie fine", "laboratory": "laboratoire", "pub": "pub",
    "travel_agency": "agence de voyages", "massage": "massage", "art": "art", "bicycle": "vélos",
    "hearing_aids": "audioprothésiste", "employment_agency": "agence d'emploi", "pastry": "pâtisserie",
    "newsagent": "presse", "variety_store": "bazar", "arts_centre": "centre culturel", "sports_hall": "gymnase",
    "ticket": "billetterie", "veterinary": "vétérinaire", "castle": "château", "funeral_directors": "pompes funèbres",
    "caterer": "traiteur", "doityourself": "bricolage", "trade": "fournitures pro", "childcare": "crèche",
    "frozen_food": "surgelés", "kitchen": "cuisines", "car_rental": "location de voitures", "wine": "cave à vin",
    "soccer": "football", "sports": "articles de sport", "cheese": "fromagerie", "music_school": "école de musique",
    "tailor": "couturier", "locksmith": "serrurier", "perfumery": "parfumerie", "car_wash": "lavage auto",
    "electronics": "électronique", "computer": "informatique", "nightclub": "discothèque", "ice_cream": "glacier",
    "nursing_home": "maison de retraite", "public_building": "bâtiment public", "toys": "jouets", "pet": "animalerie",
    "hardware": "quincaillerie", "stationery": "papeterie", "seafood": "poissonnerie", "photo": "photo",
    "tennis": "tennis", "swimming": "piscine", "water_park": "centre aquatique", "zoo": "zoo", "theme_park": "parc d'attractions",
    "guest_house": "chambre d'hôtes", "hostel": "auberge de jeunesse", "events_venue": "salle d'événements",
    "conference_centre": "centre de congrès", "exhibition_centre": "parc des expositions", "courthouse": "tribunal",
    "prison": "prison", "fire_station": "pompiers", "embassy": "ambassade", "music": "musique", "coworking": "coworking",
}
IMPORTANT = {"gare", "musée", "hôpital", "mairie", "centre commercial", "grand magasin", "université", "stade",
             "parc", "aérogare", "château", "théâtre", "cinéma", "tribunal", "centre de congrès", "parc des expositions",
             "zoo", "parc d'attractions", "centre aquatique"}


class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.n = 0
        self.rows, self.towns = [], []

    def keep(self, tags):
        name = tags.get("name")
        if not name:
            return None
        for k in KEYS:
            v = tags.get(k)
            if not v:
                continue
            if k in ONLY and v not in ONLY[k]:
                continue
            if v == "yes" or v in (SKIP.get(k) or ()):
                continue
            return name, FR.get(v, v.replace("_", " "))
        return None

    def add(self, o, lat, lon):
        r = self.keep(o.tags)
        if not r:
            return
        name, kind = r
        t = o.tags
        addr = " ".join(x for x in [t.get("addr:housenumber"), t.get("addr:street")] if x)
        brand = t.get("brand") or ""
        poids = (2 if kind in IMPORTANT else 0) + (1 if t.get("wikidata") else 0)
        self.rows.append([name, kind, addr, t.get("addr:city") or "", brand, round(lat, 6), round(lon, 6), poids,
                          1 if addr else 0])
        self.n += 1

    def node(self, n):
        if not n.location.valid():
            return
        # communes (pour la ville des lieux sans adresse)
        if n.tags.get("place") in ("city", "town", "village") and n.tags.get("name"):
            self.towns.append((n.location.lat, n.location.lon, n.tags["name"]))
        self.add(n, n.location.lat, n.location.lon)

    def way(self, w):
        # centre approximatif : moyenne des nœuds
        try:
            pts = [(nd.lat, nd.lon) for nd in w.nodes if nd.location.valid()]
        except osmium.InvalidLocationError:
            return
        if pts:
            self.add(w, sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))



def dist(a, b):
    return math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 111320 * math.cos(math.radians(48.8)))


def build(pbf, db_file):
    h = H()
    h.apply_file(str(pbf), locations=True)

    # ville manquante : commune la plus proche (grille de 0,05°)
    grid = defaultdict(list)
    for la, lo, nm in h.towns:
        grid[(round(la / 0.05), round(lo / 0.05))].append((la, lo, nm))

    def town(la, lo):
        gi, gj = round(la / 0.05), round(lo / 0.05)
        best = None
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for t in grid.get((gi + di, gj + dj), ()):
                    d = dist((la, lo), t)
                    if best is None or d < best[0]:
                        best = (d, t[2])
        return best[1] if best else ""

    # doublons : même nom (sans casse) à moins de 50 m (400 m pour les gares) → celui qui a une adresse
    by_name = defaultdict(list)
    for r in h.rows:
        by_name[r[0].lower()].append(r)
    kept = []
    for rs in by_name.values():
        rs.sort(key=lambda r: (-r[8], r[5], r[6]))
        out = []
        for r in rs:
            radius = 400 if r[1] == "gare" else 50
            if all(dist((r[5], r[6]), (o[5], o[6])) > radius for o in out):
                out.append(r)
        kept += out
    for r in kept:
        if not r[3]:
            r[3] = town(r[5], r[6])
    kept.sort(key=lambda r: (r[0].lower(), r[5], r[6]))  # ordre stable d'une semaine à l'autre

    db_file.unlink(missing_ok=True)
    db = sqlite3.connect(db_file)
    db.executescript("""
    create table lieux(id integer primary key, nom text, type text, adresse text, ville text, marque text,
      lat real, lon real, poids integer);
    """)
    db.executemany("insert into lieux(nom, type, adresse, ville, marque, lat, lon, poids) values (?,?,?,?,?,?,?,?)",
                   [r[:8] for r in kept])
    db.executescript("""
    create virtual table recherche using fts5(nom, type, marque, ville, content='lieux', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    insert into recherche(recherche) values('rebuild');
    """)
    db.commit()
    db.execute("vacuum")
    db.close()
    return len(h.rows), len(kept)


def main():
    force = "--force" in sys.argv
    manifest = OUT_DIR / "lieux.json"
    if not force and manifest.exists() and (OUT_DIR / "lieux.db.xz").exists():
        age = (time.time() - datetime.fromisoformat(json.loads(manifest.read_text())["date"]).timestamp()) / 86400
        if age < MAX_AGE_DAYS:
            print(f"lieux : base de {age:.1f} jour(s), rien à faire")
            return
    t0 = time.time()
    PBF.parent.mkdir(parents=True, exist_ok=True)
    with httpx.stream("GET", PBF_URL, follow_redirects=True, timeout=600) as r:
        r.raise_for_status()
        with open(PBF, "wb") as f:
            for chunk in r.iter_bytes(1 << 20):
                f.write(chunk)
    total, kept = build(PBF, WORK_DB)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    data = lzma.compress(WORK_DB.read_bytes(), preset=9)
    (OUT_DIR / "lieux.db.xz").write_bytes(data)
    manifest.write_text(json.dumps({
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "lieux": kept,
        "taille": len(data),
        "taille_base": WORK_DB.stat().st_size,
        "sha256": hashlib.sha256(data).hexdigest(),
        "source": "© contributeurs OpenStreetMap (ODbL), extrait Geofabrik",
    }, ensure_ascii=False, indent=1))
    PBF.unlink(missing_ok=True)  # 300 Mo : retéléchargé la semaine suivante
    print(f"lieux : {kept} lieux ({total} avant doublons), {len(data) / 1e6:.1f} Mo, {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
