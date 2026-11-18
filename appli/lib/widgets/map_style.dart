// Outils communs aux cartes MapLibre : fond vectoriel OpenFreeMap (clair ou sombre), GeoJSON, couleurs.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

/// Fond de carte vectoriel OpenFreeMap (© OpenMapTiles, © contributeurs OpenStreetMap).
String mapStyleUrl(bool dark) => 'https://tiles.openfreemap.org/styles/${dark ? 'dark' : 'liberty'}';

/// « #RRGGBB » d'une couleur (pour les couches de la carte).
String cssColor(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Map<String, dynamic> geoCollection(List<Map<String, dynamic>> features) => {
  'type': 'FeatureCollection',
  'features': features,
};

Map<String, dynamic> geoPoint(LatLng p, [Map<String, dynamic> props = const {}]) => {
  'type': 'Feature',
  'properties': props,
  'geometry': {
    'type': 'Point',
    'coordinates': [p.longitude, p.latitude],
  },
};

Map<String, dynamic> geoLine(List<LatLng> pts, [Map<String, dynamic> props = const {}]) => {
  'type': 'Feature',
  'properties': props,
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      for (final p in pts) [p.longitude, p.latitude],
    ],
  },
};

/// Rectangle englobant (au moins deux points).
ml.LatLngBounds boundsOf(List<LatLng> pts) {
  var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
  for (final p in pts) {
    s = math.min(s, p.latitude);
    n = math.max(n, p.latitude);
    w = math.min(w, p.longitude);
    e = math.max(e, p.longitude);
  }
  // un seul point (ou presque) : petit rectangle autour, pour que le cadrage reste raisonnable
  const pad = 0.002;
  if (n - s < pad) {
    s -= pad;
    n += pad;
  }
  if (e - w < pad) {
    w -= pad;
    e += pad;
  }
  return ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e));
}

/// Centre d'un ensemble de points (Paris s'il est vide).
LatLng centerOf(List<LatLng> pts) {
  if (pts.isEmpty) return const LatLng(48.8566, 2.3522);
  final b = boundsOf(pts);
  return LatLng((b.southwest.latitude + b.northeast.latitude) / 2, (b.southwest.longitude + b.northeast.longitude) / 2);
}
