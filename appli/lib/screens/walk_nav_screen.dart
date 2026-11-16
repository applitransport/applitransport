// Navigation à pied jusqu'à l'arrêt de montée (bouton « Partir » d'un itinéraire).
// Carte vectorielle (OpenFreeMap) qui suit l'usager, orientée dans sa direction : boussole à l'arrêt
// ou en marchant lentement, direction de marche (GPS) au-delà. Rien n'est envoyé : la position reste
// sur le téléphone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' show ThemeReader;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/location.dart';
import '../data/track.dart' show distanceMeters;
import '../poc/app_state.dart';
import '../poc/nearby.dart' show distanceLabel;
import '../poc/position.dart' show duration, hhmm;
import 'line_screen.dart';

/// Vitesse de marche retenue pour les temps restants (m/s, ≈ 4,7 km/h).
const walkSpeed = 1.3;

/// Au-delà de cette vitesse (m/s), la direction de marche (GPS) oriente la carte ; en dessous, la
/// boussole.
const _gpsHeadingSpeed = 0.8;

/// Écart entre deux chevrons de direction sur le chemin (m).
const _chevronEvery = 25.0;

/// Style de carte vectorielle (lu une fois par session, clair ou sombre).
final Map<bool, Future<Style?>> _styles = {};
Future<Style?> _style(bool dark) => _styles[dark] ??= _readStyle(dark).catchError((_) => null);

Future<Style?> _readStyle(bool dark) async {
  final uri = 'https://tiles.openfreemap.org/styles/${dark ? 'dark' : 'liberty'}';
  final base = await StyleReader(uri: uri).read();
  // les noms (rues, lieux) sont écrits avec une expression « nom latin, sinon nom local » que le moteur
  // ne lit pas : sans correction, aucun texte n'est dessiné. On la remplace par le nom simple.
  final json = jsonDecode(utf8.decode((await http.get(Uri.parse(uri))).bodyBytes)) as Map<String, dynamic>;
  for (final l in (json['layers'] as List).cast<Map<String, dynamic>>()) {
    final layout = l['layout'];
    if (l['type'] == 'symbol' && layout is Map && layout['text-field'] is List) {
      final f = jsonEncode(layout['text-field']);
      if (f.contains('"name')) layout['text-field'] = ['get', 'name'];
    }
  }
  return Style(theme: ThemeReader().read(json), providers: base.providers, sprites: base.sprites);
}

