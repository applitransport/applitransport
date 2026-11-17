import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:applitransport/data/places_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  // PC de développement (Linux) : SQLite du système ; sur Android, celui embarqué dans l'appli
  open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));

  test('normalizeWords : accents, casse, ponctuation', () {
    expect(normalizeWords("Musée d'Orsay"), 'musee d orsay');
    expect(normalizeWords('  McDonald’s  '), 'mcdonald s');
  });

  test('recherche : mot entier, catégorie la plus proche, début de mot', () {
    final dir = Directory.systemTemp.createTempSync('lieux');
    final db = sqlite3.open('${dir.path}/lieux.db');
    db.execute('''
      create table lieux(id integer primary key, nom text, type text, adresse text, ville text, marque text,
        lat real, lon real, poids integer);
      insert into lieux(nom, type, adresse, ville, marque, lat, lon, poids) values
        ('Paul', 'boulangerie', '', 'Montigny-le-Bretonneux', 'Paul', 48.77, 2.04, 0),
        ('Boulangerie Pauline', 'boulangerie', '', 'Saint-Cyr-l''École', '', 48.80, 2.06, 0),
        ('Faculté de Pharmacie', 'université', '', 'Orsay', '', 48.70, 2.17, 2),
        ('Pharmacie du Centre', 'pharmacie', '', 'Montigny-le-Bretonneux', '', 48.771, 2.041, 0),
        ('McDonald''s', 'restauration rapide', '', 'Guyancourt', 'McDonald''s', 48.77, 2.07, 0);
      create virtual table recherche using fts5(nom, type, marque, ville, content='lieux', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3');
      insert into recherche(recherche) values('rebuild');
    ''');
    db.dispose();
    File('${dir.path}/lieux.json').writeAsStringSync(jsonEncode({'date': '2026-11-17T00:00:00Z', 'lieux': 5}));
    final store = PlacesStore(dir, () => 'http://localhost/');
    const here = LatLng(48.7748, 2.0389);
    expect(store.search('paul', near: here).first.name, 'Paul');
    expect(store.search('pharmacie', near: here).first.name, 'Pharmacie du Centre');
    expect(store.search('mcdo', near: here).first.name, "McDonald's");
    expect(store.search('zzz', near: here), isEmpty);
    dir.deleteSync(recursive: true);
  });
}
