"""État en mémoire du serveur communautaire d'AppliTransport.

Positions « je suis dedans » et signalements des voyageurs, agrégés par ligne. Rien n'est écrit sur
disque : tout disparaît au redémarrage et chaque donnée est effacée après sa durée de vie.

Vie privée (note de conception, « Identifiants, vie privée et RGPD ») :
- une position n'est liée qu'à son identifiant de session, tiré au hasard par l'appli pour un trajet ;
- l'empreinte du jour (en-tête X-Empreinte) ne sert qu'aux limites de débit et au comptage des
  sources d'un signalement, sous forme salée ; elle n'est jamais rangée avec les positions ;
- l'adresse IP ne sert qu'à une limite de débit, sous forme salée, en mémoire ;
- le sel change chaque jour (UTC) et les compteurs de débit sont alors vidés.
"""

from __future__ import annotations

import hashlib
import hmac
import math
import os
import secrets
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Callable

# Durée de vie d'un signalement après le dernier reçu, par type (s).
DUREES = {"retard": 20 * 60, "incident": 30 * 60, "supprime": 30 * 60, "affluence": 10 * 60}

# Valeurs admises pour « detail », par type.
DETAILS = {
    "retard": {"retard", "pas_passe", "bloque"},
    "incident": {
        "panne",
        "accident",
        "deviation",
        "agression",
        "malaise",
        "trafic_interrompu",
        "colis_suspect",
    },
    "supprime": {"supprime"},
    "affluence": {"assis", "debout", "plein"},
}

CONSERVATION_POSITIONS = 10 * 60  # une position est effacée 10 min après sa réception
VU_RECENT = 120  # une session compte comme source d'un véhicule si son dernier point a moins de 2 min
CACHE_LIGNE = 10  # réponse « état d'une ligne » réutilisée pendant 10 s
INTERVALLE_POSITION = 20  # au plus une position toutes les 20 s par empreinte
SIGNALEMENTS_PAR_HEURE = 10
# en 4G, de nombreux abonnés partagent une même adresse : relevée sur le VPS (COMMUNAUTE_IP_PAR_MINUTE)
REQUETES_IP_PAR_MINUTE = int(os.environ.get("COMMUNAUTE_IP_PAR_MINUTE", "60"))
VITESSE_MAX_KMH = 240  # saut de plus de 2 km en 30 s entre deux points d'une session : rejeté
ECART_DISCORDANT = 1000  # deux voyageurs à plus de 1 km pour la même course : non concordant (m)
MAX_SESSIONS = 50_000
MAX_SIGNALEMENTS = 50_000


class Refus(Exception):
    """Requête refusée : code (debit, plein, invalide) et statut HTTP."""

    STATUTS = {"debit": 429, "plein": 503, "invalide": 422}

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.statut = self.STATUTS[code]


@dataclass
class Position:
    session: str
    ligne: str
    course: str
    sens: int
    arret_prec: str
    arret_suiv: str
    progression: float
    lat: float
    lon: float
    vitesse_kmh: float | None
    recu: float


@dataclass
class Signalement:
    id: str
    ligne: str
    type: str
    detail: str
    course: str | None
    arret: str | None
    premier: float
    dernier: float
    sources: set[str] = field(default_factory=set)  # empreintes salées, pour compter sans doublon

    @property
    def expire(self) -> float:
        return self.dernier + DUREES[self.type]


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    lat = math.radians((lat1 + lat2) / 2)
    dx = math.radians(lon2 - lon1) * math.cos(lat)
    dy = math.radians(lat2 - lat1)
    return 6_371_000 * math.hypot(dx, dy)


