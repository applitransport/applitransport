import 'package:applitransport/data/paris_time.dart';
import 'package:flutter_test/flutter_test.dart';

// L'heure de Paris ne dépend pas du fuseau de l'appareil (les tests tournent aussi en UTC sur GitHub).
void main() {
  String hm(DateTime t) => '${t.day}/${t.month} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';

  test('heure d\'été et d\'hiver, changements d\'heure 2026', () {
    expect(hm(parisTime(DateTime.utc(2026, 10, 29, 16, 34))), '29/10 17:34'); // hiver : UTC+1
    expect(hm(parisTime(DateTime.utc(2026, 7, 14, 10))), '14/7 12:00'); // été : UTC+2
    // dimanche 25 octobre 2026 : 03:00 d'été → 02:00 d'hiver (01:00 UTC)
    expect(hm(parisTime(DateTime.utc(2026, 10, 25, 0, 59))), '25/10 2:59');
    expect(hm(parisTime(DateTime.utc(2026, 10, 25, 1))), '25/10 2:00');
    // dimanche 29 mars 2026 : 02:00 d'hiver → 03:00 d'été (01:00 UTC)
    expect(hm(parisTime(DateTime.utc(2026, 3, 29, 0, 59))), '29/3 1:59');
    expect(hm(parisTime(DateTime.utc(2026, 3, 29, 1))), '29/3 3:00');
  });

  test('une heure SIRI avec fuseau explicite donne la même heure de Paris', () {
    expect(parisTime(DateTime.parse('2026-10-29T16:34:00Z')), parisTime(DateTime.parse('2026-10-29T17:34:00+01:00')));
  });
}
