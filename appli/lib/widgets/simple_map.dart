// Carte fixe (moteur MapLibre, fond vectoriel OpenFreeMap) : des traits (pleins ou en tirets), des
// points et des repères étiquetés (« Départ », « Arrivée »…), cadrée sur ce qu'elle montre.
// Sert au détail d'un trajet (Itinéraire) et à l'aperçu avant la recherche.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'map_style.dart';

class MapTrace {
  const MapTrace(this.points, {required this.color, this.width = 5, this.dashed = false});
  final List<LatLng> points;
  final Color color;
  final double width;

  /// Tirets cerclés de blanc (marche à pied, trajet à vol d'oiseau).
  final bool dashed;
}

class MapDot {
  const MapDot(this.point, {required this.color, this.stroke = Colors.white, this.radius = 6, this.strokeWidth = 2});
  final LatLng point;
  final Color color, stroke;
  final double radius, strokeWidth;
}

class MapFlag {
  const MapFlag(this.point, this.label, {required this.background, this.foreground = Colors.white});
  final LatLng point;
  final String label;
  final Color background, foreground;
}

class SimpleMap extends StatefulWidget {
  const SimpleMap({
    super.key,
    this.traces = const [],
    this.dots = const [],
    this.flags = const [],
    this.padding = const EdgeInsets.all(28),
  });
  final List<MapTrace> traces;
  final List<MapDot> dots;
  final List<MapFlag> flags;

  /// Marge du cadrage initial autour de tout ce qui est affiché.
  final EdgeInsets padding;

  @override
  State<SimpleMap> createState() => _SimpleMapState();
}

class _SimpleMapState extends State<SimpleMap> {
  ml.MapLibreMapController? _map;
  bool _ready = false;

  List<LatLng> get _all => [
    for (final t in widget.traces) ...t.points,
    for (final d in widget.dots) d.point,
    for (final f in widget.flags) f.point,
  ];

  Map<String, dynamic> _traces(bool dashed) => geoCollection([
    for (final t in widget.traces)
      if (t.dashed == dashed && t.points.length >= 2) geoLine(t.points, {'color': cssColor(t.color), 'w': t.width}),
  ]);

  Map<String, dynamic> _dots() => geoCollection([
    for (final d in widget.dots)
      geoPoint(d.point, {'color': cssColor(d.color), 'stroke': cssColor(d.stroke), 'r': d.radius, 'sw': d.strokeWidth}),
  ]);

  Map<String, dynamic> _flags() => geoCollection([
    for (final f in widget.flags)
      geoPoint(f.point, {'label': f.label, 'bg': cssColor(f.background), 'fg': cssColor(f.foreground)}),
  ]);

  @override
  void didUpdateWidget(SimpleMap old) {
    super.didUpdateWidget(old);
    _update();
  }

  Future<void> _update() async {
    final m = _map;
    if (m == null || !_ready) return;
    try {
      await m.setGeoJsonSource('traits', _traces(false));
      await m.setGeoJsonSource('tirets', _traces(true));
      await m.setGeoJsonSource('points', _dots());
      await m.setGeoJsonSource('reperes', _flags());
    } on PlatformException catch (_) {} // carte déjà fermée
  }

  Future<void> _onStyle() async {
    final m = _map;
    if (m == null || !mounted) return;
    final dark = Theme.of(context).brightness == Brightness.dark;
    await m.addGeoJsonSource('traits', _traces(false));
    await m.addGeoJsonSource('tirets', _traces(true));
    await m.addGeoJsonSource('points', _dots());
    await m.addGeoJsonSource('reperes', _flags());
    await m.addLineLayer(
      'traits',
      'traits',
      const ml.LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: ['get', 'w'],
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    // tirets sur un liseré (blanc, ou foncé en mode sombre), lisibles sur le fond
    await m.addLineLayer(
      'tirets',
      'tirets-lisere',
      ml.LineLayerProperties(
        lineColor: dark ? '#14212B' : '#FFFFFF',
        lineWidth: const [
          '+',
          ['get', 'w'],
          3,
        ],
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    await m.addLineLayer(
      'tirets',
      'tirets',
      const ml.LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: ['get', 'w'],
        lineDasharray: [1.2, 1.4],
        lineJoin: 'round',
      ),
    );
    await m.addCircleLayer(
      'points',
      'points',
      const ml.CircleLayerProperties(
        circleRadius: ['get', 'r'],
        circleColor: ['get', 'color'],
        circleStrokeColor: ['get', 'stroke'],
        circleStrokeWidth: ['get', 'sw'],
      ),
    );
    await m.addCircleLayer(
      'reperes',
      'reperes-point',
      const ml.CircleLayerProperties(
        circleRadius: 7,
        circleColor: ['get', 'bg'],
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ),
    );
    await m.addSymbolLayer(
      'reperes',
      'reperes-texte',
      const ml.SymbolLayerProperties(
        textField: ['get', 'label'],
        textFont: ['Noto Sans Bold'],
        textSize: 12,
        textColor: ['get', 'fg'],
        textHaloColor: ['get', 'bg'],
        textHaloWidth: 4,
        textAnchor: 'bottom',
        textOffset: [0, -0.9],
        textAllowOverlap: true,
      ),
    );
    _ready = true;
    final pts = _all;
    if (pts.isNotEmpty) {
      final p = widget.padding;
      await m.moveCamera(
        ml.CameraUpdate.newLatLngBounds(boundsOf(pts), left: p.left, top: p.top, right: p.right, bottom: p.bottom),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = centerOf(_all);
    return ml.MapLibreMap(
      styleString: mapStyleUrl(dark),
      initialCameraPosition: ml.CameraPosition(target: ml.LatLng(c.latitude, c.longitude), zoom: 13),
      compassEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      attributionButtonPosition: ml.AttributionButtonPosition.bottomRight,
      onMapCreated: (c) => _map = c,
      onStyleLoadedCallback: _onStyle,
    );
  }
}
