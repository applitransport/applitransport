import 'package:applitransport/poc/data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nom du véhicule selon le type de ligne', () {
    expect(vehicleWord('train'), 'train');
    expect(vehicleWord('train', plural: true), 'trains');
    expect(vehicleWord('bus', plural: true), 'bus');
    expect(vehicleWord('metro'), 'métro');
    expect(vehicleWord('inconnu'), 'véhicule');
  });

  test('type de ligne d\'après le mode du calculateur', () {
    expect(typeOfMode('Bus'), 'bus');
    expect(typeOfMode('Train Transilien'), 'train');
    expect(typeOfMode('RER'), 'train');
    expect(typeOfMode('TER'), 'train');
    expect(typeOfMode('Tramway'), 'tram');
    expect(typeOfMode('Métro'), 'metro');
  });
}
