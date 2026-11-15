"""Serveur communautaire d'AppliTransport : relais des positions et signalements des voyageurs.

Trois routes (formats de la note de conception « Signalements communautaires ») :
  POST /v1/positions        dernier point d'un trajet « je suis dedans »
  POST /v1/signalements     retard, incident, supprimé, affluence
  GET  /v1/lignes/{ligne}   agrégats d'une ligne
et GET /sante pour la surveillance.

Lancement (journal d'accès désactivé : aucune adresse IP écrite) :
  uvicorn communaute.serveur:app --host 0.0.0.0 --port 8765 --no-access-log
Derrière un relais (Caddy), COMMUNAUTE_RELAIS=1 fait lire l'adresse dans X-Forwarded-For.
"""

from __future__ import annotations

import os
from typing import Literal

from fastapi import FastAPI, Header, Path, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

try:  # lancé comme paquet (uvicorn communaute.serveur:app) ou depuis le dossier (uvicorn serveur:app)
    from .etat import Etat, Refus
except ImportError:
    from etat import Etat, Refus

IDENT = r"^[A-Za-z0-9:_.\-]{1,64}$"
SESSION = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
EMPREINTE = r"^[0-9a-f]{64}$"


class Message(BaseModel):
    model_config = ConfigDict(extra="forbid")
    v: Literal[1]
    session: str = Field(pattern=SESSION)
    ligne: str = Field(pattern=IDENT)
    t: int  # heure du téléphone (s UTC) : indicative, le serveur date avec sa propre horloge


class PositionIn(Message):
    course: str = Field(pattern=IDENT)
    sens: int = Field(ge=0, le=9)
    arret_prec: str = Field(pattern=IDENT)
    arret_suiv: str = Field(pattern=IDENT)
    progression: float = Field(ge=0, le=1)
    lat: float = Field(ge=48.0, le=49.5)  # Île-de-France élargie
    lon: float = Field(ge=1.3, le=3.7)
    vitesse_kmh: float | None = Field(default=None, ge=0, le=250)


class SignalementIn(Message):
    type: Literal["retard", "incident", "supprime", "affluence"]
    detail: str = Field(pattern=r"^[a-z_]{1,20}$")
    course: str | None = Field(default=None, pattern=IDENT)
    arret: str | None = Field(default=None, pattern=IDENT)


def creer_app(etat: Etat | None = None) -> FastAPI:
    etat = etat or Etat()
    relais = os.environ.get("COMMUNAUTE_RELAIS") == "1"
    app = FastAPI(title="AppliTransport communauté", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.etat = etat

    def adresse(request: Request) -> str:
        if relais:
            transmis = request.headers.get("x-forwarded-for", "")
            if transmis:
                return transmis.split(",")[-1].strip()
        return request.client.host if request.client else "?"

    @app.exception_handler(Refus)
    async def refus(_request: Request, e: Refus):
        return JSONResponse(status_code=e.statut, content={"erreur": e.code, "message": str(e)})

    @app.get("/sante")
    def sante():
        return {"ok": True}

    @app.post("/v1/positions", status_code=204)
    def positions(m: PositionIn, request: Request, x_empreinte: str = Header(pattern=EMPREINTE)):
        etat.position(x_empreinte, adresse(request), m.model_dump())

    @app.post("/v1/signalements", status_code=201)
    def signalements(m: SignalementIn, request: Request, x_empreinte: str = Header(pattern=EMPREINTE)):
        if m.type in ("retard", "supprime") and not (m.course or m.arret):
            raise Refus("invalide", "un retard ou une suppression porte sur une course ou un arrêt")
        return {"id": etat.signalement(x_empreinte, adresse(request), m.model_dump())}

    @app.get("/v1/lignes/{ligne}")
    def ligne(request: Request, ligne: str = Path(pattern=IDENT)):
        return etat.ligne(ligne, adresse(request))

    return app


app = creer_app()
