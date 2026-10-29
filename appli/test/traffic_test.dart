import 'dart:convert';
import 'dart:io';

import 'package:applitransport/data/traffic.dart';
import 'package:flutter_test/flutter_test.dart';

// Perturbations réelles de la ligne N relevées par la surveillance le 29/10/2026.
void main() {
  test('nettoyage du HTML des messages', () {
    expect(cleanHtml('<p>P&#233;riode : de soir&#233;e.<br><br>Dates&nbsp;: lundi</p>'), 'Période : de soirée.\nDates : lundi');
  });

  test('Info Trafic de la N : classement, dédoublonnage, périodes', () {
    final data = jsonDecode(File('test/fixtures/trafic_N.json').readAsStringSync());
    final raw = (data['disruptions'] as List).length;
    final list = parseLineReports(data);
    expect(list.length, lessThan(raw)); // les doublons sont fusionnés
    final works = list.where((d) => d.kind == DisruptionKind.works).toList();
    final lifts = list.where((d) => d.kind == DisruptionKind.accessibility).toList();
    expect(works, isNotEmpty);
    expect(lifts, isNotEmpty);
    expect(works.every((d) => d.wholeLine), isTrue);
    expect(lifts.every((d) => d.stopAreas.isNotEmpty), isTrue);
    expect(list.every((d) => d.title.isNotEmpty && !d.text.contains('&#')), isTrue);
    // travaux de nuit (00:38 → 02:59) du 26 au 30/10 : en cours la nuit du 30, pas à midi
    final tonight = works.where((d) => d.activeAt(DateTime(2026, 10, 30, 1))).toList();
    expect(tonight, isNotEmpty);
    expect(tonight.any((d) => d.activeAt(DateTime(2026, 10, 29, 12))), isFalse);
    // ignore: avoid_print
    print('${list.length} perturbations (sur $raw), ${works.length} travaux, ${lifts.length} ascenseurs ; '
        'nuit du 30/10 à 1 h : ${tonight.map((d) => d.title).join(' | ')}');
  });
}
