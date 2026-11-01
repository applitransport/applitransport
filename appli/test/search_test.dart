import 'package:applitransport/poc/data.dart';
import 'package:flutter_test/flutter_test.dart';

StopArea area(String name, {List<String> aliases = const [], String town = '', int lines = 1}) => StopArea.fromJson({
  'id': name,
  'name': name,
  'town': town,
  'aliases': aliases,
  'lines': [for (var i = 0; i < lines; i++) 'IDFM:C$i'],
});

void main() {
  test('forme de comparaison : sans majuscules, accents, tirets ni apostrophes', () {
    expect(searchKey('La Défense'), 'la defense');
    expect(searchKey("Gare de l'Est"), 'gare de l est');
    expect(searchKey('Évry-Courcouronnes'), 'evry courcouronnes');
    expect(searchKey('  Saint-Quentin   en Yvelines '), 'saint quentin en yvelines');
  });

  test('recherche d\'arrêt tolérante aux accents et à la ponctuation', () {
    final areas = [
      area('La Défense', town: 'Puteaux', lines: 20),
      area('Gare de l\'Est', town: 'Paris 10e', lines: 15),
      area(
        'Saint-Quentin en Yvelines - Montigny-le-Bretonneux',
        aliases: ['Saint-Quentin - Souterrain quai J'],
        lines: 38,
      ),
      area('Le Hameau', town: 'Montigny-le-Bretonneux', lines: 6),
    ];
    List<String> find(String q) => [for (final a in searchStopAreas(areas, q)) a.name];
    expect(find('la defense'), ['La Défense']);
    expect(find('LA DÉFENSE'), ['La Défense']);
    expect(find('gare de l est'), ["Gare de l'Est"]);
    expect(find('saint quentin'), ['Saint-Quentin en Yvelines - Montigny-le-Bretonneux']);
    expect(find('souterrain'), ['Saint-Quentin en Yvelines - Montigny-le-Bretonneux']); // nom de quai
    expect(find('hameau montigny'), ['Le Hameau']); // nom + commune
  });
}
