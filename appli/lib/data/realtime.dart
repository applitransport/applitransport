// Lecture des réponses SIRI de PRIM et rattachement aux courses des horaires téléchargés.
//
// Rattachement : par numéro de course quand il figure dans l'identifiant GTFS (bus), sinon par
// arrêt + heure prévue (trains SNCF, dont les identifiants ne correspondent pas aux horaires).
import '../poc/data.dart';

const _staleAfter = Duration(minutes: 15); // course sans nouvelles : donnée périmée (bus fantôme)

class RtCall {
  RtCall(this.stopId, this.aimed, this.expected, this.status);
  final String? stopId;
  final DateTime? aimed, expected;
  final String status; // ON_TIME, DELAYED, EARLY, CANCELLED, NO_REPORT, ARRIVED…
}

class RtJourney {
  RtJourney(this.ref, this.lineRef, this.recordedAt, this.cancelled, this.calls);
  final String ref, lineRef;
  final DateTime? recordedAt;
  final bool cancelled;
  final List<RtCall> calls;

  /// « 529FSQY:VehicleJourney::8747417:LOC » → « 8747417 »
  String get number {
    final parts = ref.split(':').where((p) => p.isNotEmpty).toList();
    return parts.length >= 2 ? parts[parts.length - 2] : ref;
  }
}

/// Identifiant SIRI d'arrêt → identifiant GTFS : quai de bus ou gare SNCF.
String? gtfsStopId(String ref) {
  final p = ref.split(':');
  if (ref.startsWith('STIF:StopPoint:Q:') && p.length > 3) return 'IDFM:${p[3]}';
  if (ref.startsWith('STIF:StopArea:SP:') && p.length > 3) return 'IDFM:monomodalStopPlace:${p[3]}';
  return null; // identifiant propre à l'exploitant (ex. terminus Gare de Trappes)
}

