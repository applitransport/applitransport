// Lieux d'Île-de-France (OpenStreetMap) sur l'appareil : base SQLite publiée chaque semaine par l'usine
// (lieux/lieux.db.xz), téléchargée à la demande. Recherche plein texte (FTS5), sans connexion et sans
// rien envoyer.
//
//   <dossier>/lieux.db     base décompressée (≈ 28 Mo)
//   <dossier>/lieux.json   description de la base installée (date, nombre, empreinte)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show XZDecoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart';

/// Un lieu trouvé dans la base.
class LocalPlace {
  const LocalPlace({
    required this.name,
    required this.kind,
    required this.address,
    required this.town,
    required this.pos,
  });
  final String name, kind, address, town;
  final LatLng pos;

  /// « boulangerie · 12 Rue X, Montigny-le-Bretonneux ».
  String get detail => [
    kind,
    [address, town].where((x) => x.isNotEmpty).join(', '),
  ].where((x) => x.isNotEmpty).join(' · ');
}

/// Minuscules sans accents ni ponctuation, mots séparés par des espaces.
String normalizeWords(String s) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final b = StringBuffer();
  for (final c in s.toLowerCase().runes) {
    final ch = String.fromCharCode(c);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : (RegExp(r'[a-z0-9]').hasMatch(ch) ? ch : ' '));
  }
  return b.toString().split(' ').where((w) => w.isNotEmpty).join(' ');
}

/// Note d'un résultat (plus petit = meilleur) : pertinence et importance données par la base, distance,
/// et bonus quand les mots tapés sont des mots entiers du nom ou du type.
double placeScore({
  required double base,
  required double km,
  required String name,
  required String kind,
  required List<String> words,
}) {
  final nw = normalizeWords(name).split(' '), tw = normalizeWords(kind).split(' ');
  var bonus = 0.0;
  for (final w in words) {
    bonus += nw.contains(w) ? 4 : (tw.contains(w) ? 3 : 0);
  }
  if (nw.join(' ') == words.join(' ')) bonus += 4; // nom exact
  if (tw.join(' ') == words.join(' ')) bonus += 6; // catégorie seule (« pharmacie ») : la plus proche
  return base + 2 * math.log(0.3 + km) / math.ln10 - bonus;
}

Uint8List _unxz(Uint8List data) => XZDecoder().decodeBytes(data);

class PlacesStore {
  PlacesStore(this.dir, this.baseUrl, {http.Client? client}) : _client = client ?? http.Client() {
    _readMeta();
  }

  final Directory dir;

  /// Adresse de la publication (se termine par « / »), lue à chaque appel (réglable).
  final String Function() baseUrl;
  final http.Client _client;
  Database? _db;
  Map<String, dynamic>? meta;

  File get _dbFile => File('${dir.path}/lieux.db');
  File get _metaFile => File('${dir.path}/lieux.json');

  bool get installed => meta != null && _dbFile.existsSync();

  /// Date de la base installée.
  DateTime? get date => meta == null ? null : DateTime.tryParse(meta!['date'] ?? '');

  void _readMeta() {
    try {
      meta = _metaFile.existsSync() ? jsonDecode(_metaFile.readAsStringSync()) as Map<String, dynamic> : null;
    } catch (_) {
      meta = null;
    }
  }

  Database? get _open {
    if (!installed) return null;
    return _db ??= sqlite3.open(_dbFile.path, mode: OpenMode.readOnly);
  }

  /// Description de la base publiée (date, nombre, taille, empreinte), ou null sans réseau.
  Future<Map<String, dynamic>?> remote() async {
    try {
      final r = await _client.get(Uri.parse('${baseUrl()}lieux/lieux.json')).timeout(const Duration(seconds: 15));
      return r.statusCode == 200 ? jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }

  /// Une base plus récente est-elle publiée ?
  Future<bool> outdated() async {
    final m = await remote();
    return m != null && m['sha256'] != meta?['sha256'];
  }

  /// Télécharge et installe la base publiée. [onProgress] : octets reçus, total (ou null).
  Future<void> download({void Function(int received, int? total)? onProgress}) async {
    final m = await remote();
    if (m == null) throw const HttpException('lieux : publication introuvable');
    final req = http.Request('GET', Uri.parse('${baseUrl()}lieux/lieux.db.xz'));
    final resp = await _client.send(req);
    if (resp.statusCode != 200) throw HttpException('lieux : HTTP ${resp.statusCode}');
    final total = resp.contentLength;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in resp.stream) {
      bytes.add(chunk);
      onProgress?.call(bytes.length, total);
    }
    final data = bytes.takeBytes();
    if (sha256.convert(data).toString() != m['sha256']) throw const FormatException('lieux : fichier altéré');
    final db = await compute(_unxz, data);
    final tmp = File('${_dbFile.path}.tmp');
    await tmp.writeAsBytes(db, flush: true);
    _db?.dispose();
    _db = null;
    await tmp.rename(_dbFile.path);
    await _metaFile.writeAsString(jsonEncode(m));
    meta = m;
  }

  Future<void> remove() async {
    _db?.dispose();
    _db = null;
    if (await _dbFile.exists()) await _dbFile.delete();
    if (await _metaFile.exists()) await _metaFile.delete();
    meta = null;
  }

  /// Lieux correspondant à [text], les plus pertinents et proches de [near] d'abord.
  List<LocalPlace> search(String text, {LatLng? near, int limit = 6}) {
    final db = _open;
    final words = normalizeWords(text).split(' ').where((w) => w.isNotEmpty).toList();
    if (db == null || words.isEmpty || words.join().length < 2) return const [];
    final match = words.map((w) => '"$w"*').join(' ');
    final c = near ?? const LatLng(48.8566, 2.3522);
    const cols =
        'l.nom, l.type, l.adresse, l.ville, l.lat, l.lon, bm25(recherche, 10.0, 1.0, 3.0, 0.5) - l.poids * 1.5';
    const dist = '((l.lat - ?1) * (l.lat - ?1) + (l.lon - ?2) * (l.lon - ?2) * 0.43)';
    // deux tirages : les plus pertinents, et les plus proches parmi ceux qui correspondent
    final rows = <Row>[];
    try {
      for (final order in ['7', dist]) {
        rows.addAll(
          db.select(
            'select $cols from recherche join lieux l on l.id = recherche.rowid '
            'where recherche match ?3 order by $order limit 40',
            [c.latitude, c.longitude, match],
          ),
        );
      }
    } on SqliteException {
      return const [];
    }
    final seen = <String>{};
    final scored = <(double, LocalPlace)>[];
    for (final row in rows) {
      final r = row.values;
      final p = LocalPlace(
        name: r[0] as String,
        kind: r[1] as String,
        address: r[2] as String,
        town: r[3] as String,
        pos: LatLng((r[4] as num).toDouble(), (r[5] as num).toDouble()),
      );
      if (!seen.add('${p.name}|${p.pos}')) continue;
      final km = const Distance().as(LengthUnit.Kilometer, c, p.pos);
      scored.add((placeScore(base: (r[6] as num).toDouble(), km: km, name: p.name, kind: p.kind, words: words), p));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored.take(limit)) s.$2];
  }
}
