// Carte d'un sens de ligne (moteur MapLibre, fond vectoriel OpenFreeMap) : tracés de ses variantes,
// arrêts, votre arrêt, l'arrivée, les véhicules et, à la demande, votre position GPS. Tout est dessiné
// en couches de la carte ; les véhicules portent une icône dessinée par l'appli.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../data/geo.dart';
import '../poc/data.dart';
import 'map_style.dart';

class MapBus {
  const MapBus({
    required this.id,
    required this.position,
    required this.selected,
    required this.realtime,
    this.crowd = false,
    this.alert = false,
  });
  final String id; // « variante/course »
  final LatLng position;
  final bool selected, realtime;

  /// Position vue par un voyageur à bord (recalée sur le tracé) plutôt qu'estimée.
  final bool crowd;

  /// Signalé bloqué ou en incident par des voyageurs.
  final bool alert;
}

class LineMap extends StatefulWidget {
  const LineMap({
    super.key,
    required this.shapes,
    required this.stops,
    required this.color,
    this.myStop,
    this.toStop,
    this.buses = const [],
    this.onBusTap,
    this.vehicleIcon = Icons.directions_bus,
    this.confirmationColors = false,
    this.alertStops = const [],
    this.showMe = false,
  });

  final List<List<LatLng>> shapes;
  final List<Stop> stops;
  final Color color;
  final Stop? myStop;

  /// Arrêt d'arrivée, marqué « Arrivée » (Quelle ligne prendre ?).
  final Stop? toStop;
  final List<MapBus> buses;
  final void Function(String busId)? onBusTap;

  /// Icône des véhicules sur la carte (bus, train, métro, tram).
  final IconData vehicleIcon;

  /// Couleur des véhicules selon leur source : vert = vu par un voyageur, rouge = théorique ou PRIM
  /// (suivi de ligne). Sinon : couleur de la ligne en temps réel, gris en théorique.
  final bool confirmationColors;

  /// Afficher la position du téléphone (réglage « Ma position sur la carte »).
  final bool showMe;

  /// Arrêts où des voyageurs signalent un incident.
  final List<LatLng> alertStops;

  @override
  State<LineMap> createState() => _LineMapState();
}

class _LineMapState extends State<LineMap> {
  ml.MapLibreMapController? _map;
  bool _ready = false;
  StreamSubscription<Position>? _gps;
  LatLng? _me;

  @override
  void initState() {
    super.initState();
    if (widget.showMe) _follow();
  }

  @override
  void didUpdateWidget(LineMap old) {
    super.didUpdateWidget(old);
    if (widget.showMe && _gps == null) _follow();
    if (!widget.showMe && _gps != null) {
      _gps!.cancel();
      _gps = null;
      _me = null;
    }
    _refresh();
  }

  @override
  void dispose() {
    _gps?.cancel();
    super.dispose();
  }

  /// Suit la position du téléphone (permission déjà accordée dans les réglages) sans déplacer la carte.
  void _follow() {
    _gps = Geolocator.getPositionStream(locationSettings: const LocationSettings(distanceFilter: 10)).listen((p) {
      _me = LatLng(p.latitude, p.longitude);
      _refresh();
    }, onError: (_) {});
  }

  List<List<LatLng>> get _lines {
    final lines = widget.shapes.where((s) => s.length >= 2).toList();
    if (lines.isEmpty) lines.add([for (final s in widget.stops) s.pos]);
    return lines;
  }

  // --- données des couches -------------------------------------------------------------------
  Map<String, dynamic> _lineGeo() => geoCollection([
    for (final l in _lines)
      if (l.length >= 2) geoLine(l),
  ]);

  Map<String, dynamic> _stopsGeo() => geoCollection([for (final s in widget.stops) geoPoint(s.pos)]);

  Map<String, dynamic> _flagsGeo(ColorScheme scheme) => geoCollection([
    if (widget.myStop case final s?)
      geoPoint(s.pos, {
        'label': 'Votre arrêt',
        'bg': cssColor(scheme.inverseSurface),
        'fg': cssColor(scheme.onInverseSurface),
      }),
    if (widget.toStop case final s?)
      geoPoint(s.pos, {'label': 'Arrivée', 'bg': cssColor(Colors.green.shade700), 'fg': '#FFFFFF'}),
  ]);

  Map<String, dynamic> _busGeo(ColorScheme scheme) {
    // le véhicule choisi en dernier : dessiné au-dessus des autres
    final buses = [...widget.buses]..sort((a, b) => a.selected ? 1 : (b.selected ? -1 : 0));
    return geoCollection([
      for (final b in buses)
        geoPoint(b.position, {
          'id': b.id,
          'color': cssColor(
            widget.confirmationColors
                ? (b.crowd ? Colors.green.shade600 : Colors.red.shade600)
                : (b.realtime ? widget.color : Colors.grey),
          ),
          'stroke': b.selected ? cssColor(scheme.onSurface) : '#FFFFFF',
          'r': b.selected ? 19.0 : 13.0,
          'sw': b.selected ? 3.0 : 2.0,
          'icon': b.selected ? 0.9 : 0.6,
        }),
    ]);
  }

