// Heure de Paris, indépendante du fuseau horaire réglé sur l'appareil.
//
// Les horaires IDFM, le calculateur et l'Info Trafic sont en heure de Paris ; PRIM donne le temps réel
// en UTC. Convertir avec le fuseau du téléphone décalerait tout d'une heure sur un appareil réglé
// ailleurs (et rattacherait une course au mauvais horaire). Convention de l'appli : une heure de Paris
// est un DateTime « UTC » dont les champs (année… minute) sont ceux de l'horloge de Paris.

/// Dernier dimanche du mois [month] de [year], à 01:00 UTC (changement d'heure européen).
DateTime _lastSunday(int year, int month) {
  final last = DateTime.utc(year, month + 1, 0, 1);
  return last.subtract(Duration(days: last.weekday % 7));
}

/// Heure de Paris de l'instant [t] : UTC+2 du dernier dimanche de mars au dernier dimanche
/// d'octobre (01:00 UTC), UTC+1 sinon.
DateTime parisTime(DateTime t) {
  final utc = t.toUtc();
  final summer = !utc.isBefore(_lastSunday(utc.year, 3)) && utc.isBefore(_lastSunday(utc.year, 10));
  return utc.add(Duration(hours: summer ? 2 : 1));
}

DateTime parisNow() => parisTime(DateTime.now());

/// Minuit du jour [d] (heure de Paris), dans la convention de l'appli.
DateTime parisMidnight(DateTime d) => DateTime.utc(d.year, d.month, d.day);
