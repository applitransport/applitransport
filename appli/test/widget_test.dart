import 'package:applitransport/poc/position.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatage des heures et durées', () {
    expect(hhmm(8 * 3600 + 5 * 60), '08:05');
    expect(hhmm(25 * 3600 + 35 * 60), '01:35'); // course après minuit
    expect(duration(45), '45 s');
    expect(duration(3725), '1 h 02');
    expect(delayLabel(null), 'théorique');
    expect(delayLabel(20), "à l'heure");
    expect(delayLabel(185), '+3 min');
  });
}
