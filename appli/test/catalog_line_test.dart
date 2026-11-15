import 'package:applitransport/poc/data.dart';
import 'package:flutter_test/flutter_test.dart';

CatalogLine _line(String short, String long, [List<String>? termini]) => CatalogLine.fromCatalog({
  'route_id': 'IDFM:C01748',
  'short_name': short,
  'long_name': long,
  'type': 'train',
  'network': 'IDFM:93',
  'color': 'FF0000',
  'text_color': 'FFFFFF',
  'size': 1000,
  'termini': ?termini,
});

void main() {
  test('nom long sans répéter le nom court, puis terminus', () {
    final ter = _line('TER', 'TER Normandie', ['Paris Saint-Lazare', 'Rouen Rive Droite']);
    expect(ter.longLabel, 'Normandie');
    expect(ter.description, 'Normandie · Paris Saint-Lazare ↔ Rouen Rive Droite');
  });

  test('nom long identique au nom court : seulement les terminus', () {
    expect(_line('5104', '5104', ['Pas du Lac', 'Trappes Gare']).description, 'Pas du Lac ↔ Trappes Gare');
    expect(_line('T6', 't6').longLabel, '');
  });

  test('ancien catalogue sans terminus', () {
    final l = _line('Soir', 'Soir Montereau Sud');
    expect(l.termini, isEmpty);
    expect(l.description, 'Montereau Sud');
  });
}
