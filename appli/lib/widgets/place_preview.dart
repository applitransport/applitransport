// Aperçu d'un itinéraire avant la recherche : départ, arrivée, trait droit et distance à vol
// d'oiseau. Sert à vérifier que c'est le bon lieu avant de consommer une requête PRIM.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/track.dart' show distanceMeters;
import '../poc/nearby.dart' show distanceLabel;
import 'simple_map.dart';

class PlacePreview extends StatelessWidget {
  const PlacePreview({super.key, required this.from, required this.to, this.me});
  final LatLng from, to;

  /// Position de l'usager (point bleu), si connue.
  final LatLng? me;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = distanceMeters(from, to);
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
            builder: (context, box) => SimpleMap(
              key: ValueKey('$from>$to>${box.maxHeight.round()}'),
              padding: const EdgeInsets.fromLTRB(40, 60, 40, 30),
              traces: [
                MapTrace([from, to], color: scheme.primary, width: 3, dashed: true),
              ],
              dots: [if (me case final p?) MapDot(p, color: Colors.blue, radius: 7)],
              flags: [
                MapFlag(from, 'Départ', background: scheme.inverseSurface, foreground: scheme.onInverseSurface),
                MapFlag(to, 'Arrivée', background: Colors.green.shade700),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
