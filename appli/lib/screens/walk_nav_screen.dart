// Navigation à pied jusqu'à l'arrêt de montée (bouton « Partir » d'un itinéraire).
// Moteur MapLibre et carte vectorielle OpenFreeMap : les noms de rue restent à l'endroit. L'appli
// centre la carte sur l'usager et la tourne elle-même, comme Organic Maps : capteur « vecteur de
// rotation » sans lissage, angle interpolé à chaque image de l'écran ; en marchant, la direction GPS
// prime 3 s après chaque position. (Le suivi intégré de MapLibre lisse et anime trop : latence.)
// Rien n'est envoyé : la position reste sur le téléphone.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_compass/flutter_compass.dart';
import '../data/geo.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/location.dart';
import '../data/track.dart' show distanceMeters, walkSpeed;
import '../poc/app_state.dart';
import '../poc/nearby.dart' show distanceLabel;
import '../poc/position.dart' show duration, hhmm;
import 'line_screen.dart';

/// Cap (degrés, 0 = nord, sens horaire) de [a] vers [b].
double bearing(LatLng a, LatLng b) {
  final p1 = a.latitudeInRad, p2 = b.latitudeInRad, dl = b.longitudeInRad - a.longitudeInRad;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Chemin restant depuis [me] : on repart du point du chemin le plus proche.
List<LatLng> remainingPath(List<LatLng> path, LatLng me) {
  if (path.isEmpty) return [me];
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < path.length; i++) {
    final d = distanceMeters(me, path[i]);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  // point le plus proche déjà dépassé : on vise le suivant
  final next = best + 1 < path.length && distanceMeters(me, path[best + 1]) < distanceMeters(path[best], path[best + 1])
      ? best + 1
      : best;
  return [me, ...path.sublist(next)];
}

double pathLength(List<LatLng> p) {
  var m = 0.0;
  for (var i = 1; i < p.length; i++) {
    m += distanceMeters(p[i - 1], p[i]);
  }
  return m;
}

/// Chevrons le long du chemin : position et cap, tous les [every] mètres.
List<(LatLng, double)> chevrons(List<LatLng> p, {double every = 25}) {
  final out = <(LatLng, double)>[];
  var carry = every / 2;
  for (var i = 1; i < p.length; i++) {
    final a = p[i - 1], b = p[i];
    final len = distanceMeters(a, b);
    if (len == 0) continue;
    final cap = bearing(a, b);
    var t = carry;
    while (t < len) {
      final f = t / len;
      out.add((LatLng(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f), cap));
      t += every;
    }
    carry = t - len;
  }
  return out;
}

Map<String, dynamic> _line(List<LatLng> p) => {
  'type': 'FeatureCollection',
  'features': [
    if (p.length >= 2)
      {
        'type': 'Feature',
        'properties': <String, dynamic>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final x in p) [x.longitude, x.latitude],
          ],
        },
      },
  ],
};

class WalkNavScreen extends StatefulWidget {
  const WalkNavScreen({
    super.key,
    required this.app,
    required this.path,
    required this.target,
    this.lineCode,
    this.lineId,
    this.departure,
    this.fromArea,
    this.toArea,
  });
  final AppState app;

  /// Chemin à pied proposé par l'itinéraire (peut être réduit à l'arrêt seul).
  final List<LatLng> path;

  /// Nom de l'arrêt (ou du lieu) à rejoindre.
  final String target;

  /// Transport à prendre à l'arrêt : numéro, identifiant de ligne, heure de départ (secondes du jour).
  final String? lineCode, lineId;
  final int? departure;
  final String? fromArea, toArea;

  @override
  State<WalkNavScreen> createState() => _WalkNavScreenState();
}

class _WalkNavScreenState extends State<WalkNavScreen> with SingleTickerProviderStateMixin {
  ml.MapLibreMapController? _map;
  bool _styleReady = false;
  StreamSubscription<Position>? _gps;
  StreamSubscription<CompassEvent>? _compass;
  double? _target; // dernier cap mesuré (degrés), null tant qu'il n'est pas connu
  double? _shown; // cap affiché, qui rejoint _target image par image
  DateTime _gpsBearingAt = DateTime(0); // dernière direction de marche GPS
  late final Ticker _frames = createTicker(_onFrame);
  Duration _lastFrame = Duration.zero;
  bool _moving = false; // déplacement de caméra en cours (on n'en empile pas)
  bool _dirty = false; // position changée : recentrer

