#!/usr/bin/env bash
# One-time setup, as root: runs the nightly build as the system user
# qlever-plazi from /opt/qlever-plazi, with the data in /fastssd/qlever-plazi,
# and takes over from a setup that ran from a personal account (crontab and
# ~/qlever-plazi-data of OLD_USER). Safe to run again.
#
#   sudo ./systemd/install.sh
set -euo pipefail

SERVICE_USER=qlever-plazi
CODE=/opt/qlever-plazi
DATA=/fastssd/qlever-plazi
REPO_URL=https://github.com/plazi/qlever-plazi.git
OLD_USER=${OLD_USER:-reto}

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
step() { echo; echo "== $*"; }

# The earlier setup's data, which is chowned and later removed: only ever a
# qlever-plazi-data directory inside an existing home directory
old_home=$(getent passwd "$OLD_USER" | cut -d: -f6) || { echo "no user $OLD_USER (set OLD_USER)" >&2; exit 1; }
case $old_home in
  "" | / ) echo "$OLD_USER has no usable home directory ('$old_home')" >&2; exit 1 ;;
esac
[ -d "$old_home" ] || { echo "home directory $old_home of $OLD_USER does not exist" >&2; exit 1; }
OLD_DATA=$old_home/qlever-plazi-data

step "service user $SERVICE_USER"
if ! id "$SERVICE_USER" > /dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir "/var/lib/$SERVICE_USER" \
    --shell /usr/sbin/nologin "$SERVICE_USER"
fi
# Also when the user existed already: the unit runs with this group, and the
# build needs Docker
getent group "$SERVICE_USER" > /dev/null || groupadd --system "$SERVICE_USER"
usermod -g "$SERVICE_USER" -aG docker "$SERVICE_USER"
id "$SERVICE_USER"

step "data in $DATA"
mkdir -p "$DATA"
chown "$SERVICE_USER:" "$DATA"

step "code in $CODE"
if [ ! -d "$CODE/.git" ]; then
  git clone --quiet "$REPO_URL" "$CODE"
fi
chown -R "$SERVICE_USER:" "$CODE"
sudo -u "$SERVICE_USER" git -C "$CODE" pull --ff-only --quiet
sudo -u "$SERVICE_USER" git -C "$CODE" log --oneline -1

step "systemd units"
install -m 644 "$CODE/systemd/qlever-plazi.service" "$CODE/systemd/qlever-plazi.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now qlever-plazi.timer

step "taking over from $OLD_USER"
if crontab -u "$OLD_USER" -l 2> /dev/null | grep -q 'qlever-plazi'; then
  # grep -v exits 1 when no other line is left
  crontab -u "$OLD_USER" -l | { grep -v 'qlever-plazi' || true; } | crontab -u "$OLD_USER" -
  echo "removed the qlever-plazi line from the crontab of $OLD_USER"
fi
if [ -d "$OLD_DATA" ]; then
  # The first run drains the server that still uses this index
  chown -R "$SERVICE_USER:" "$OLD_DATA"
fi

step "first run (about 30 minutes; progress: journalctl -fu qlever-plazi)"
if systemctl start qlever-plazi.service; then
  echo "first run succeeded"
else
  echo "first run FAILED, see: journalctl -u qlever-plazi" >&2
  echo "the previous server keeps serving; $OLD_DATA was kept" >&2
  exit 1
fi

if [ -d "$OLD_DATA" ] && [[ $(readlink -f "$DATA/current") == "$DATA"/* ]] &&
  ! docker ps -q | xargs -r docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' | grep -q "$OLD_DATA"; then
  step "removing $OLD_DATA (no longer served)"
  rm -rf "$OLD_DATA"
fi

step "done"
systemctl list-timers qlever-plazi.timer --no-pager
echo "status: https://qlever.ld.plazi.org/status/status.json"
