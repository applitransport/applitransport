import 'dart:convert';
import 'dart:io';

import 'package:applitransport/data/package_decoder.dart';
import 'package:applitransport/data/repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Petit serveur de publication : sert un dossier, avec ETag et réponse 304 comme GitHub Pages.
Future<HttpServer> serve(Directory root, List<String> log) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final f = File('${root.path}${req.uri.path}');
    log.add(req.uri.path);
    if (!await f.exists()) {
      req.response.statusCode = 404;
    } else {
      final bytes = await f.readAsBytes();
      final etag = '"${bytes.length}-${bytes.fold<int>(0, (a, b) => (a * 31 + b) & 0xFFFFFFF)}"';
      if (req.headers.value('if-none-match') == etag) {
        req.response.statusCode = 304;
        log.add('304');
      } else {
        req.response.headers.set('etag', etag);
        req.response.add(bytes);
      }
    }
    await req.response.close();
  });
  return server;
}

void writeCatalog(Directory pub, Map<String, String> versions) {
  final lines = [
    for (final e in versions.entries)
      {
        'route_id': 'IDFM:${e.key}',
        'file': 'lines/${e.key}.json.gz',
        'version': e.value,
        'size': File('${pub.path}/lines/${e.key}.json.gz').lengthSync(),
      }
  ];
  File('${pub.path}/catalog.json.gz').writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode({'format': 1, 'lines': lines}))));
}

void main() {
  late Directory tmp, pub, device;
  late HttpServer server;
  final log = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('applitransport_test');
    pub = await Directory('${tmp.path}/public/lines').create(recursive: true).then((d) => d.parent);
    device = Directory('${tmp.path}/appareil');
    for (final code in ['C01527', 'C01528']) {
      File('test/fixtures/$code.json.gz').copySync('${pub.path}/lines/$code.json.gz');
    }
    writeCatalog(pub, {'C01527': 'v1', 'C01528': 'v1'});
    log.clear();
    server = await serve(pub, log);
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  String url() => 'http://127.0.0.1:${server.port}/';

  test('catalogue, téléchargements, mises à jour et persistance', () async {
    final base = url();
    var repo = await Repository.open(dir: device, baseUrl: base);
    expect(repo.catalog, isNull);

    // 1er lancement : catalogue téléchargé ; 2e vérification : « inchangé » (304), rien de retéléchargé
    expect(await repo.refreshCatalog(), isTrue);
    expect(repo.catalogLines.length, 2);
    expect(await repo.refreshCatalog(), isFalse);
    expect(log.where((l) => l == '304').length, 1);

    // téléchargement d'une ligne, lisible et décodable
    await repo.download('C01527');
    expect(repo.local.keys, ['C01527']);
    final pkg = await repo.readLine('C01527');
    expect(timetableFor(pkg, DateTime(2026, 10, 29)).name, '5104');

    // nouvelle publication : la 5104 change de version → signalée, puis mise à jour
    writeCatalog(pub, {'C01527': 'v2', 'C01528': 'v1'});
    expect(await repo.refreshCatalog(), isTrue);
    expect(repo.outdated, ['C01527']);
    await repo.download('C01527');
    expect(repo.outdated, isEmpty);

    // « tout télécharger »
    final progress = <int>[];
    await repo.downloadMany(['C01527', 'C01528'], onProgress: (d, t) => progress.add(d));
    expect(progress, [1, 2]);
    expect(repo.localBytes, repo.allBytes);

    // réouverture (redémarrage de l'appli) : tout est conservé, sans réseau
    await server.close(force: true);
    repo = await Repository.open(dir: device, baseUrl: base);
    expect(repo.local.keys.toSet(), {'C01527', 'C01528'});
    expect(repo.local['C01527']!.version, 'v2');
    expect(repo.catalogLines.length, 2);
    expect(timetableFor(await repo.readLine('C01528'), DateTime(2026, 10, 29)).name, '5105');

    // suppression
    await repo.remove('C01528');
    expect(File('${device.path}/lines/C01528.json.gz').existsSync(), isFalse);
    repo = await Repository.open(dir: device, baseUrl: base);
    expect(repo.local.keys, ['C01527']);
  });
}