  /// Angle de la flèche de l'usager à l'écran (degrés) : seule elle se redessine à chaque image.
  final _arrow = ValueNotifier<double?>(null);
  double _zoom = 17;
  Timer? _ticker;
  LatLng? _me;
  bool _follow = true; // carte qui suit l'usager
  bool _headingUp = true; // carte orientée dans ma direction (sinon nord en haut)
  String? _error;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    _start();
  }

  Future<void> _start() async {
    try {
      await ensureLocationPermission();
    } catch (e) {
      setState(() => _error = 'Localisation indisponible : $e');
      return;
    }
    // position pour les distances et le chemin restant (la carte a son propre suivi)
    _gps =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 2),
        ).listen((p) {
          _me = LatLng(p.latitude, p.longitude);
          // en marchant (> 0,7 m/s ≈ 2,5 km/h), la direction de marche prime sur la boussole
          if (p.speed > 0.7 && p.heading >= 0) {
            _target = p.heading;
            _gpsBearingAt = DateTime.now();
          }
          _drawPath();
          _dirty = true;
          if (mounted) setState(() {});
        }, onError: (e) => setState(() => _error = 'Localisation indisponible : $e'));
    _compass = FlutterCompass.events?.listen((e) {
      final raw = e.heading;
      if (raw == null) return;
      if (DateTime.now().difference(_gpsBearingAt).inMilliseconds < 3000) return;
      _target = (raw + 360) % 360; // capteur déjà stable : pas de lissage
    });
    _frames.start();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _gps?.cancel();
    _compass?.cancel();
    _frames.dispose();
    _arrow.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  List<LatLng> get _path => _me == null ? widget.path : remainingPath(widget.path, _me!);

  Future<void> _onStyle() async {
    final m = _map;
    if (m == null) return;
    final p = _path;
    await m.addGeoJsonSource('liaison', _line(p.length >= 2 && _me != null ? p.sublist(0, 2) : const []));
    await m.addGeoJsonSource('chemin', _line(_me != null ? p.sublist(1) : p));
    await m.addGeoJsonSource('arrivee', {
      'type': 'FeatureCollection',
      'features': [
        if (widget.path.isNotEmpty)
          {
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': {
              'type': 'Point',
              'coordinates': [widget.path.last.longitude, widget.path.last.latitude],
            },
          },
      ],
    });
    // ma position → chemin : trait gris fin (ce n'est pas un chemin par les rues)
    await m.addLineLayer('liaison', 'liaison', const ml.LineLayerProperties(lineColor: '#9E9E9E', lineWidth: 2));
    await m.addLineLayer(
      'chemin',
      'chemin-bord',
      const ml.LineLayerProperties(lineColor: '#FFFFFF', lineWidth: 8, lineCap: 'round'),
    );
    await m.addLineLayer(
      'chemin',
      'chemin',
      const ml.LineLayerProperties(lineColor: '#1E88E5', lineWidth: 5, lineCap: 'round', lineDasharray: [1, 1.5]),
    );
    // chevrons de direction le long du chemin
    await m.addSymbolLayer(
      'chemin',
      'chevrons',
      const ml.SymbolLayerProperties(
        symbolPlacement: 'line',
        symbolSpacing: 60,
        textField: '›',
        textFont: ['Noto Sans Bold'],
        textSize: 24,
        textColor: '#0D47A1',
        textHaloColor: '#FFFFFF',
        textHaloWidth: 1.5,
        textKeepUpright: false,
        textRotationAlignment: 'map',
        textAllowOverlap: true,
      ),
    );
    await m.addCircleLayer(
      'arrivee',
      'arrivee',
      const ml.CircleLayerProperties(
        circleRadius: 9,
        circleColor: '#2E7D32',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 3,
      ),
    );
    _styleReady = true;
  }

  Future<void> _drawPath() async {
    final m = _map;
    if (m == null || !_styleReady || _me == null) return;
    final p = _path;
    try {
      await m.setGeoJsonSource('liaison', _line(p.sublist(0, math.min(2, p.length))));
      await m.setGeoJsonSource('chemin', _line(p.sublist(1)));
    } on PlatformException catch (_) {} // écran quitté entre-temps
  }

  /// À chaque image : le cap affiché rejoint le cap mesuré (≈ 60 ms), puis la carte est recentrée et
  /// tournée si quelque chose a changé.
  void _onFrame(Duration now) {
    final dt = (now - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = now;
    final t = _target;
    if (t != null) {
      final s = _shown;
      if (s == null) {
        _shown = t;
        _dirty = true;
      } else {
        final diff = ((t - s + 540) % 360) - 180;
        if (diff.abs() > 0.05) {
          _shown = (s + diff * (1 - math.exp(-dt.clamp(0, 0.1) / 0.06)) + 360) % 360;
          _dirty = true;
        }
      }
    }
    if (_dirty) _moveCamera();
    // flèche : vers le haut si la carte est orientée dans ma direction, sinon mon cap
    _arrow.value = _shown == null ? null : (_headingUp ? 0 : _shown);
  }

  /// Centre la carte sur l'usager et l'oriente (sans animation : l'interpolation est faite par image).
  void _moveCamera({bool force = false}) {
    final m = _map, me = _me;
    if (m == null || me == null || !_follow) return;
    if (_moving && !force) return; // déplacement précédent pas encore appliqué
    _dirty = false;
    _moving = true;
    m
        .moveCamera(
          ml.CameraUpdate.newCameraPosition(
            ml.CameraPosition(
              target: ml.LatLng(me.latitude, me.longitude),
              zoom: _zoom,
              bearing: _headingUp ? (_shown ?? 0) : 0,
            ),
          ),
        )
        .whenComplete(() => _moving = false);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final me = _me;
    final left = pathLength(me == null ? widget.path : _path);
    final arrived = me != null && left < 20;
    final start = widget.path.isNotEmpty ? widget.path.first : const LatLng(48.85, 2.35);
    return Scaffold(
      appBar: AppBar(title: Text('Vers ${widget.target}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          _banner(context, left, arrived),
          Expanded(
            child: Stack(
              children: [
                // l'usager touche la carte : elle ne le suit plus (bouton pour reprendre)
                Listener(
                  onPointerDown: (_) {
                    if (_follow) setState(() => _follow = false);
                  },
                  child: ml.MapLibreMap(
                    styleString: 'https://tiles.openfreemap.org/styles/${dark ? 'dark' : 'liberty'}',
                    initialCameraPosition: ml.CameraPosition(
                      target: ml.LatLng(start.latitude, start.longitude),
                      zoom: 17,
                    ),
                    myLocationEnabled: true,
                    myLocationRenderMode: ml.MyLocationRenderMode.normal,
                    trackCameraPosition: true,
                    compassEnabled: false,
                    tiltGesturesEnabled: false,
                    attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
                    onMapCreated: (c) => _map = c,
                    onStyleLoadedCallback: _onStyle,
                    // zoom choisi par l'usager : conservé quand la carte reprend le suivi
                    onCameraIdle: () => _zoom = _map?.cameraPosition?.zoom ?? _zoom,
                  ),
                ),
                // flèche de l'usager, au centre (la carte y est centrée sur lui), même angle que la carte
                if (_follow && _me != null)
                  Center(
                    child: IgnorePointer(
                      child: ValueListenableBuilder(
                        valueListenable: _arrow,
                        builder: (context, angle, _) => angle == null
                            ? const SizedBox.shrink()
                            : Transform.rotate(
                                angle: angle * math.pi / 180,
                                child: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black38)],
                                  ),
                                  child: const Icon(Icons.navigation, color: Color(0xFF1E88E5), size: 28),
                                ),
                              ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: Column(
                    children: [
                      // orientation : dans ma direction ↔ nord en haut
                      FloatingActionButton.small(
                        heroTag: 'cap',
                        tooltip: _headingUp ? 'Nord en haut' : 'Orienter dans ma direction',
                        onPressed: () {
                          setState(() {
                            _headingUp = !_headingUp;
                            _follow = true;
                          });
                          _moveCamera(force: true);
                        },
                        child: Icon(_headingUp ? Icons.explore : Icons.navigation),
                      ),
                      if (!_follow) ...[
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'centre',
                          tooltip: 'Recentrer sur moi',
                          onPressed: () {
                            setState(() => _follow = true);
                            _moveCamera(force: true);
                          },
                          child: const Icon(Icons.my_location),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.lineId != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.timeline),
                    label: Text('Suivre le ${widget.lineCode ?? 'transport'}'),
                    // retour : on revient sur la navigation, qui continue
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LineScreen(
                          app: app,
                          lineId: widget.lineId,
                          fromArea: widget.fromArea,
                          toArea: widget.toArea,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _banner(BuildContext context, double left, bool arrived) {
    final scheme = Theme.of(context).colorScheme;
    final walkSec = (left / walkSpeed).round();
    final dep = widget.departure;
    final now = app.nowSec();
    final spare = dep == null ? null : dep - now - walkSec; // marge à l'arrivée à l'arrêt
    final late = dep != null && spare != null && spare < 60 && !arrived && dep > now;
    final first = _error != null
        ? _error!
        : _me == null
        ? 'Recherche de votre position…'
        : arrived
        ? 'Vous êtes à ${widget.target}.'
        : '${widget.target} : ${distanceLabel(left)} · ${duration(walkSec)} à pied';
    final second = dep == null
        ? null
        : '${widget.lineCode ?? 'Départ'} à ${hhmm(dep)}'
              '${dep > now ? ' (dans ${duration(dep - now)})' : ' (parti)'}'
              '${late ? ' · pressez le pas' : ''}';
    final fg = late ? Colors.white : scheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      color: late ? Colors.orange.shade800 : scheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(first, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg)),
          if (second != null) Text(second, style: TextStyle(color: fg)),
        ],
      ),
    );
  }
}
