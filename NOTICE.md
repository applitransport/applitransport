# Licences

## Code d'AppliTransport
[PolyForm Strict 1.0.0](LICENSE.md) : utilisation libre et gratuite à des fins **non commerciales**,
**sans modification ni redistribution**.

## Données
- **Horaires prévus** ([GTFS IDFM](https://data.iledefrance-mobilites.fr/explore/dataset/offre-horaires-tc-gtfs-idfm/)) et **API PRIM** (prochains passages, perturbations,
  itinéraires) : © Île-de-France Mobilités, [Licence Mobilités](https://cloud.fabmob.io/s/eYWWJBdM3fQiFNm).
  Le catalogue et les paquets de lignes publiés par l'usine (GitHub Pages) sont une base de données
  dérivée : ils restent sous **Licence Mobilités** (partage à l'identique), indépendamment de la licence
  du code, qui ne s'applique pas aux données.
- **Communes des arrêts** : [référentiel des arrêts](https://data.iledefrance-mobilites.fr/explore/dataset/arrets/) © Île-de-France Mobilités,
  [Licence Ouverte 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/).
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
