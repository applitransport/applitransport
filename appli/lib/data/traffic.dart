// Perturbations d'une ligne (API Info Trafic v2 de PRIM) : travaux, incidents, ascenseurs.
// La gravité fournie est inutilisable (tout est « retards importants ») : on classe d'après
// l'étiquette et la cause.

enum DisruptionKind { incident, works, accessibility }

class Disruption {
  Disruption({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.periods,
    required this.stopAreas,
    required this.wholeLine,
  });

  final String id;
  final DisruptionKind kind;
  final String title, text;
  final List<(DateTime, DateTime)> periods;

  /// Zones d'arrêt touchées (« IDFM:63923 ») ; [wholeLine] : la ligne elle-même est visée.
  final List<String> stopAreas;
  final bool wholeLine;

  bool activeAt(DateTime t) => periods.any((p) => !t.isBefore(p.$1) && t.isBefore(p.$2));
  bool upcomingAfter(DateTime t) => !activeAt(t) && periods.any((p) => p.$1.isAfter(t));
  DateTime? get firstStart => periods.isEmpty ? null : periods.map((p) => p.$1).reduce((a, b) => a.isBefore(b) ? a : b);
}

/// « 20261029T150900 » (heure de Paris) → DateTime
DateTime? navitiaTime(String? s) {
  if (s == null || s.length < 15) return null;
  return DateTime(int.parse(s.substring(0, 4)), int.parse(s.substring(4, 6)), int.parse(s.substring(6, 8)),
      int.parse(s.substring(9, 11)), int.parse(s.substring(11, 13)), int.parse(s.substring(13, 15)));
}

const _entities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'rsquo': '’', 'eacute': 'é',
  'egrave': 'è', 'agrave': 'à', 'ccedil': 'ç', 'ecirc': 'ê', 'laquo': '«', 'raquo': '»'};

/// Texte HTML des messages → texte simple (sauts de ligne gardés).
String cleanHtml(String html) {
  var s = html.replaceAll(RegExp(r'<br\s*/?>|</p>|</li>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-z]+);'), (m) {
    final e = m[1]!;
    if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
    return _entities[e] ?? m[0]!;
  });
  return s.split('\n').map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim()).where((l) => l.isNotEmpty).join('\n');
}

String _message(Map<String, dynamic> d, bool Function(Map<String, dynamic> channel) wanted) {
  for (final m in (d['messages'] ?? const []) as List) {
    if (wanted((m['channel'] ?? const {}) as Map<String, dynamic>) && (m['text'] ?? '').toString().isNotEmpty) {
      return cleanHtml(m['text']);
    }
  }
  return '';
}

/// Lit une réponse line_reports ; les doublons (même titre et même texte) sont fusionnés.
List<Disruption> parseLineReports(Map<String, dynamic> data) {
  final out = <String, Disruption>{};
  for (final d in (data['disruptions'] ?? const []) as List) {
    if (d['status'] == 'past') continue;
    final tags = [for (final t in (d['tags'] ?? const []) as List) t.toString().toLowerCase()];
    final cause = (d['cause'] ?? '').toString().toLowerCase();
    final title = _message(d, (c) => (c['types'] as List? ?? const []).contains('title'));
    final text = _message(d, (c) => c['name'] == 'moteur' || (c['types'] as List? ?? const []).contains('web'));
    final kind = tags.any((t) => t.contains('ascenseur') || t.contains('escalator')) || title.toLowerCase().contains('ascenseur')
        ? DisruptionKind.accessibility
        : cause.contains('travaux')
            ? DisruptionKind.works
            : DisruptionKind.incident;
    final objects = [for (final o in (d['impacted_objects'] ?? const []) as List) o['pt_object'] ?? const {}];
    final key = '$title|$text';
    final periods = [
      for (final p in (d['application_periods'] ?? const []) as List)
        if (navitiaTime(p['begin']) != null && navitiaTime(p['end']) != null) (navitiaTime(p['begin'])!, navitiaTime(p['end'])!)
    ];
    final previous = out[key];
    out[key] = Disruption(
      id: d['id'],
      kind: kind,
      // ascenseurs : le titre est générique (« Panne d'un ascenseur »), le texte dit où
      title: title.isNotEmpty && !(kind == DisruptionKind.accessibility && text.isNotEmpty)
          ? title
          : (text.split('\n').firstOrNull ?? title),
      text: text,
      periods: [...?previous?.periods, ...periods],
      stopAreas: {
        ...?previous?.stopAreas,
        for (final o in objects)
          if (o['embedded_type'] == 'stop_area') (o['id'] as String).replaceFirst('stop_area:', ''),
      }.toList(),
      wholeLine: (previous?.wholeLine ?? false) || objects.any((o) => o['embedded_type'] == 'line'),
    );
  }
  return out.values.toList();
}
