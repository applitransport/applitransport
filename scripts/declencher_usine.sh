#!/bin/sh
# Lance l'usine à données sur GitHub (équivalent du bouton « Run workflow » de l'onglet Actions).
# Prévu pour un cron sur une machine toujours allumée (Raspberry Pi…), car la planification de
# GitHub est retardée de plusieurs heures, voire sautée. Le créneau GitHub reste en secours.
#
# Le jeton GitHub (fine-grained, dépôt applitransport/applitransport seul, droit « Actions : Read
# and write ») est lu dans un fichier local, jamais dans ce script :
#   ~/.config/applitransport/jeton_github   (chmod 600)
#
# Exemple de crontab (crontab -e), heure locale de Paris : 08:45 = 06:45 UTC l'été, 07:45 l'hiver,
# après la publication d'IDFM (vers 06:25 UTC) :
#   45 8 * * * /home/pi/declencher_usine.sh >> /home/pi/declencher_usine.log 2>&1

DEPOT="applitransport/applitransport"
TACHE="usine.yml"
JETON_FICHIER="${JETON_FICHIER:-$HOME/.config/applitransport/jeton_github}"

if [ ! -r "$JETON_FICHIER" ]; then
  echo "$(date '+%F %T') jeton introuvable : $JETON_FICHIER"
  exit 1
fi
JETON=$(tr -d ' \r\n' < "$JETON_FICHIER")

# 3 essais espacés de 10 min (coupure réseau, GitHub indisponible)
for essai in 1 2 3; do
  code=$(curl -s -o /tmp/declencher_usine.$$ -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $JETON" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$DEPOT/actions/workflows/$TACHE/dispatches" \
    -d '{"ref":"main"}')
  if [ "$code" = "204" ]; then
    echo "$(date '+%F %T') usine lancée"
    rm -f /tmp/declencher_usine.$$
    exit 0
  fi
  echo "$(date '+%F %T') essai $essai : échec (HTTP $code) $(head -c 300 /tmp/declencher_usine.$$ 2>/dev/null)"
  rm -f /tmp/declencher_usine.$$
  # 401/403/404 : jeton invalide, expiré ou sans le bon droit ; inutile d'insister
  case "$code" in 401|403|404) exit 1 ;; esac
  [ "$essai" -lt 3 ] && sleep 600
done
exit 1
