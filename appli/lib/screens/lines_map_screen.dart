// Carte des lignes d'un arrêt (« Quelle ligne prendre ? ») : chaque ligne qui y passe, dessinée de cet
// arrêt jusqu'à son terminus, dans chaque sens. Toucher un arrêt le choisit comme arrivée. Calculé sur le
// téléphone à partir des lignes téléchargées ; moteur MapLibre et fond OpenFreeMap.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../data/track.dart' show distanceMeters;
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../widgets/line_badge.dart';

/// Une ligne vue depuis un arrêt : un sens, son tracé à partir de l'arrêt et les arrêts suivants.
class LineReach {
  LineReach(this.line, this.shape, this.stops);
  final DemoLine line;
  final List<LatLng> shape;
  final List<Stop> stops; // arrêts après celui de départ, terminus compris
  String get terminus => stops.isEmpty ? '' : stops.last.name;
}

/// Tracé à partir du point le plus proche de [from].
List<LatLng> shapeFrom(List<LatLng> shape, LatLng from) {
  if (shape.length < 2) return shape;
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < shape.length; i++) {
    final d = distanceMeters(shape[i], from);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return [from, ...shape.sublist(best)];
}

/// Lignes téléchargées qui passent à [origin] : pour chaque sens et chaque terminus, le parcours le plus
/// long à partir de cet arrêt.
List<LineReach> linesFrom(AppState app, StopArea origin) {
  final out = <LineReach>[];
  for (final id in origin.lines) {
    final l = app.timetable(id);
    if (l == null) continue;
    for (final d in l.directions) {
      final byTerminus = <String, LineReach>{};
      for (final v in d.variants) {
        final i = v.stops.indexWhere((s) => s.area == origin.id);
        if (i < 0 || i == v.stops.length - 1) continue;
        final r = LineReach(l, shapeFrom(v.shape, v.stops[i].pos), v.stops.sublist(i + 1));
        final prev = byTerminus[r.terminus];
        if (prev == null || r.stops.length > prev.stops.length) byTerminus[r.terminus] = r;
      }
      out.addAll(byTerminus.values);
    }
  }
  return out;
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class LinesMapScreen extends StatefulWidget {
  const LinesMapScreen({super.key, required this.app, required this.origin});
  final AppState app;
  final StopArea origin;

  @override
  State<LinesMapScreen> createState() => _LinesMapScreenState();
}

class _LinesMapScreenState extends State<LinesMapScreen> {
  ml.MapLibreMapController? _map;
  bool _styleReady = false;
  String? _selected; // ligne mise en évidence
  bool _downloading = false;

  AppState get app => widget.app;
  List<LineReach> get _reach => linesFrom(app, widget.origin);
  List<String> get _missing => [
    for (final id in widget.origin.lines)
      if (!app.hasSchedules(id)) id,
  ];

  Map<String, dynamic> _linesGeo(List<LineReach> reach) => {
    'type': 'FeatureCollection',
    'features': [
      for (final r in reach)
        if (r.shape.length >= 2)
          {
            'type': 'Feature',
            'properties': {
              'color': _hex(r.line.color),
              'op': _selected == null || _selected == r.line.id ? 0.9 : 0.15,
              'w': _selected == r.line.id ? 7.0 : 4.5,
            },
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final p in r.shape) [p.longitude, p.latitude],
              ],
            },
          },
    ],
  };

  Map<String, dynamic> _stopsGeo(List<LineReach> reach) {
    final seen = <String>{};
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final r in reach)
          if (_selected == null || _selected == r.line.id)
            for (final s in r.stops)
              if (seen.add('${s.area}|${r.line.id}'))
                {
                  'type': 'Feature',
                  'properties': {'area': s.area, 'name': s.name, 'color': _hex(r.line.color)},
                  'geometry': {
                    'type': 'Point',
                    'coordinates': [s.pos.longitude, s.pos.latitude],
                  },
                },
      ],
    };
  }

  Map<String, dynamic> _terminiGeo(List<LineReach> reach) => {
    'type': 'FeatureCollection',
    'features': [
      for (final r in reach)
        if (r.stops.isNotEmpty && (_selected == null || _selected == r.line.id))
          {
            'type': 'Feature',
            'properties': {'label': '${r.line.name} ${r.terminus}'},
            'geometry': {
              'type': 'Point',
              'coordinates': [r.stops.last.pos.longitude, r.stops.last.pos.latitude],
            },
          },
    ],
  };

  Future<void> _onStyle() async {
    final m = _map;
    if (m == null) return;
    final reach = _reach;
    final o = widget.origin.pos;
    final dark = Theme.of(context).brightness == Brightness.dark;
    await m.addGeoJsonSource('lignes', _linesGeo(reach));
    await m.addGeoJsonSource('arrets', _stopsGeo(reach));
    await m.addGeoJsonSource('terminus', _terminiGeo(reach));
    await m.addGeoJsonSource('depart', {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': <String, dynamic>{},
          'geometry': {
            'type': 'Point',
            'coordinates': [o.longitude, o.latitude],
          },
        },
      ],
    });
    await m.addLineLayer(
      'lignes',
      'lignes',
      const ml.LineLayerProperties(
        lineColor: ['get', 'color'],
        lineOpacity: ['get', 'op'],
        lineWidth: ['get', 'w'],
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
    await m.addCircleLayer(
      'arrets',
      'arrets',
      const ml.CircleLayerProperties(
        circleRadius: 5,
        circleColor: '#FFFFFF',
        circleStrokeColor: ['get', 'color'],
        circleStrokeWidth: 2.5,
      ),
    );
    await m.addSymbolLayer(
      'terminus',
      'terminus',
      ml.SymbolLayerProperties(
        textField: const ['get', 'label'],
        textFont: const ['Noto Sans Bold'],
        textSize: 12,
        // mode sombre : texte clair sur halo foncé
        textColor: dark ? '#E8EEF2' : '#14212B',
        textHaloColor: dark ? '#14212B' : '#FFFFFF',
        textHaloWidth: 2,
        textOffset: [0, 1.2],
        textAnchor: 'top',
      ),
    );
    await m.addCircleLayer(
      'depart',
      'depart',
      ml.CircleLayerProperties(
        circleRadius: 9,
        circleColor: dark ? '#5FB4D0' : '#0E5A73',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
    );
    _styleReady = true;
    _fit(reach);
  }

  /// Cadre la carte sur toutes les lignes (ou celle mise en évidence).
  void _fit(List<LineReach> reach) {
    final pts = [
      widget.origin.pos,
      for (final r in reach)
        if (_selected == null || _selected == r.line.id) ...r.shape,
    ];
    if (pts.length < 2) return;
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    _map?.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e)),
        left: 40,
        top: 90,
        right: 40,
        bottom: 60,
      ),
    );
  }

  Future<void> _refresh({bool fit = false}) async {
    final m = _map;
    if (m == null || !_styleReady) return;
    final reach = _reach;
    await m.setGeoJsonSource('lignes', _linesGeo(reach));
    await m.setGeoJsonSource('arrets', _stopsGeo(reach));
    await m.setGeoJsonSource('terminus', _terminiGeo(reach));
    if (fit) _fit(reach);
  }

  /// Toucher un arrêt (zone de 44 px autour du doigt) : il devient l'arrivée.
  Future<void> _onTap(math.Point<double> p) async {
    final m = _map;
    if (m == null) return;
    final f = await m.queryRenderedFeaturesInRect(Rect.fromCenter(center: Offset(p.x, p.y), width: 44, height: 44), [
      'arrets',
    ], null);
    if (f.isEmpty || !mounted) return;
    final props = (f.first as Map)['properties'] as Map?;
    final area = app.stopAreas[props?['area']];
    if (area == null) return;
    Navigator.pop(context, area);
  }

  Future<void> _downloadMissing() async {
    setState(() => _downloading = true);
    for (final id in _missing) {
      await app.download(id);
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    _refresh(fit: true);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final lines = [for (final id in widget.origin.lines) ?app.timetable(id)];
    final missing = _missing;
    return Scaffold(
      appBar: AppBar(title: Text('Lignes de ${widget.origin.label}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          // pastilles : toucher une ligne la met en évidence, « Toutes » revient à l'ensemble
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: const Text('Toutes'),
                    selected: _selected == null,
                    showCheckmark: false,
                    onSelected: (_) {
                      setState(() => _selected = null);
                      _refresh(fit: true);
                    },
                  ),
                ),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setState(() => _selected = _selected == l.id ? null : l.id);
                        _refresh(fit: true);
                      },
                      child: Opacity(
                        opacity: _selected == null || _selected == l.id ? 1 : 0.35,
                        child: Center(
                          child: LineBadge(name: l.name, color: l.color, textColor: l.textColor),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (missing.isNotEmpty)
            Material(
              color: scheme.secondaryContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.download),
                title: Text('${missing.length} ligne(s) non téléchargée(s) : pas de tracé'),
                trailing: _downloading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: _downloadMissing, child: const Text('Télécharger')),
              ),
            ),
          Expanded(
            child: ml.MapLibreMap(
              styleString: 'https://tiles.openfreemap.org/styles/${dark ? 'dark' : 'liberty'}',
              initialCameraPosition: ml.CameraPosition(
                target: ml.LatLng(widget.origin.pos.latitude, widget.origin.pos.longitude),
                zoom: 13,
              ),
              compassEnabled: false,
              tiltGesturesEnabled: false,
              rotateGesturesEnabled: false,
              attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
              onMapCreated: (c) => _map = c,
              onStyleLoadedCallback: _onStyle,
              // un toucher sur un arrêt (élément de la carte) compte aussi comme toucher de carte
              featureTapsTriggersMapClick: true,
              onMapClick: (p, _) => _onTap(p),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Chaque ligne est dessinée de cet arrêt jusqu\'à son terminus. Touchez un arrêt pour le choisir '
                'comme arrivée.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