/// Dossier du cache des tuiles dessinées, un par thème.
Future<Directory> Function() _cacheFolder(bool dark) => () async {
  final d = Directory('${(await getTemporaryDirectory()).path}/carte_${dark ? 'sombre' : 'claire'}');
  return d.create(recursive: true);
};

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
List<(LatLng, double)> chevrons(List<LatLng> p, {double every = _chevronEvery}) {
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

class _WalkNavScreenState extends State<WalkNavScreen> {
  final _map = MapController();
  StreamSubscription<Position>? _gps;
  StreamSubscription<CompassEvent>? _compass;
  Timer? _ticker;
  LatLng? _me;
  double _heading = 0; // lissé
  double? _gpsHeading, _compassHeading;
  bool _follow = true; // carte centrée sur l'usager
  // nord en haut par défaut : avec ce moteur, les noms de rue tournent avec la carte
  bool _headingUp = false; // carte orientée dans ma direction (sinon nord en haut)
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
    _gps =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1),
        ).listen((p) {
          _me = LatLng(p.latitude, p.longitude);
          _gpsHeading = p.speed >= _gpsHeadingSpeed && p.heading >= 0 ? p.heading : null;
          _update();
        }, onError: (e) => setState(() => _error = 'Localisation indisponible : $e'));
    // boussole absente sur certains téléphones : direction GPS seule
    _compass = FlutterCompass.events?.listen((e) {
      _compassHeading = e.heading;
      if (_gpsHeading == null) _update();
    });
  }

  /// Nouvelle position ou orientation : cap lissé, carte recentrée et tournée.
  void _update() {
    final raw = _gpsHeading ?? _compassHeading;
    if (raw != null) {
      // lissage angulaire (évite que la carte tremble)
      final diff = ((raw - _heading + 540) % 360) - 180;
      _heading = (_heading + diff * 0.25 + 360) % 360;
    }
    if (_me != null && _follow) {
      _map.moveAndRotate(_me!, _map.camera.zoom < 15 ? 17 : _map.camera.zoom, _headingUp ? -_heading : 0);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _gps?.cancel();
    _compass?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final me = _me;
    final path = me == null ? widget.path : remainingPath(widget.path, me);
    final left = me == null ? pathLength(widget.path) : pathLength(path);
    final arrived = me != null && left < 20;
    return Scaffold(
      appBar: AppBar(title: Text('Vers ${widget.target}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          _banner(context, left, arrived),
          Expanded(
            child: Stack(
              children: [
                FutureBuilder(
                  future: _style(dark),
                  builder: (context, snap) => snap.connectionState != ConnectionState.done
                      ? const Center(child: CircularProgressIndicator())
                      : _mapView(context, snap.data, path, dark),
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
                          setState(() => _headingUp = !_headingUp);
                          if (!_headingUp) _map.rotate(0);
                          _update();
                        },
                        child: Transform.rotate(
                          angle: (_headingUp ? -_heading : 0) * math.pi / 180,
                          child: Icon(_headingUp ? Icons.navigation : Icons.explore),
                        ),
                      ),
                      if (!_follow) ...[
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'centre',
                          tooltip: 'Recentrer sur moi',
                          onPressed: () {
                            setState(() => _follow = true);
                            _update();
                          },
                          child: const Icon(Icons.my_location),
                        ),
                      ],
                    ],
                  ),
                ),
                const Positioned(
                  left: 6,
                  bottom: 4,
                  child: Text(
                    '© OpenFreeMap © OpenMapTiles © OpenStreetMap',
                    style: TextStyle(fontSize: 9, color: Colors.grey),
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
    final late = spare != null && spare < 60;
    final lines = <String>[
      if (_error != null)
        _error!
      else if (_me == null)
        'Recherche de votre position…'
      else if (arrived)
        'Vous êtes à ${widget.target}.'
      else
        '${widget.target} : ${distanceLabel(left)} · ${duration(walkSec)} à pied',
      if (dep != null)
        '${widget.lineCode ?? 'Départ'} à ${hhmm(dep)}'
            '${dep > now ? ' (dans ${duration(dep - now)})' : ' (parti)'}'
            '${late && !arrived && dep > now ? ' · pressez le pas' : ''}',
    ];
    return Container(
      width: double.infinity,
      color: late && !arrived ? Colors.orange.shade800 : scheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lines.first,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: late && !arrived ? Colors.white : scheme.onSecondaryContainer),
          ),
          if (lines.length > 1)
            Text(lines[1], style: TextStyle(color: late && !arrived ? Colors.white : scheme.onSecondaryContainer)),
        ],
      ),
    );
  }

  Widget _mapView(BuildContext context, Style? style, List<LatLng> path, bool dark) {
    final me = _me;
    final start = me ?? (widget.path.isNotEmpty ? widget.path.first : const LatLng(48.85, 2.35));
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: start,
        initialZoom: 17,
        maxZoom: 19,
        // l'usager déplace la carte : on arrête de la recentrer (bouton pour reprendre)
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && _follow) setState(() => _follow = false);
        },
      ),
      children: [
        if (style != null)
          VectorTileLayer(
            tileProviders: style.providers,
            theme: style.theme,
            sprites: style.sprites,
            maximumZoom: 19,
            layerMode: VectorTileLayerMode.raster,
            // tuiles dessinées gardées à part pour chaque thème (sinon des tuiles sombres en mode clair)
            // (le type Directory de la bibliothèque est celui de dart:io sur Android)
            cacheFolder: _cacheFolder(dark) as dynamic,
          )
        else
          // style vectoriel indisponible : carte habituelle
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'fr.applitransport.app',
            tileBuilder: dark ? darkModeTileBuilder : null,
          ),
        if (path.length >= 2)
          PolylineLayer(
            polylines: [
              // ma position → chemin : trait gris fin (ce n'est pas un chemin par les rues)
              Polyline(points: path.sublist(0, 2), color: Colors.grey, strokeWidth: 2),
              Polyline(
                points: path.sublist(1),
                color: Colors.blue.shade600,
                strokeWidth: 6,
                borderColor: Colors.white,
                borderStrokeWidth: 1.5,
                pattern: const StrokePattern.dotted(spacingFactor: 1.6),
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            // chevrons de direction : tournent avec la carte
            for (final (p, cap) in chevrons(path.sublist(1)))
              Marker(
                point: p,
                width: 22,
                height: 22,
                child: Transform.rotate(
                  angle: cap * math.pi / 180,
                  child: Icon(Icons.keyboard_arrow_up, size: 22, color: Colors.blue.shade900),
                ),
              ),
            if (widget.path.isNotEmpty)
              Marker(
                point: widget.path.last,
                width: 36,
                height: 36,
                alignment: Alignment.topCenter,
                child: Icon(Icons.location_on, size: 36, color: Colors.green.shade700),
              ),
            if (me != null)
              Marker(
                point: me,
                width: 40,
                height: 40,
                // flèche de l'usager : dans sa direction, quelle que soit l'orientation de la carte
                child: Transform.rotate(
                  angle: _heading * math.pi / 180,
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.navigation, color: Colors.blue, size: 30),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
