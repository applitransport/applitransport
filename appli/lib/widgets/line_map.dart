// Carte OpenStreetMap d'un sens de ligne : tracés de ses variantes, arrêts, votre arrêt, les bus
// et, à la demande, votre position GPS.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../poc/data.dart';

class MapBus {
  const MapBus({required this.id, required this.position, required this.selected, required this.realtime});
  final String id; // « variante/course »
  final LatLng position;
  final bool selected, realtime;
}

class LineMap extends StatefulWidget {
  const LineMap({
    super.key,
    required this.shapes,
    required this.stops,
    required this.color,
    this.myStop,
    this.buses = const [],
    this.onBusTap,
  });

  final List<List<LatLng>> shapes;
  final List<Stop> stops;
  final Color color;
  final Stop? myStop;
  final List<MapBus> buses;
  final void Function(String busId)? onBusTap;

  @override
  State<LineMap> createState() => _LineMapState();
}

class _LineMapState extends State<LineMap> {
  final _controller = MapController();
  StreamSubscription<Position>? _gps;
  LatLng? _me;
  bool _locating = false;

  @override
  void dispose() {
    _gps?.cancel();
    super.dispose();
  }

  /// Demande la position du téléphone, la suit ensuite et centre la carte dessus.
  Future<void> _locate() async {
    if (_me != null) {
      _controller.move(_me!, 15);
      return;
    }
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'localisation désactivée sur l\'appareil';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'permission refusée';
      final pos = await Geolocator.getCurrentPosition();
      setState(() => _me = LatLng(pos.latitude, pos.longitude));
      _controller.move(_me!, 15);
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((p) => setState(() => _me = LatLng(p.latitude, p.longitude)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Position indisponible : $e')));
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = widget.shapes.where((s) => s.length >= 2).toList();
    if (lines.isEmpty) lines.add([for (final s in widget.stops) s.pos]);
    final mine = widget.myStop;
    final color = widget.color;
    return Stack(children: [
      FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints([for (final l in lines) ...l]), padding: const EdgeInsets.all(24)),
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'fr.applitransport.app',
            // mode sombre : fond de carte assombri
            tileBuilder: dark ? darkModeTileBuilder : null,
          ),
          PolylineLayer(polylines: [
            for (final l in lines) Polyline(points: l, color: color.withValues(alpha: 0.85), strokeWidth: 5),
          ]),
          CircleLayer(circles: [
            for (final s in widget.stops)
              CircleMarker(point: s.pos, radius: 4, color: scheme.surface, borderColor: color, borderStrokeWidth: 2),
          ]),
          if (mine != null)
            MarkerLayer(markers: [
              Marker(
                point: mine.pos,
                width: 120,
                height: 46,
                alignment: Alignment.topCenter,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(3)),
                    child: Text('Votre arrêt', style: TextStyle(color: scheme.onInverseSurface, fontSize: 11)),
                  ),
                  Icon(Icons.location_on, color: scheme.inverseSurface, size: 24),
                ]),
              ),
            ]),
          MarkerLayer(markers: [
            for (final b in [...widget.buses]..sort((a, b) => a.selected ? 1 : (b.selected ? -1 : 0)))
              Marker(
                point: b.position,
                width: b.selected ? 38 : 26,
                height: b.selected ? 38 : 26,
                child: GestureDetector(
                  onTap: widget.onBusTap == null ? null : () => widget.onBusTap!(b.id),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: b.realtime ? color : Colors.grey,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: b.selected ? scheme.onSurface : Colors.white, width: b.selected ? 3 : 2),
                      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
                    ),
                    child: Icon(Icons.directions_bus, color: Colors.white, size: b.selected ? 20 : 14),
                  ),
                ),
              ),
          ]),
          // votre position : point bleu
          if (_me != null)
            MarkerLayer(markers: [
              Marker(
                point: _me!,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
                  ),
                ),
              ),
            ]),
          const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
        ],
      ),
      Positioned(
        top: 8,
        right: 8,
        child: FloatingActionButton.small(
          heroTag: null,
          tooltip: 'Ma position',
          onPressed: _locating ? null : _locate,
          child: _locating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(_me == null ? Icons.my_location_outlined : Icons.my_location),
        ),
      ),
    ]);
  }
}
