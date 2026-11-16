// Aperçu d'un itinéraire avant la recherche : départ, arrivée, trait droit et distance à vol
// d'oiseau. Sert à vérifier que c'est le bon lieu avant de consommer une requête PRIM.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/track.dart' show distanceMeters;
import '../poc/nearby.dart' show distanceLabel;

class PlacePreview extends StatelessWidget {
  const PlacePreview({super.key, required this.from, required this.to, this.me});
  final LatLng from, to;

  /// Position de l'usager (point bleu), si connue.
  final LatLng? me;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final d = distanceMeters(from, to);
    Marker flag(LatLng p, String label, Color bg, Color fg) => Marker(
      point: p,
      width: 120,
      height: 46,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
            child: Text(label, style: TextStyle(color: fg, fontSize: 11)),
          ),
          Icon(Icons.location_on, color: bg, size: 24),
        ],
      ),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text(
            'À vol d\'oiseau : ${distanceLabel(d)} · appuyez sur Rechercher pour le trajet',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          // recadrage quand la taille change (clavier qui se ferme) : la carte est recréée
          child: LayoutBuilder(
            builder: (context, box) => FlutterMap(
              key: ValueKey('$from>$to>${box.maxHeight.round()}'),
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints([from, to, ?me]),
                  padding: const EdgeInsets.fromLTRB(40, 60, 40, 30),
                  maxZoom: 16,
                ),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'fr.applitransport.app',
                  tileBuilder: dark ? darkModeTileBuilder : null,
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [from, to],
                      color: scheme.primary,
                      strokeWidth: 3,
                      pattern: StrokePattern.dashed(segments: const [10, 8]),
                    ),
                  ],
                ),
                if (me != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: me!,
                        radius: 7,
                        color: Colors.blue,
                        borderColor: Colors.white,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    flag(from, 'Départ', scheme.inverseSurface, scheme.onInverseSurface),
                    flag(to, 'Arrivée', Colors.green.shade700, Colors.white),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