  Map<String, dynamic> _alertsGeo() => geoCollection([
    for (final b in widget.buses)
      if (b.alert) geoPoint(b.position, {'bus': 1}),
    for (final p in widget.alertStops) geoPoint(p, {'bus': 0}),
  ]);

  Map<String, dynamic> _meGeo() => geoCollection([if (_me case final p?) geoPoint(p)]);

  Future<void> _onStyle() async {
    final m = _map;
    if (m == null || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = cssColor(widget.color);
    await m.addImage('vehicule', await iconImage(widget.vehicleIcon, Colors.white, 64));
    await m.addGeoJsonSource('trace', _lineGeo());
    await m.addGeoJsonSource('arrets', _stopsGeo());
    await m.addGeoJsonSource('reperes', _flagsGeo(scheme));
    await m.addGeoJsonSource('vehicules', _busGeo(scheme));
    await m.addGeoJsonSource('alertes', _alertsGeo());
    await m.addGeoJsonSource('moi', _meGeo());
    await m.addLineLayer(
      'trace',
      'trace',
      ml.LineLayerProperties(lineColor: line, lineOpacity: 0.85, lineWidth: 5, lineCap: 'round', lineJoin: 'round'),
    );
    await m.addCircleLayer(
      'arrets',
      'arrets',
      ml.CircleLayerProperties(
        circleRadius: 4,
        circleColor: dark ? '#1E2328' : '#FFFFFF',
        circleStrokeColor: line,
        circleStrokeWidth: 2,
      ),
    );
    // « Votre arrêt », « Arrivée » : un repère et son étiquette
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
    await m.addCircleLayer(
      'vehicules',
      'vehicules',
      const ml.CircleLayerProperties(
        circleRadius: ['get', 'r'],
        circleColor: ['get', 'color'],
        circleStrokeColor: ['get', 'stroke'],
        circleStrokeWidth: ['get', 'sw'],
      ),
    );
    await m.addSymbolLayer(
      'vehicules',
      'vehicules-icone',
      const ml.SymbolLayerProperties(
        iconImage: 'vehicule',
        iconSize: ['get', 'icon'],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
    );
    // signalé bloqué ou en incident : pastille orange (en haut à droite du véhicule, ou sur l'arrêt)
    for (final (id, bus, shift) in [
      ('alertes-vehicule', 1, <double>[12, -12]),
      ('alertes-arret', 0, <double>[0, 0]),
    ]) {
      await m.addCircleLayer(
        'alertes',
        id,
        ml.CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#E65100',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 1.5,
          circleTranslate: shift,
        ),
        filter: [
          '==',
          ['get', 'bus'],
          bus,
        ],
      );
    }
    await m.addCircleLayer(
      'moi',
      'moi',
      const ml.CircleLayerProperties(
        circleRadius: 8,
        circleColor: '#2196F3',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
    );
    _ready = true;
    _fit();
  }

  void _fit() {
    final pts = [for (final l in _lines) ...l];
    if (pts.length < 2) return;
    _map?.moveCamera(ml.CameraUpdate.newLatLngBounds(boundsOf(pts), left: 24, top: 24, right: 24, bottom: 24));
  }

  /// Données changées (véhicules qui avancent, position, signalements) : couches mises à jour.
  Future<void> _refresh() async {
    final m = _map;
    if (m == null || !_ready || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    await m.setGeoJsonSource('vehicules', _busGeo(scheme));
    await m.setGeoJsonSource('alertes', _alertsGeo());
    await m.setGeoJsonSource('reperes', _flagsGeo(scheme));
    await m.setGeoJsonSource('moi', _meGeo());
  }

  /// Toucher un véhicule (zone de 44 px) : sa fiche.
  Future<void> _onTap(math.Point<double> p) async {
    final m = _map, cb = widget.onBusTap;
    if (m == null || cb == null) return;
    final f = await m.queryRenderedFeaturesInRect(Rect.fromCenter(center: Offset(p.x, p.y), width: 44, height: 44), [
      'vehicules',
    ], null);
    if (f.isEmpty) return;
    final id = ((f.last as Map)['properties'] as Map?)?['id'];
    if (id is String) cb(id);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = centerOf(_lines.expand((l) => l).toList());
    return ml.MapLibreMap(
      styleString: mapStyleUrl(dark),
      initialCameraPosition: ml.CameraPosition(target: ml.LatLng(c.latitude, c.longitude), zoom: 12),
      compassEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      attributionButtonPosition: ml.AttributionButtonPosition.bottomRight,
      onMapCreated: (c) => _map = c,
      onStyleLoadedCallback: _onStyle,
      featureTapsTriggersMapClick: true,
      onMapClick: (p, _) => _onTap(p),
    );
  }
}

/// Icône Material dessinée en image PNG (icône des véhicules sur la carte).
Future<Uint8List> iconImage(IconData icon, Color color, double size) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final tp = TextPainter(textDirection: TextDirection.ltr)
    ..text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontSize: size, fontFamily: icon.fontFamily, package: icon.fontPackage, color: color),
    )
    ..layout();
  tp.paint(canvas, Offset.zero);
  final img = await recorder.endRecording().toImage(size.ceil(), size.ceil());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}
