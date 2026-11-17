// Éléments d'interface des trajets « à bord », partagés par le suivi de ligne et l'état de la ligne :
// bandeau du trajet en cours, demande de participation, « Je suis à bord » (choix de la course).
import 'package:flutter/material.dart';
import '../data/geo.dart';
import 'package:latlong2/latlong.dart';

import '../data/location.dart';
import '../data/ride.dart';
import '../data/ride_session.dart';
import '../poc/app_state.dart';
import '../poc/data.dart';
import '../poc/line_vehicles.dart';
import '../poc/position.dart';
import '../poc/ride_control.dart';

void _tell(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// Active la participation : elle exige la localisation, en position précise. Message en cas d'échec.
Future<bool> enableParticipation(BuildContext context, AppState app) async {
  String? problem;
  try {
    await ensureLocationPermission();
    if (await preciseLocationDenied()) {
      problem =
          'La participation demande la position exacte : réglages Android de l\'appli › Position › '
          'Utiliser la position exacte.';
    }
  } catch (e) {
    problem = 'La participation demande la localisation : $e';
  }
  if (problem != null) {
    if (context.mounted) _tell(context, problem);
    return false;
  }
  app.setCommunityShare(true);
  return true;
}

/// « Ma position sur la carte » : permission demandée ici, une fois.
Future<void> setShowMyPosition(BuildContext context, AppState app, bool on) async {
  if (!on) return app.setShowMyPosition(false);
  try {
    await ensureLocationPermission();
    app.setShowMyPosition(true);
  } catch (e) {
    if (context.mounted) _tell(context, 'Position indisponible : $e');
  }
}

/// Avant un envoi : serveur renseigné et participation acceptée (demandée si elle est désactivée).
Future<bool> ensureParticipation(BuildContext context, AppState app, {String what = 'ce signalement'}) async {
  if (!app.community.configured) {
    _tell(context, 'Renseignez l\'adresse du serveur communautaire dans Configuration › Général.');
    return false;
  }
  if (app.communityShare) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Participer ?'),
      content: Text(
        'Activer la participation pour envoyer $what ?\n\n'
        'La localisation (position exacte) est alors utilisée pendant vos trajets à bord. '
        'Seuls sont envoyés la position du véhicule, recalée sur la ligne, et vos signalements, avec un '
        'identifiant tiré au hasard. Aucun compte, aucune donnée personnelle. '
        'Désactivable dans Configuration › Général.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Activer')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  return enableParticipation(context, app);
}

/// « À bord » sans bus choisi : on ne monte que si l'association est sûre, c'est-à-dire un seul bus
/// du sens [dirIndex] à moins de 400 m de l'usager, lui-même à moins de 60 m du tracé. Sinon :
/// « Touchez votre bus sur la carte ».
Future<void> boardNearest(BuildContext context, AppState app, DemoLine l, int dirIndex) async {
  if (!await ensureParticipation(context, app, what: 'votre position pendant ce trajet')) return;
  if (!context.mounted) return;
  final me = await _preciseFix(context);
  if (me == null || !context.mounted) return;
  final d = l.directions[dirIndex], word = vehicleWord(l.type);
  final found = aboardCandidates(
    d,
    me,
    app.nowSec(),
    crowd: crowdEstimates(app, l, d),
    rt: (v, t) => app.rt(l.id, d.id, v, t),
  );
  if (!found.onTrack) return _tell(context, 'Vous n\'êtes pas sur le tracé de ce sens (→ ${d.label}).');
  final near = [
    for (final c in found.candidates)
      if (c.gap <= boardMaxGap) c,
  ];
  if (near.length != 1) {
    return _tell(
      context,
      near.isEmpty
          ? 'Aucun $word de ce sens à moins de 400 m de vous : touchez votre $word sur la carte.'
          : 'Plusieurs ${vehicleWord(l.type, plural: true)} près de vous : touchez le vôtre sur la carte.',
    );
  }
  final c = near.single;
  try {
    await beginRide(app, l, dirIndex, variant: c.v, trip: c.t, startAlong: c.along, label: tripName(l, d, c.v, c.t));
  } catch (e) {
    if (context.mounted) _tell(context, 'Position indisponible : $e');
  }
}

/// Position précise du téléphone, ou null (message affiché) si indisponible ou trop imprécise.
Future<LatLng?> _preciseFix(BuildContext context) async {
  final Position pos;
  try {
    await ensureLocationPermission();
    pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).timeout(const Duration(seconds: 30));
  } catch (e) {
    if (context.mounted) _tell(context, 'Position indisponible : $e');
    return null;
  }
  if (!context.mounted) return null;
  if (pos.accuracy > const RideThresholds().maxAccuracy) {
    _tell(context, 'GPS trop imprécis (± ${pos.accuracy.round()} m) : réessayez dans un instant.');
    return null;
  }
  return LatLng(pos.latitude, pos.longitude);
}

