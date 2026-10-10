#!/usr/bin/env bash
# Sets up (or updates) the nightly build on a host, as root:
#
#   sudo ./systemd/install.sh
#
# Runs the build as the system user qlever-plazi from /opt/qlever-plazi, with
# the host settings in /etc/qlever-plazi.env. On a new host the first call
# creates that file from qlever-plazi.env.example and stops, so it can be
# edited; the second call finishes the setup and runs the first build.
# Safe to run again.
set -euo pipefail

SERVICE_USER=qlever-plazi
CODE=/opt/qlever-plazi
CONFIG=/etc/qlever-plazi.env
# For the first build only, see the end
FORCE=/run/systemd/system/qlever-plazi.service.d/force.conf
REPO_URL=https://github.com/plazi/qlever-plazi.git
SRC=$(cd "$(dirname "$0")/.." && pwd)

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
step() { echo; echo "== $*"; }
# A leftover of a killed install.sh would force every run
if [ -e "$FORCE" ]; then rm -f "$FORCE"; systemctl daemon-reload; fi
# The checks below and the build need these
for tool in docker jq git curl flock; do
  command -v "$tool" > /dev/null || { echo "install $tool first" >&2; exit 1; }
done

step "host settings in $CONFIG"
if [ ! -f "$CONFIG" ]; then
  install -m 644 "$SRC/qlever-plazi.env.example" "$CONFIG"
  echo "created $CONFIG from the example: edit it (QP_ROOT, QP_NETWORK, ...), then run $0 again"
  exit 0
fi
# As the runs see them: read, with their defaults, and checked by the script
# itself, from the file alone (the unit only sets QP_ROOT, from here, below)
settings=$(env -i PATH="$PATH" QP_CONFIG="$CONFIG" "$SRC/scripts/qlever-plazi.sh" settings) ||
  { echo "fix $CONFIG, then run $0 again" >&2; exit 1; }
echo "$settings"
setting() { sed -n "s/^$1=//p" <<< "$settings"; }
QP_ROOT=$(setting QP_ROOT)
QP_NETWORK=$(setting QP_NETWORK)
QP_HOST=$(setting QP_HOST)
QP_PREFIX=$(setting QP_PREFIX)
docker network inspect "$QP_NETWORK" > /dev/null 2>&1 ||
  { echo "QP_NETWORK in $CONFIG: no Docker network '$QP_NETWORK'" >&2; exit 1; }

