#!/usr/bin/env bash
# Installe ou met à jour le serveur communautaire sur la machine courante (Debian, Ubuntu).
# Il écoute en local (127.0.0.1:8765), derrière un relais HTTPS (Caddy) sur la même machine.
# À lancer en root depuis le dossier copié par deployer.sh :  sudo bash deploy/installer.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"   # dossier communaute/ copié
DEST=/opt/applitransport-communaute
COMPTE=applitransport-communaute
SERVICE=applitransport-communaute
UNIT="$SERVICE.service"

[ "$(id -u)" -eq 0 ] || { echo "à lancer avec sudo" >&2; exit 1; }

if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
  echo "== installation de python3-venv"
  apt-get update -q && apt-get install -y -q python3-venv
fi

if ! id "$COMPTE" >/dev/null 2>&1; then
  echo "== création du compte système $COMPTE"
  useradd --system --home-dir "$DEST" --no-create-home --shell /usr/sbin/nologin "$COMPTE"
fi

echo "== copie du code dans $DEST"
install -d -m 0755 "$DEST" "$DEST/communaute"
install -m 0644 "$SRC"/__init__.py "$SRC"/etat.py "$SRC"/serveur.py "$SRC"/requirements.txt "$DEST/communaute/"

echo "== environnement Python"
[ -x "$DEST/venv/bin/python" ] || python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q --upgrade pip
"$DEST/venv/bin/pip" install -q -r "$DEST/communaute/requirements.txt"

echo "== service systemd"
install -m 0644 "$SRC/deploy/$UNIT" "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

echo "== contrôle"
for _ in $(seq 1 20); do
  if curl -sf http://127.0.0.1:8765/sante >/dev/null; then
    echo "serveur en service (127.0.0.1:8765, à relayer en HTTPS)"
    exit 0
  fi
  sleep 1
done
echo "le serveur ne répond pas ; journal :" >&2
journalctl -u "$SERVICE" -n 30 --no-pager >&2
exit 1
