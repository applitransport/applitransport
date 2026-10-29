// Données de l'appareil : catalogue et lignes téléchargés depuis la publication de l'usine
// (GitHub Pages, ou le PC pendant le développement), conservés de façon permanente.
//
//   <dossier>/index.json            lignes téléchargées (version, date, taille), en-têtes du catalogue
//   <dossier>/catalog.json.gz       catalogue tel que publié
//   <dossier>/lines/<code>.json.gz  paquets tels que publiés (compressés : ~14 Mo pour toutes les lignes)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package_decoder.dart';

class LocalLine {
  LocalLine(this.version, this.downloadedAt, this.size, this.until);

  LocalLine.fromJson(Map<String, dynamic> j)
      : version = j['version'],
        downloadedAt = DateTime.parse(j['downloaded_at']),
        size = j['size'],
        until = j['until'] == null ? null : DateTime.parse(j['until']);

  final String version;
  final DateTime downloadedAt;
  final int size;

  /// Dernier jour couvert par les horaires téléchargés (au-delà : horaires à mettre à jour).
  final DateTime? until;

  Map<String, dynamic> toJson() => {
        'version': version,
        'downloaded_at': downloadedAt.toIso8601String(),
        'size': size,
        'until': until?.toIso8601String(),
      };
}

class Repository {
  Repository._(this.dir, this.baseUrl, this._client);

  /// [baseUrl] : adresse du dossier publié (se termine par « / »).
  static Future<Repository> open({required Directory dir, required String baseUrl, http.Client? client}) async {
    final r = Repository._(dir, baseUrl, client ?? http.Client());
    await Directory('${dir.path}/lines').create(recursive: true);
    await r._load();
    return r;
  }

  final Directory dir;
  String baseUrl;
  final http.Client _client;

  Map<String, dynamic>? _catalog;
  List<Map<String, dynamic>> _lines = const [];
  Map<String, Map<String, dynamic>> _byCode = const {}; // index : code de ligne -> entrée du catalogue
  final Map<String, LocalLine> local = {};

  Map<String, dynamic>? get catalog => _catalog;

  set catalog(Map<String, dynamic>? c) {
    _catalog = c;
    _lines = [for (final l in c?['lines'] ?? const []) l as Map<String, dynamic>];
    _byCode = {for (final l in _lines) (l['route_id'] as String).split(':').last: l};
  }
  DateTime? lastCheck;
  String? _etag, _lastModified;

  File get _indexFile => File('${dir.path}/index.json');
  File get _catalogFile => File('${dir.path}/catalog.json.gz');
  File _lineFile(String code) => File('${dir.path}/lines/$code.json.gz');
  Uri _url(String path) => Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/').resolve(path);

  Future<void> _load() async {
    if (await _indexFile.exists()) {
      final j = jsonDecode(await _indexFile.readAsString());
      _etag = j['etag'];
      _lastModified = j['last_modified'];
      lastCheck = j['last_check'] == null ? null : DateTime.parse(j['last_check']);
      for (final e in (j['lines'] as Map<String, dynamic>).entries) {
        if (await _lineFile(e.key).exists()) local[e.key] = LocalLine.fromJson(e.value);
      }
    }
    if (await _catalogFile.exists()) catalog = readPackage(await _catalogFile.readAsBytes());
  }

  Future<void> _pendingSave = Future.value();

  /// Les écritures de l'index se font l'une après l'autre (téléchargements parallèles).
  Future<void> _save() => _pendingSave = _pendingSave.then((_) => _writeIndex(), onError: (_) => _writeIndex());

  Future<void> _writeIndex() async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'etag': _etag,
      'last_modified': _lastModified,
      'last_check': lastCheck?.toIso8601String(),
      'lines': {for (final e in local.entries) e.key: e.value.toJson()},
    }));
    await tmp.rename(_indexFile.path); // remplacement atomique
  }

  List<Map<String, dynamic>> get catalogLines => _lines;

  Map<String, dynamic>? catalogLine(String code) => _byCode[code];

  /// Télécharge le catalogue s'il a changé (requête conditionnelle). Renvoie true s'il a changé.
  Future<bool> refreshCatalog() async {
    final headers = <String, String>{
      if (_etag != null && catalog != null) 'If-None-Match': _etag!,
      if (_lastModified != null && catalog != null) 'If-Modified-Since': _lastModified!,
    };
    final r = await _client.get(_url('catalog.json.gz'), headers: headers);
    lastCheck = DateTime.now();
    if (r.statusCode == 304) {
      await _save();
      return false;
    }
    if (r.statusCode != 200) throw HttpException('catalogue : HTTP ${r.statusCode}');
    final parsed = readPackage(r.bodyBytes); // vérifie que le fichier est complet et lisible
    await _catalogFile.writeAsBytes(r.bodyBytes, flush: true);
    catalog = parsed;
    _etag = r.headers['etag'];
    _lastModified = r.headers['last-modified'];
    await _save();
    return true;
  }

  /// Télécharge (ou met à jour) une ligne du catalogue. [save] : enregistrer l'index aussitôt.
  Future<void> download(String code, {bool save = true}) async {
    final line = catalogLine(code);
    if (line == null) throw StateError('ligne $code absente du catalogue');
    final r = await _client.get(_url(line['file']));
    if (r.statusCode != 200) throw HttpException('ligne $code : HTTP ${r.statusCode}');
    final pkg = readPackage(r.bodyBytes);
    if (pkg['format'] != supportedFormat) throw FormatException('ligne $code : format ${pkg['format']} non géré');
    await _lineFile(code).writeAsBytes(r.bodyBytes, flush: true);
    local[code] = LocalLine(line['version'], DateTime.now(), r.bodyBytes.length, lastServiceDay(pkg));
    if (save) await _save();
  }

  /// Télécharge plusieurs lignes en parallèle ([parallel] à la fois). L'index est enregistré toutes
  /// les 100 lignes et à la fin : une interruption ne fait perdre que les dernières.
  Future<void> downloadMany(List<String> codes, {void Function(int done, int total)? onProgress, int parallel = 6}) async {
    var done = 0;
    final queue = [...codes];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final code = queue.removeLast();
        await download(code, save: false);
        onProgress?.call(++done, codes.length);
        if (done % 100 == 0) await _save();
      }
    }

    try {
      await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    } finally {
      await _save();
    }
  }

  Future<void> remove(String code) async {
    local.remove(code);
    final f = _lineFile(code);
    if (await f.exists()) await f.delete();
    await _save();
  }

  /// Lignes téléchargées dont le catalogue annonce une nouvelle version.
  List<String> get outdated => [
        for (final e in local.entries)
          if (_byCode[e.key] != null && _byCode[e.key]!['version'] != e.value.version) e.key
      ];

  /// Lignes téléchargées qui ont disparu du catalogue (ligne supprimée du réseau).
  List<String> get vanished => [for (final code in local.keys) if (catalog != null && catalogLine(code) == null) code];

  Future<Map<String, dynamic>> readLine(String code) async => readPackage(await _lineFile(code).readAsBytes());

  /// Lecture immédiate (paquets de quelques Ko à 170 Ko) pour les écrans.
  Map<String, dynamic> readLineSync(String code) => readPackage(_lineFile(code).readAsBytesSync());

  int get localBytes => local.values.fold(0, (a, l) => a + l.size);

  int get allBytes => catalogLines.fold(0, (a, l) => a + (l['size'] as int));
}