step "no other deployment serving $QP_HOST"
# Another server routed by Traefik to the same host would keep answering next
# to ours (the switch only stops containers of this setup), and another
# scheduled build would compete for the same data. Retire them first.
# Stopped containers too, as compose or a restart policy may start them again.
# The containers of this setup are its servers, labelled with their role, and
# $QP_PREFIX-status (see scripts/qlever-plazi.sh).
others=$(docker ps -aq | xargs -r docker inspect |
  jq -r --arg host "$QP_HOST" --arg role "$QP_PREFIX-server" --arg status "/$QP_PREFIX-status" '
    ($host | ascii_downcase) as $h | .[]
    | select(.Name != $status and .Config.Labels["org.plazi.qlever.role"] != $role)
    | select(any(.Config.Labels // {} | .[] | ascii_downcase; contains("`\($h)`") or contains("\"\($h)\"")))
    | .Name' || true)
schedules=$(grep -l 'qlever-plazi.sh' /var/spool/cron/crontabs/* /etc/crontab /etc/cron.d/* 2> /dev/null || true)
if [ -n "$others$schedules" ]; then
  [ -z "$others" ] || echo "containers routed to $QP_HOST outside this setup (running or not):" $others >&2
  [ -z "$schedules" ] || echo "crontabs that run qlever-plazi.sh:" $schedules >&2
  echo "remove those containers (docker rm, and from their compose file) and the qlever-plazi.sh lines" \
    "of those crontabs, then run $0 again" >&2
  exit 1
fi
echo "none"

step "service user $SERVICE_USER"
if ! id "$SERVICE_USER" > /dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir "/var/lib/$SERVICE_USER-home" \
    --shell /usr/sbin/nologin "$SERVICE_USER"
fi
# Also when the user existed already: the unit runs with this group, and the
# build needs Docker
getent group "$SERVICE_USER" > /dev/null || groupadd --system "$SERVICE_USER"
usermod -g "$SERVICE_USER" -aG docker "$SERVICE_USER"
id "$SERVICE_USER"
# The runs read the settings as this user
sudo -u "$SERVICE_USER" test -r "$CONFIG" || { echo "$SERVICE_USER cannot read $CONFIG" >&2; exit 1; }
# An earlier install.sh made /var/lib/qlever-plazi, now the default QP_ROOT,
# the home directory: keep the data and the home apart
home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
home=$(realpath -m "${home:-/}") root=$(realpath -m "$QP_ROOT")
if [ "$home" != / ] && [[ $root/ == "$home"/* || $home/ == "$root"/* ]]; then
  echo "QP_ROOT $QP_ROOT overlaps $home, the home directory of $SERVICE_USER: set another QP_ROOT in $CONFIG," >&2
  echo "or, while nothing runs as $SERVICE_USER: usermod -d /var/lib/$SERVICE_USER-home $SERVICE_USER" >&2
  exit 1
fi

step "data in $QP_ROOT"
mkdir -p "$QP_ROOT"
chown "$SERVICE_USER:" "$QP_ROOT"

step "code in $CODE"
if [ ! -d "$CODE/.git" ]; then
  git clone --quiet "$REPO_URL" "$CODE"
fi
chown -R "$SERVICE_USER:" "$CODE"
sudo -u "$SERVICE_USER" git -C "$CODE" pull --ff-only --quiet
sudo -u "$SERVICE_USER" git -C "$CODE" log --oneline -1

step "systemd units"
install -m 644 "$CODE/systemd/qlever-plazi.service" "$CODE/systemd/qlever-plazi.timer" /etc/systemd/system/
mkdir -p /etc/systemd/system/qlever-plazi.service.d
# QP_ROOT is fixed here, with the dependency on its mount, so that a run with
# a broken settings file still writes its failed status to the right place
printf '[Unit]\n# Generated by install.sh from %s\nRequiresMountsFor=%s\n\n[Service]\nEnvironment=QP_ROOT=%s\n' \
  "$CONFIG" "$QP_ROOT" "$QP_ROOT" > /etc/systemd/system/qlever-plazi.service.d/data.conf
# Without a healthy server on the live index, there may be no live treatment
# count to compare with, and a timer run would skip unchanged data: the first
# build runs with QP_FORCE=1
live=$(readlink "$QP_ROOT/current" || true)
live=${live%/}
serving=$(docker ps -q --filter health=healthy --filter "label=org.plazi.qlever.role=$QP_PREFIX-server" \
  --filter "label=org.plazi.qlever.index=${live##*/}")
if [ -n "$live" ] && [ -n "$serving" ]; then
  first_build=false
else
  first_build=true
  trap 'rm -f "$FORCE"; systemctl daemon-reload || echo "WARNING: run systemctl daemon-reload, or the timer runs with QP_FORCE=1" >&2' EXIT
  mkdir -p "$(dirname "$FORCE")"
  printf '[Service]\nEnvironment=QP_FORCE=1\n' > "$FORCE"
fi
systemctl daemon-reload
systemctl enable --now qlever-plazi.timer

if $first_build; then
  step "first build (about 30 minutes; progress: journalctl -fu qlever-plazi)"
  systemctl start qlever-plazi.service ||
    { echo "first build FAILED, see: journalctl -u qlever-plazi" >&2; exit 1; }
else
  step "done (a healthy server runs on the live index; the timer builds the next one)"
fi
systemctl list-timers qlever-plazi.timer --no-pager
