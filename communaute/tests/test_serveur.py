"""Tests du serveur communautaire, sans réseau : horloge simulée, client de test FastAPI."""

import uuid

import pytest
from fastapi.testclient import TestClient

from communaute import etat as e
from communaute.serveur import creer_app

EMP_A = "a" * 64
EMP_B = "b" * 64


class Horloge:
    def __init__(self, t=1_794_640_000.0):  # 14/11/2026 vers 7 h UTC
        self.t = t

    def __call__(self):
        return self.t

    def avance(self, s):
        self.t += s


@pytest.fixture
def h():
    return Horloge()


@pytest.fixture
def client(h):
    return TestClient(creer_app(e.Etat(horloge=h)))


def position(session=None, **champs):
    m = {
        "v": 1,
        "session": session or str(uuid.uuid4()),
        "ligne": "C01527",
        "course": "123456",
        "sens": 0,
        "arret_prec": "IDFM:12345",
        "arret_suiv": "IDFM:12346",
        "progression": 0.42,
        "lat": 48.780123,
        "lon": 2.041256,
        "vitesse_kmh": 23.4,
        "t": 1_794_640_000,
    }
    m.update(champs)
    return m


def signalement(**champs):
    m = {
        "v": 1,
        "session": str(uuid.uuid4()),
        "ligne": "C01527",
        "type": "incident",
        "detail": "panne",
        "course": "123456",
        "t": 1_794_640_000,
    }
    m.update(champs)
    return m


def envoyer(client, chemin, corps, emp=EMP_A):
    return client.post(chemin, json=corps, headers={"X-Empreinte": emp})


def test_sante(client):
    assert client.get("/sante").json() == {"ok": True}


def test_position_puis_etat_de_ligne(client):
    assert envoyer(client, "/v1/positions", position()).status_code == 204
    r = client.get("/v1/lignes/C01527").json()
    assert r["signalements"] == []
    (v,) = r["vehicules"]
    assert v["course"] == "123456"
    assert (v["lat"], v["lon"]) == (48.7801, 2.0413)  # arrondi à environ 10 m
    assert v["sources"] == 1 and v["concordant"] is True
    assert "session" not in v  # jamais d'identifiant dans les réponses


def test_messages_invalides(client):
    assert envoyer(client, "/v1/positions", position(), emp="pas-une-empreinte").status_code == 422
    assert client.post("/v1/positions", json=position()).status_code == 422  # sans empreinte
    assert envoyer(client, "/v1/positions", position(lat=45.76)).status_code == 422  # hors Île-de-France
    assert envoyer(client, "/v1/positions", position(session="123")).status_code == 422
    assert envoyer(client, "/v1/positions", {**position(), "texte": "libre"}).status_code == 422
    assert envoyer(client, "/v1/signalements", signalement(detail="inconnu")).status_code == 422
    assert envoyer(client, "/v1/signalements", signalement(type="retard", detail="retard", course=None)).status_code == 422


def test_une_position_toutes_les_20_s(client, h):
    s = str(uuid.uuid4())
    assert envoyer(client, "/v1/positions", position(s)).status_code == 204
    h.avance(10)
    r = envoyer(client, "/v1/positions", position(s))
    assert r.status_code == 429 and r.json()["erreur"] == "debit"
    h.avance(15)
    assert envoyer(client, "/v1/positions", position(s, lat=48.7815)).status_code == 204


def test_saut_impossible_rejete(client, h):
    s = str(uuid.uuid4())
    envoyer(client, "/v1/positions", position(s))
    h.avance(30)
    assert envoyer(client, "/v1/positions", position(s, lat=48.80)).status_code == 422  # 2,2 km en 30 s


def test_nouvelle_session_remplace_la_precedente(client, h):
    envoyer(client, "/v1/positions", position(course="111"))
    h.avance(30)
    envoyer(client, "/v1/positions", position(course="222"))
    h.avance(11)  # au-delà du cache
    courses = [v["course"] for v in client.get("/v1/lignes/C01527").json()["vehicules"]]
    assert courses == ["222"]


def test_deux_voyageurs_dans_le_meme_bus(client, h):
    envoyer(client, "/v1/positions", position(), emp=EMP_A)
    envoyer(client, "/v1/positions", position(lat=48.7805), emp=EMP_B)
    (v,) = client.get("/v1/lignes/C01527").json()["vehicules"]
    assert v["sources"] == 2 and v["concordant"] is True


