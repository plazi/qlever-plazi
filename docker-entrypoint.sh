#!/bin/sh
# The access token is not part of the image (the image is public). Unless
# QLEVER_ACCESS_TOKEN is given, a random token is generated at every start:
# `qlever start` needs one to set the index description, but nobody outside
# the container knows it, so privileged operations (cache clearing, runtime
# settings, updates) are effectively disabled.
set -eu

if [ "${1:-}" = "start" ]; then
  token=${QLEVER_ACCESS_TOKEN:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)}
  set -- "$@" --access-token "$token"
fi

exec qlever "$@"