/// « À bord » du bus choisi sur la carte (course [trip] de la variante [variant], sens [dirIndex]) :
/// sur le tracé à 60 m près et à moins de 400 m du bus ; position seulement théorique et plus loin :
/// confirmation ; position connue (voyageur, PRIM) et plus loin : refusé.
Future<void> boardSelected(BuildContext context, AppState app, DemoLine l, int dirIndex, int variant, int trip) async {
  if (!await ensureParticipation(context, app, what: 'votre position pendant ce trajet')) return;
  if (!context.mounted) return;
  final me = await _preciseFix(context);
  if (me == null || !context.mounted) return;
  final d = l.directions[dirIndex], v = d.variants[variant], word = vehicleWord(l.type);
  final seen = crowdEstimates(app, l, d)['$variant/$trip'];
  final rt = app.rt(l.id, d.id, variant, trip);
  final busAt = seen != null
      ? LatLng(seen.vehicle.lat, seen.vehicle.lon)
      : busStatus(v, trip, app.nowSec(), rt)?.position;
  if (busAt == null) return _tell(context, 'Ce $word n\'est pas en circulation.');
  final r = boardCheck(v, me, busAt, theoretical: seen == null && rt == null);
  switch (r.check) {
    case BoardCheck.offLine:
      return _tell(context, 'Vous n\'êtes pas sur cette ligne (à plus de 60 m de son tracé).');
    case BoardCheck.tooFar:
      return _tell(context, 'Ce $word est à ${r.gap.round()} m de vous : êtes-vous dans un autre $word ?');
    case BoardCheck.confirm:
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${capitalized(word)} plus loin que prévu'),
          content: Text(
            'D\'après l\'horaire, ce $word devrait être à ${r.gap.round()} m de vous. '
            'Confirmez-vous être dedans ?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Oui, j\'y suis')),
          ],
        ),
      );
      if (ok != true) return;
    case BoardCheck.ok:
  }
  if (!context.mounted) return;
  try {
    await beginRide(
      app,
      l,
      dirIndex,
      variant: variant,
      trip: trip,
      startAlong: r.along,
      label: tripName(l, d, variant, trip),
    );
  } catch (e) {
    if (context.mounted) _tell(context, 'Position indisponible : $e');
  }
}

/// Bandeau du trajet en cours, sur une ligne : course et état en bref ; ⓘ ouvre le détail. [onTap] :
/// action d'un appui (suivi de ligne : ouvrir l'état de la ligne, où se trouve « Sorti »).
class RideBanner extends StatelessWidget {
  const RideBanner({super.key, required this.app, this.onTap});
  final AppState app;
  final VoidCallback? onTap;

  /// État détaillé : où l'on est sur la ligne, ou pourquoi le dernier point est ignoré.
  static String status(AppState app, RideSession ride) {
    final tr = ride.tracker, last = ride.lastSample;
    final l = app.timetable(ride.lineId);
    final v = l != null && ride.direction < l.directions.length
        ? l.directions[ride.direction].variants[ride.variant]
        : null;
    if (tr.ended != null) return 'Trajet terminé : ${endLabel(tr.ended!)}.';
    if (ride.error != null) return 'Localisation : ${ride.error}';
    if (last == null || (tr.accepted == 0 && last.verdict == SampleVerdict.poorAccuracy)) {
      return 'En attente d\'une position précise…';
    }
    if (last.verdict == SampleVerdict.notAtStop) return 'Vous ne semblez pas être à ${ride.boardStop}.';
    if (!last.accepted) return 'Point ignoré : ${verdictLabel(last.verdict)}.';
    final speed = last.speedKmh == null ? '' : ', ${last.speedKmh!.round()} km/h';
    return '${v == null ? '' : 'Entre ${v.stops[last.prevStop].name} et ${v.stops[last.nextStop].name} '
              '(${(last.progression * 100).round()} %), '}à ${last.projection!.offset.round()} m du tracé$speed.';
  }

  /// État en quelques mots, pour le bandeau.
  static String brief(RideSession ride) {
    final tr = ride.tracker, last = ride.lastSample;
    if (tr.ended != null) return 'terminé';
    if (ride.error != null) return 'localisation indisponible';
    if (last == null || (tr.accepted == 0 && last.verdict == SampleVerdict.poorAccuracy)) return 'attente position';
    if (last.verdict == SampleVerdict.notAtStop) return 'loin de l\'arrêt';
    if (ride.shareError != null) return 'envoi refusé';
    return ride.share == null ? 'non partagé' : '${ride.sent} envoi${ride.sent > 1 ? 's' : ''}';
  }

  void _details(BuildContext context) {
    final ride = app.ride!, tr = ride.tracker;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.ended == null ? 'À bord' : 'Trajet terminé'),
        content: SingleChildScrollView(
          child: Text(
            '${ride.label}\n\n'
            '${status(app, ride)}\n\n'
            '${tr.accepted} point(s) accepté(s), ${tr.rejected} ignoré(s).\n'
            '${ride.share == null ? 'Rien n\'est envoyé (participation désactivée).' : '${ride.sent} position(s) envoyée(s).'}'
            '${ride.shareError == null ? '' : '\nDernier refus : ${ride.shareError}'}',
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ride = app.ride!, tr = ride.tracker, scheme = Theme.of(context).colorScheme;
    final ended = tr.ended != null;
    return Material(
      color: ended ? scheme.surfaceContainerHighest : Colors.green.withValues(alpha: 0.15),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              Icon(ended ? Icons.check_circle_outline : Icons.person_pin_circle, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${ended ? 'Trajet terminé' : 'À bord'} : ${ride.label} · ${brief(ride)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(tooltip: 'Détail', onPressed: () => _details(context), icon: const Icon(Icons.info_outline)),
              if (ended)
                IconButton(tooltip: 'Fermer', onPressed: () => app.setRide(null), icon: const Icon(Icons.close)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le trajet en cours porte-t-il sur ce sens de cette ligne ?
bool rideOn(RideSession? ride, String lineId, int dirIndex) =>
    ride != null && ride.active && ride.lineId == lineId && ride.direction == dirIndex;

/// Icône d'un type de signalement.
IconData reportIcon(String type) => switch (type) {
  'retard' => Icons.schedule,
  'incident' => Icons.warning_amber,
  'supprime' => Icons.cancel_outlined,
  'affluence' => Icons.groups,
  _ => Icons.info_outline,
};
