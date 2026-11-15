# Serveur communautaire

Relais des positions « je suis dedans » et des signalements des voyageurs (retard, incident,
supprimé, affluence). Conception : note « AppliTransport — Signalements communautaires ».

- Tout est **en mémoire** : rien sur disque, positions effacées 10 min après réception,
  signalements après 10 à 30 min selon le type.
- **Aucune adresse IP** écrite (journal d'accès désactivé) ; l'empreinte du jour (`X-Empreinte`)
  ne sert qu'aux limites de débit et au comptage des sources, salée, jamais rangée avec les positions.
- Le serveur n'appelle jamais PRIM : la fusion avec PRIM se fait dans l'appli.

| Route | Rôle |
|---|---|
| `POST /v1/positions` | dernier point d'un trajet (au plus 1 toutes les 20 s par empreinte) |
| `POST /v1/signalements` | signalement (au plus 10 par heure par empreinte) |
| `GET /v1/lignes/{ligne}` | véhicules vus et signalements en cours (cache 10 s) |
| `GET /sante` | surveillance |

## Développement

```bash
.venv/bin/pip install -r communaute/requirements-dev.txt
.venv/bin/python -m pytest communaute                       # tests (horloge simulée)
.venv/bin/uvicorn communaute.serveur:app --port 8765 --no-access-log   # serveur local
```

## Installation sur un serveur

```bash
SSH_OPTS="-i ~/.ssh/<clé>" communaute/deploy/deployer.sh <utilisateur>@<machine>
```

Copie le code, crée le compte système `applitransport-communaute`, l'environnement Python dans
`/opt/applitransport-communaute` et le service systemd du même nom : écoute en local seulement
(`127.0.0.1:8765`, `IPAddressDeny=any` hors localhost), mémoire bornée à 256 Mo, pas de journal
d'accès. Un relais HTTPS sur la même machine (Caddy : `reverse_proxy 127.0.0.1:8765` pour `/v1/*` et
`/sante`) le rend joignable ; `COMMUNAUTE_RELAIS=1` lui fait lire l'adresse réelle dans
`X-Forwarded-For` et `COMMUNAUTE_IP_PAR_MINUTE` règle la limite par adresse. Relancer la même
commande met à jour. Journal : `journalctl -u applitransport-communaute`.
