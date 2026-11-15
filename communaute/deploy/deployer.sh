#!/usr/bin/env bash
# Depuis le PC : copie le serveur communautaire sur une machine et l'installe (ou le met à jour).
#   SSH_OPTS="-i ~/.ssh/<clé>" communaute/deploy/deployer.sh <utilisateur>@<machine>
# Demande le mot de passe sudo s'il y en a un (saisi sur la machine, jamais enregistré).
set -euo pipefail

HOTE="${1:?usage : $0 utilisateur@machine}"
# shellcheck disable=SC2086
ssh() { command ssh ${SSH_OPTS:-} "$@"; }
# shellcheck disable=SC2086
scp() { command scp ${SSH_OPTS:-} "$@"; }
ICI="$(cd "$(dirname "$0")/.." && pwd)"
DISTANT=/tmp/applitransport-communaute

ssh "$HOTE" "rm -rf $DISTANT && mkdir -p $DISTANT/deploy"
scp -q "$ICI"/__init__.py "$ICI"/etat.py "$ICI"/serveur.py "$ICI"/requirements.txt "$HOTE:$DISTANT/"
scp -q "$ICI"/deploy/installer.sh "$ICI"/deploy/applitransport-communaute.service "$HOTE:$DISTANT/deploy/"
ssh -t "$HOTE" "sudo bash $DISTANT/deploy/installer.sh; rm -rf $DISTANT"