class Etat:
    def __init__(self, horloge: Callable[[], float] = time.time):
        self.horloge = horloge
        self._jour = None
        self._sel = b""
        self.positions: dict[str, dict[str, Position]] = defaultdict(dict)  # ligne → session → dernier point
        self._ligne_de: dict[str, str] = {}  # session → ligne
        self.signalements: dict[tuple, Signalement] = {}
        self._cache: dict[str, tuple[float, dict]] = {}
        self.compteurs: dict[str, int] = defaultdict(int)  # anonymes, du jour : positions, retard, incident…
        self._nouveau_jour()

    # --- jour, sel et limites de débit -----------------------------------------------------------

    def _nouveau_jour(self) -> None:
        self._jour = time.strftime("%Y-%m-%d", time.gmtime(self.horloge()))
        self._sel = secrets.token_bytes(32)
        self._derniere_position: dict[str, float] = {}  # empreinte salée → heure
        self._session_de: dict[str, str] = {}  # empreinte salée → session en cours
        self._signalements_de: dict[str, deque] = defaultdict(deque)
        self._requetes_ip: dict[str, deque] = defaultdict(deque)
        self.compteurs = defaultdict(int)

    def _sale(self, valeur: str) -> str:
        return hmac.new(self._sel, valeur.encode(), hashlib.sha256).hexdigest()[:32]

    def _verifier_jour(self) -> None:
        if time.strftime("%Y-%m-%d", time.gmtime(self.horloge())) != self._jour:
            self._nouveau_jour()

    def _limite_ip(self, ip: str, maintenant: float) -> None:
        q = self._requetes_ip[self._sale("ip:" + ip)]
        while q and q[0] <= maintenant - 60:
            q.popleft()
        if len(q) >= REQUETES_IP_PAR_MINUTE:
            raise Refus("debit", "trop de requêtes depuis cette adresse")
        q.append(maintenant)

    # --- purge ---------------------------------------------------------------------------------

    def purger(self) -> None:
        maintenant = self.horloge()
        for ligne in list(self.positions):
            sessions = self.positions[ligne]
            for s in [s for s, p in sessions.items() if p.recu <= maintenant - CONSERVATION_POSITIONS]:
                del sessions[s]
                self._ligne_de.pop(s, None)
            if not sessions:
                del self.positions[ligne]
        for k in [k for k, sig in self.signalements.items() if sig.expire <= maintenant]:
            del self.signalements[k]
        for ligne in [l for l, (t, _) in self._cache.items() if t <= maintenant - CACHE_LIGNE]:
            del self._cache[ligne]

    def _oublier_session(self, session: str) -> None:
        ligne = self._ligne_de.pop(session, None)
        if ligne is not None:
            self.positions.get(ligne, {}).pop(session, None)

    # --- écritures -------------------------------------------------------------------------------

    def position(self, empreinte: str, ip: str, d: dict) -> None:
        """Enregistre le dernier point d'une session. d : champs du message validés par l'API."""
        self._verifier_jour()
        self.purger()
        maintenant = self.horloge()
        self._limite_ip(ip, maintenant)
        emp = self._sale("emp:" + empreinte)
        avant = self._derniere_position.get(emp)
        if avant is not None and maintenant - avant < INTERVALLE_POSITION:
            raise Refus("debit", f"au plus une position toutes les {INTERVALLE_POSITION} s")
        session = d["session"]
        # un seul trajet à la fois : une nouvelle session remplace la précédente
        ancienne = self._session_de.get(emp)
        if ancienne is not None and ancienne != session:
            self._oublier_session(ancienne)
        prec = self.positions.get(self._ligne_de.get(session, ""), {}).get(session)
        if prec is not None:
            if prec.ligne != d["ligne"] or prec.course != d["course"]:
                raise Refus("invalide", "une session suit une seule course")
            dt = max(maintenant - prec.recu, 1)
            if distance_m(prec.lat, prec.lon, d["lat"], d["lon"]) / dt * 3.6 > VITESSE_MAX_KMH:
                raise Refus("invalide", "déplacement impossible depuis le point précédent")
        elif len(self._ligne_de) >= MAX_SESSIONS:
            raise Refus("plein", "serveur plein, réessayez plus tard")
        self.positions[d["ligne"]][session] = Position(
            session=session,
            ligne=d["ligne"],
            course=d["course"],
            sens=d["sens"],
            arret_prec=d["arret_prec"],
            arret_suiv=d["arret_suiv"],
            progression=d["progression"],
            lat=round(d["lat"], 4),  # environ 10 m
            lon=round(d["lon"], 4),
            vitesse_kmh=None if d.get("vitesse_kmh") is None else round(d["vitesse_kmh"]),
            recu=maintenant,
        )
        self._ligne_de[session] = d["ligne"]
        self._session_de[emp] = session
        self._derniere_position[emp] = maintenant
        self._cache.pop(d["ligne"], None)
        self.compteurs["positions"] += 1

    def signalement(self, empreinte: str, ip: str, d: dict) -> str:
        """Ajoute un signalement ou une source à un signalement identique en cours ; renvoie son id."""
        self._verifier_jour()
        self.purger()
        maintenant = self.horloge()
        self._limite_ip(ip, maintenant)
        if d["detail"] not in DETAILS[d["type"]]:
            raise Refus("invalide", f"détail inconnu pour {d['type']}")
        emp = self._sale("emp:" + empreinte)
        q = self._signalements_de[emp]
        while q and q[0] <= maintenant - 3600:
            q.popleft()
        if len(q) >= SIGNALEMENTS_PAR_HEURE:
            raise Refus("debit", f"au plus {SIGNALEMENTS_PAR_HEURE} signalements par heure")
        # l'affluence n'a qu'une valeur à la fois (la dernière) ; les autres détails sont distincts
        cle = (d["ligne"], d["type"], d.get("course"), d.get("arret"), None if d["type"] == "affluence" else d["detail"])
        sig = self.signalements.get(cle)
        if sig is None:
            if len(self.signalements) >= MAX_SIGNALEMENTS:
                raise Refus("plein", "serveur plein, réessayez plus tard")
            sig = Signalement(
                id="s-" + secrets.token_hex(4),
                ligne=d["ligne"],
                type=d["type"],
                detail=d["detail"],
                course=d.get("course"),
                arret=d.get("arret"),
                premier=maintenant,
                dernier=maintenant,
            )
            self.signalements[cle] = sig
        sig.detail = d["detail"]
        sig.dernier = maintenant
        sig.sources.add(emp)
        q.append(maintenant)
        self._cache.pop(d["ligne"], None)
        self.compteurs[d["type"]] += 1
        return sig.id

    # --- lecture ---------------------------------------------------------------------------------

    def ligne(self, ligne: str, ip: str) -> dict:
        """État d'une ligne : véhicules vus par des voyageurs et signalements en cours (agrégats)."""
        self._verifier_jour()
        self.purger()
        maintenant = self.horloge()
        self._limite_ip(ip, maintenant)
        en_cache = self._cache.get(ligne)
        if en_cache is not None:
            return en_cache[1]
        par_course: dict[str, list[Position]] = defaultdict(list)
        for p in self.positions.get(ligne, {}).values():
            par_course[p.course].append(p)
        vehicules = []
        for course, points in par_course.items():
            points.sort(key=lambda p: p.recu, reverse=True)
            dernier = points[0]
            recents = [p for p in points if p.recu > maintenant - VU_RECENT]
            concordant = all(
                distance_m(a.lat, a.lon, b.lat, b.lon) <= ECART_DISCORDANT
                for i, a in enumerate(recents)
                for b in recents[i + 1 :]
            )
            vehicules.append(
                {
                    "course": course,
                    "sens": dernier.sens,
                    "arret_prec": dernier.arret_prec,
                    "arret_suiv": dernier.arret_suiv,
                    "progression": dernier.progression,
                    "lat": dernier.lat,
                    "lon": dernier.lon,
                    "vitesse_kmh": dernier.vitesse_kmh,
                    "sources": len(recents),
                    "concordant": concordant,
                    "vu_il_y_a_s": int(maintenant - dernier.recu),
                }
            )
        signalements = [
            {
                "id": s.id,
                "type": s.type,
                "detail": s.detail,
                "course": s.course,
                "arret": s.arret,
                "sources": len(s.sources),
                "premier": int(s.premier),
                "dernier": int(s.dernier),
            }
            for s in self.signalements.values()
            if s.ligne == ligne
        ]
        reponse = {"t": int(maintenant), "vehicules": vehicules, "signalements": signalements}
        self._cache[ligne] = (maintenant, reponse)
        return reponse
