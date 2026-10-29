# AppliTransport (Flutter)

Suivi des transports d'Île-de-France : horaires hors ligne (paquets de l'usine) + temps réel PRIM.

## Lancer (PC)
```bash
# 1. publier les données de l'usine en local (catalogue + paquets)
cd ~/Documents/projet_logiciel/appli_bus
.venv/bin/python -m http.server 8080 --bind 127.0.0.1 --directory usine/out/public
# 2. l'appli
cd appli && ~/flutter/bin/flutter run -d linux
```
Sur un téléphone : servir avec `--bind 0.0.0.0`, puis dans Configuration › Général › Serveur de données,
mettre `http://<adresse du PC>:8080/`.

## Données sur l'appareil
`<support>/donnees/` (Linux : `~/.local/share/fr.applitransport.app/donnees`) :
`catalog.json.gz`, `lines/*.json.gz` (paquets tels que publiés), `index.json` (versions, dates),
`settings.json` (préférées, jeton, durée auto, thème, serveur).

## Code
- `lib/data/` : dépôt local (téléchargements, mises à jour par version), décodage des paquets, réglages,
  client PRIM (`prim.dart` : cache 25 s, compteurs du jour, garde-fous) et rattachement du temps réel (`realtime.dart`)
- `lib/poc/` : modèles des écrans, état de l'appli ; itinéraires (cas 3) = exemples enregistrés
- `lib/screens/`, `lib/widgets/` : écrans validés avec la maquette
- `test/` : décodage des vrais paquets comparé au générateur Python, dépôt testé contre un serveur local,
  rattachement de vraies réponses PRIM enregistrées (bus par numéro, trains N par heure)
