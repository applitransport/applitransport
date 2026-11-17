// Carte OpenStreetMap d'un sens de ligne : tracés de ses variantes, arrêts, votre arrêt, les bus
// et, à la demande, votre position GPS.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../data/geo.dart';
import 'package:latlong2/latlong.dart';

import '../poc/data.dart';

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

  /// Afficher la position du téléphone (réglage « Ma position sur la carte »), sans bouton.

  /// Arrêts où des voyageurs signalent un incident.

  /// Couleur des véhicules selon leur source : vert = vu par un voyageur, rouge = théorique ou PRIM
  /// (suivi de ligne). Sinon : couleur de la ligne en temps réel, gris en théorique.

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
  final bool confirmationColors;
  final bool showMe;
  final List<LatLng> alertStops;

  @override
  State<LineMap> createState() => _LineMapState();
}

class _LineMapState extends State<LineMap> {
  final _controller = MapController();
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
  }

  @override
  void dispose() {
    _gps?.cancel();
    super.dispose();
  }

  /// Suit la position du téléphone (permission déjà accordée dans les réglages) sans déplacer la carte.
  void _follow() {
    _gps = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((p) => setState(() => _me = LatLng(p.latitude, p.longitude)), onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = widget.shapes.where((s) => s.length >= 2).toList();
    if (lines.isEmpty) lines.add([for (final s in widget.stops) s.pos]);
    final mine = widget.myStop;
    final color = widget.color;
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints([for (final l in lines) ...l]),
              padding: const EdgeInsets.all(24),
            ),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'fr.applitransport.app',
              // mode sombre : fond de carte assombri
              tileBuilder: dark ? darkModeTileBuilder : null,
            ),
            PolylineLayer(
              polylines: [
                for (final l in lines) Polyline(points: l, color: color.withValues(alpha: 0.85), strokeWidth: 5),
              ],
            ),
            CircleLayer(
              circles: [
                for (final s in widget.stops)
                  CircleMarker(
                    point: s.pos,
                    radius: 4,
                    color: scheme.surface,
                    borderColor: color,
                    borderStrokeWidth: 2,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                if (mine != null) _stopFlag(mine, 'Votre arrêt', scheme.inverseSurface, scheme.onInverseSurface),
                if (widget.toStop case final to?) _stopFlag(to, 'Arrivée', Colors.green.shade700, Colors.white),
              ],
            ),
            MarkerLayer(
              markers: [
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
                          color: widget.confirmationColors
                              ? (b.crowd ? Colors.green.shade600 : Colors.red.shade600)
                              : (b.realtime ? color : Colors.grey),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: b.selected ? scheme.onSurface : Colors.white,
                            width: b.selected ? 3 : 2,
                          ),
                          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
                        ),
                        child: Icon(widget.vehicleIcon, color: Colors.white, size: b.selected ? 20 : 14),
                      ),
                    ),
                  ),
              ],
            ),
            // signalé bloqué ou en incident : pastille orange en haut à droite du véhicule
            MarkerLayer(
              markers: [
                for (final b in widget.buses)
                  if (b.alert)
                    Marker(
                      point: b.position,
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      child: IgnorePointer(
                        child: Align(alignment: Alignment.topRight, child: _alertDot(14)),
                      ),
                    ),
                // incident signalé à un arrêt
                for (final p in widget.alertStops)
                  Marker(
                    point: p,
                    width: 22,
                    height: 22,
                    child: IgnorePointer(child: _alertDot(20)),
                  ),
              ],
            ),
            // votre position : point bleu
            if (_me != null)
              MarkerLayer(
                markers: [
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
                ],
              ),
            const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
          ],
        ),
      ],
    );
  }
}

Widget _alertDot(double size) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: Colors.orange.shade700,
    shape: BoxShape.circle,
    border: Border.all(color: Colors.white, width: 1.5),
  ),
  child: Icon(Icons.priority_high, color: Colors.white, size: size * 0.7),
);

/// Repère d'arrêt avec une étiquette (« Votre arrêt », « Arrivée »).
Marker _stopFlag(Stop stop, String label, Color background, Color foreground) => Marker(
  point: stop.pos,
  width: 120,
  height: 46,
  alignment: Alignment.topCenter,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(3)),
        child: Text(label, style: TextStyle(color: foreground, fontSize: 11)),
      ),
      Icon(Icons.location_on, color: background, size: 24),
    ],
  ),
);