DateTime? _time(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();
String _value(dynamic v) => v is Map ? (v['value'] ?? '') as String : (v ?? '') as String;

RtCall _call(Map<String, dynamic> c, [String? stopRef]) => RtCall(
      gtfsStopId(stopRef ?? _value(c['StopPointRef'])),
      _time(c['AimedDepartureTime'] ?? c['AimedArrivalTime']),
      _time(c['ExpectedDepartureTime'] ?? c['ExpectedArrivalTime']),
      ((c['DepartureStatus'] ?? c['ArrivalStatus'] ?? '') as String).toUpperCase(),
    );

/// Requête « ligne » : courses en circulation, avec leurs arrêts restants (non triés).
List<RtJourney> parseEstimatedTimetable(Map<String, dynamic> data) => [
      for (final d in (data['Siri']?['ServiceDelivery']?['EstimatedTimetableDelivery'] ?? const []) as List)
        for (final f in (d['EstimatedJourneyVersionFrame'] ?? const []) as List)
          for (final j in (f['EstimatedVehicleJourney'] ?? const []) as List)
            RtJourney(
              _value(j['DatedVehicleJourneyRef']),
              _value(j['LineRef']),
              _time(j['RecordedAtTime']),
              j['Cancellation'] == true,
              [for (final c in (j['EstimatedCalls']?['EstimatedCall'] ?? const []) as List) _call(c)],
            ),
    ];

/// Requête « arrêt » : un passage par course, à l'arrêt interrogé.
List<RtJourney> parseStopMonitoring(Map<String, dynamic> data) => [
      for (final d in (data['Siri']?['ServiceDelivery']?['StopMonitoringDelivery'] ?? const []) as List)
        for (final v in (d['MonitoredStopVisit'] ?? const []) as List)
          RtJourney(
            _value(v['MonitoredVehicleJourney']?['FramedVehicleJourneyRef']?['DatedVehicleJourneyRef']),
            _value(v['MonitoredVehicleJourney']?['LineRef']),
            _time(v['RecordedAtTime']),
            v['MonitoredVehicleJourney']?['Cancellation'] == true,
            [_call((v['MonitoredVehicleJourney']?['MonitoredCall'] ?? const {}) as Map<String, dynamic>,
                _value(v['MonitoringRef']))],
          ),
    ];

/// Temps réel d'une course : retard connu à certains arrêts, prochain arrêt, suppressions.
class TripRealtime {
  TripRealtime(this.known, this.stopCount, {this.nextIndex, this.cancelled = false, this.cancelledStops = const {}});

  /// Retard (s) aux arrêts où PRIM en donne un (index d'arrêt dans la variante).
  final Map<int, int> known;
  final int stopCount;

  /// Premier arrêt pas encore desservi (requête « ligne » seulement : elle ne liste que les arrêts restants).
  final int? nextIndex;
  final bool cancelled;
  final Set<int> cancelledStops;

  /// Retard à chaque arrêt : celui de l'arrêt connu suivant, sinon du précédent.
  late final List<int> delays = () {
    final out = List<int?>.filled(stopCount, null);
    int? next;
    for (var i = stopCount - 1; i >= 0; i--) {
      next = known[i] ?? next;
      out[i] = next;
    }
    int? prev;
    for (var i = 0; i < stopCount; i++) {
      prev = known[i] ?? prev;
      out[i] ??= prev;
    }
    return [for (final d in out) d ?? 0];
  }();

  int delayAt(int i) => delays[i];
  bool passed(int i) => nextIndex != null && i < nextIndex!;
}

/// Temps réel d'une étape d'itinéraire, lu au départ de l'étape (requête « arrêt »).
class StepRealtime {
  const StepRealtime(this.delay, this.cancelled);
  final int delay;
  final bool cancelled;
}

/// Passage d'une ligne à un arrêt, prévu à [aimedSec] (s depuis minuit de [day]), dans une réponse
/// « arrêt » : rattaché par ligne et heure prévue (à 90 s près).
StepRealtime? findStep(List<RtJourney> journeys, String lineCode, int aimedSec, DateTime day) {
  final midnight = DateTime(day.year, day.month, day.day);
  for (final j in journeys) {
    if (!j.lineRef.contains(lineCode)) continue;
    for (final c in j.calls) {
      if (c.aimed == null || (c.aimed!.difference(midnight).inSeconds - aimedSec).abs() > 90) continue;
      final cancelled = j.cancelled || c.status == 'CANCELLED';
      if (c.status == 'NO_REPORT' || c.expected == null) return cancelled ? const StepRealtime(0, true) : null;
      return StepRealtime(c.expected!.difference(c.aimed!).inSeconds, cancelled);
    }
  }
  return null;
}

/// Clé d'une course dans les horaires du jour : « sens/variante/course ».
String tripKey(int direction, int variant, int trip) => '$direction/$variant/$trip';

/// Rattache les courses temps réel aux horaires d'une ligne pour le jour de service [day].
/// [remaining] : la réponse ne liste que les arrêts restants (requête « ligne »).
Map<String, TripRealtime> matchToTimetable(DemoLine line, List<RtJourney> journeys, DateTime day, DateTime now,
    {required bool remaining}) {
  final midnight = DateTime(day.year, day.month, day.day);
  int secOf(DateTime t) => t.difference(midnight).inSeconds;
  final nowSec = secOf(now);
  final code = line.id;

  // index : numéro de course → clé ; quai → [(heure, clé)]
  final byNumber = <String, (int, int, int)>{};
  final byStop = <String, List<(int, (int, int, int))>>{};
  for (final d in line.directions) {
    for (var v = 0; v < d.variants.length; v++) {
      final variant = d.variants[v];
      for (var t = 0; t < variant.trips.length; t++) {
        if (t < variant.tripIds.length) byNumber[variant.tripIds[t].split('-').last] = (d.id, v, t);
        for (var i = 0; i < variant.stops.length; i++) {
          byStop.putIfAbsent(variant.stops[i].id, () => []).add((variant.trips[t][i], (d.id, v, t)));
        }
      }
    }
  }

  (int, int, int)? byTime(RtJourney j) {
    final votes = <(int, int, int), int>{};
    for (final c in j.calls) {
      if (c.stopId == null || c.aimed == null) continue;
      final s = secOf(c.aimed!);
      for (final (sec, key) in byStop[c.stopId] ?? const <(int, (int, int, int))>[]) {
        if ((sec - s).abs() <= 60) votes[key] = (votes[key] ?? 0) + 1;
      }
    }
    if (votes.isEmpty) return null;
    return votes.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  final out = <String, TripRealtime>{};
  for (final j in journeys) {
    if (!j.lineRef.contains(code)) continue;
    final key = byNumber[j.number] ?? byTime(j);
    if (key == null) continue;
    final (dir, v, t) = key;
    final variant = line.directions.firstWhere((d) => d.id == dir).variants[v];
    // course censée rouler mais sans nouvelles depuis longtemps : on l'ignore
    if (remaining && j.recordedAt != null && variant.trips[t].first < nowSec && now.difference(j.recordedAt!) > _staleAfter) {
      continue;
    }
    final known = <int, int>{};
    final cancelledStops = <int>{};
    for (final c in j.calls) {
      final i = variant.stops.indexWhere((s) => s.id == c.stopId);
      if (i < 0) continue;
      if (c.status == 'CANCELLED') cancelledStops.add(i);
      // « pas d'information » : l'heure annoncée n'est que l'horaire théorique
      if (c.status == 'NO_REPORT' || c.aimed == null || c.expected == null) continue;
      known[i] = c.expected!.difference(c.aimed!).inSeconds;
    }
    final cancelled = j.cancelled || (cancelledStops.isNotEmpty && cancelledStops.length == j.calls.length);
    if (known.isEmpty && !cancelled && cancelledStops.isEmpty) continue; // rien de réel sur cette course
    final indexes = [for (final c in j.calls) variant.stops.indexWhere((s) => s.id == c.stopId)].where((i) => i >= 0);
    out[tripKey(dir, v, t)] = TripRealtime(
      known,
      variant.stops.length,
      nextIndex: remaining && indexes.isNotEmpty ? indexes.reduce((a, b) => a < b ? a : b) : null,
      cancelled: cancelled,
      cancelledStops: cancelledStops,
    );
  }
  return out;
}