def test_deux_voyageurs_discordants(client, h):
    envoyer(client, "/v1/positions", position(), emp=EMP_A)
    envoyer(client, "/v1/positions", position(lat=48.80), emp=EMP_B)  # 2,2 km plus loin
    (v,) = client.get("/v1/lignes/C01527").json()["vehicules"]
    assert v["concordant"] is False


def test_positions_effacees_apres_10_min(client, h):
    envoyer(client, "/v1/positions", position())
    h.avance(5 * 60)
    (v,) = client.get("/v1/lignes/C01527").json()["vehicules"]
    assert v["sources"] == 0 and v["vu_il_y_a_s"] == 300  # gardée, mais plus « récente »
    h.avance(5 * 60)
    assert client.get("/v1/lignes/C01527").json()["vehicules"] == []


def test_cache_de_10_s(client, h):
    assert client.get("/v1/lignes/C01527").json()["vehicules"] == []
    envoyer(client, "/v1/positions", position())  # une écriture vide le cache de sa ligne
    assert len(client.get("/v1/lignes/C01527").json()["vehicules"]) == 1


def test_signalement_confirme_par_deux_sources(client, h):
    id1 = envoyer(client, "/v1/signalements", signalement(), emp=EMP_A).json()["id"]
    id2 = envoyer(client, "/v1/signalements", signalement(), emp=EMP_A).json()["id"]
    id3 = envoyer(client, "/v1/signalements", signalement(), emp=EMP_B).json()["id"]
    assert id1 == id2 == id3
    (s,) = client.get("/v1/lignes/C01527").json()["signalements"]
    assert s["sources"] == 2  # la même empreinte ne compte qu'une fois


def test_details_differents_restent_distincts_sauf_affluence(client):
    envoyer(client, "/v1/signalements", signalement(detail="panne"))
    envoyer(client, "/v1/signalements", signalement(detail="accident"))
    envoyer(client, "/v1/signalements", signalement(type="affluence", detail="assis"))
    envoyer(client, "/v1/signalements", signalement(type="affluence", detail="plein"), emp=EMP_B)
    sig = client.get("/v1/lignes/C01527").json()["signalements"]
    assert sorted(s["detail"] for s in sig) == ["accident", "panne", "plein"]


def test_nouvelles_valeurs(client):
    assert envoyer(client, "/v1/signalements", signalement(type="retard", detail="bloque")).status_code == 201
    for d in ("trafic_interrompu", "colis_suspect"):
        assert envoyer(client, "/v1/signalements", signalement(detail=d)).status_code == 201
    details = sorted(s["detail"] for s in client.get("/v1/lignes/C01527").json()["signalements"])
    assert details == ["bloque", "colis_suspect", "trafic_interrompu"]


def test_expiration_des_signalements(client, h):
    envoyer(client, "/v1/signalements", signalement(type="affluence", detail="debout"))
    envoyer(client, "/v1/signalements", signalement())
    h.avance(10 * 60 + 1)
    assert [s["type"] for s in client.get("/v1/lignes/C01527").json()["signalements"]] == ["incident"]
    h.avance(20 * 60)
    assert client.get("/v1/lignes/C01527").json()["signalements"] == []


def test_dix_signalements_par_heure(client, h):
    for i in range(10):
        assert envoyer(client, "/v1/signalements", signalement(arret=f"IDFM:{i}")).status_code == 201
    assert envoyer(client, "/v1/signalements", signalement(arret="IDFM:99")).status_code == 429
    h.avance(3601)
    assert envoyer(client, "/v1/signalements", signalement(arret="IDFM:99")).status_code == 201


def test_limite_par_adresse(client):
    for _ in range(60):
        assert client.get("/v1/lignes/C01527").status_code == 200
    assert client.get("/v1/lignes/C01527").status_code == 429


def test_changement_de_jour_vide_les_limites(client, h):
    h.t = (h.t // 86400 + 1) * 86400 - 600  # 23:50 UTC
    for i in range(10):
        envoyer(client, "/v1/signalements", signalement(arret=f"IDFM:{i}"))
    assert envoyer(client, "/v1/signalements", signalement(arret="IDFM:98")).status_code == 429
    h.avance(700)  # 00:01 UTC : moins d'une heure plus tard, mais un autre jour
    assert envoyer(client, "/v1/signalements", signalement(arret="IDFM:99")).status_code == 201


def test_rien_d_identifiant_dans_les_positions(h):
    etat = e.Etat(horloge=h)
    etat.position(EMP_A, "192.0.2.1", position())
    (p,) = etat.positions["C01527"].values()
    valeurs = " ".join(str(v) for v in vars(p).values())
    assert EMP_A not in valeurs and "192.0.2.1" not in valeurs
