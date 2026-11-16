import 'package:applitransport/data/geocoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseCompletion : lieu d\'intérêt et adresse', () {
    final r = parseCompletion({
      'status': 'OK',
      'results': [
        {
          'x': 2.037504,
          'y': 48.763659,
          'country': 'PositionOfInterest',
          'names': ['Gymnase Alain Colas'],
          'city': 'Montigny-le-Bretonneux',
          'zipcode': '78180',
          'kind': 'complexe sportif couvert',
          'fulltext': 'Gymnase Alain Colas, 78180 Montigny-le-Bretonneux',
        },
        {
          'x': 2.35,
          'y': 48.85,
          'country': 'StreetAddress',
          'city': 'Paris',
          'zipcode': '75004',
          'kind': 'housenumber',
          'fulltext': '12 Rue de Rivoli, 75004 Paris',
        },
        {'country': 'StreetAddress', 'fulltext': 'sans coordonnées'},
      ],
    });
    expect(r, hasLength(2));
    expect(r[0].name, 'Gymnase Alain Colas');
    expect(r[0].isPoi, isTrue);
    expect(r[0].detail, 'complexe sportif couvert · 78180 Montigny-le-Bretonneux');
    expect(r[0].pos.latitude, closeTo(48.7637, 1e-4));
    expect(r[1].name, '12 Rue de Rivoli');
    expect(r[1].isPoi, isFalse);
    expect(r[1].detail, '75004 Paris');
  });
}
