# Licences

## Code d'AppliTransport
[PolyForm Strict 1.0.0](LICENSE.md) : utilisation libre et gratuite à des fins **non commerciales**,
**sans modification ni redistribution**.

## Données
- **Horaires, arrêts, lignes, temps réel, perturbations, itinéraires** : © Île-de-France Mobilités,
  [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
  Le catalogue et les paquets de lignes publiés par l'usine (GitHub Pages) sont une base de données
  dérivée : ils restent sous **ODbL**, indépendamment de la licence du code.
- **Communes des arrêts** : référentiel des arrêts © Île-de-France Mobilités, ODbL.
- **Fond de carte** : vectoriel [OpenFreeMap](https://openfreemap.org/), © [OpenMapTiles](https://www.openmaptiles.org/),
  données © contributeurs [OpenStreetMap](https://www.openstreetmap.org/copyright), ODbL ; affiché par
  [MapLibre](https://maplibre.org/).
- **Lieux** (commerces, équipements…) : © contributeurs OpenStreetMap, ODbL ; **adresses et lieux-dits** :
  © IGN (Géoplateforme) ; **entreprises** : © INSEE, base Sirene (API Recherche d'entreprises).

## Bibliothèques tierces
Chaque bibliothèque reste sous sa propre licence (toutes permissives) ; l'appli les liste dans
Configuration › Général › Licences.

| Bibliothèque | Licence |
|---|---|
| Flutter, http, path_provider | BSD 3 clauses |
| maplibre_gl | BSD 3 clauses (MapLibre Native : BSD 2 clauses) |
| latlong2 | Apache 2.0 |
| cupertino_icons | MIT |
| httpx (usine) | BSD 3 clauses |
| FastAPI (MIT), uvicorn (BSD), Leaflet (BSD 2 clauses) | POC web |
