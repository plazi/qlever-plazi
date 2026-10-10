#!/usr/bin/env bash
# Builds, checks and serves the QLever index behind qlever.ld.plazi.org.
#
#   qlever-plazi.sh run            nightly (systemd timer): build a new index if the data changed
#   qlever-plazi.sh rollback NAME  serve an earlier index again
#   qlever-plazi.sh list           list the kept indexes
#   qlever-plazi.sh settings       check and print the host settings in effect
#
# The upstream adfreiburg/qlever image is used unchanged; indexes live on the
# host and are never modified once built:
#
#   $QP_ROOT/indexes/<built>_<till7>_col-<version>/   one directory per index
#   $QP_ROOT/current -> indexes/...                   the index being served
#   $QP_ROOT/public/status/                           status, badge, run logs
#
# A new index only goes live after its checks pass. It is served by a new
# container that Traefik routes to only once it is healthy; the previous
# container is stopped after that, so the endpoint keeps serving throughout.
#
# Settings of the host (data directory, Docker network of Traefik, ...) are
# read from $QP_CONFIG, see qlever-plazi.env.example. Variables already set in
# the environment take precedence over the file. A run with a broken settings
# file fails like a failed check, so that the status shows it.
set -euo pipefail

QP_CONFIG=${QP_CONFIG:-/etc/qlever-plazi.env}
# All settings, defined below; a typo in the file is an error, not ignored
SETTINGS=(QP_ROOT QP_NETWORK QP_ENTRYPOINT QP_CERTRESOLVER QP_HOST QP_IMAGE QP_KEEP QP_MIN_FREE_GB
  QP_MIN_RATIO QP_FORCE QP_DRAIN_SECONDS HOOKNQ NQ_URL COL_REPO LINDAS LIVE_ENDPOINT CANARY_TREATMENT
  QP_PREFIX QP_ROUTER)
# The first problem with the file, reported by main; the lines after it still
# count. Only the line number, as the message ends up in the public status.
CONFIG_ERROR=''
config_error() { CONFIG_ERROR=${CONFIG_ERROR:-"$QP_CONFIG line $config_line: $1"}; }
declare -A config_keys=()
if [ -f "$QP_CONFIG" ] && [ -r "$QP_CONFIG" ]; then
  config_line=0
  while IFS= read -r line || [ -n "$line" ]; do
    config_line=$((config_line + 1))
    # without a byte order mark and surrounding whitespace, which includes the
    # \r of CRLF line ends
    line=${line#$'\xef\xbb\xbf'}
    line=${line%"${line##*[![:space:]]}"}
    line=${line#"${line%%[![:space:]]*}"}
    case $line in "" | "#"*) continue ;; esac
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { config_error "not KEY=value"; continue; }
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ " ${SETTINGS[*]} " == *" $key "* ]] || { config_error "no setting $key"; continue; }
    [ -z "${config_keys[$key]:-}" ] || { config_error "$key is set again"; continue; }
    config_keys[$key]=1
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    elif [[ $value == *[[:space:]]* ]]; then
      # e.g. a comment after the value
      config_error "the value of $key has a space but no quotes"; continue
    fi
    [ -n "${!key+set}" ] || declare -x "$key=$value"
  done < "$QP_CONFIG"
elif [ -e "$QP_CONFIG" ]; then
  CONFIG_ERROR="cannot read $QP_CONFIG"
fi

# Host settings
QP_ROOT=${QP_ROOT:-/var/lib/qlever-plazi}
QP_NETWORK=${QP_NETWORK:-}             # Docker network Traefik reaches the containers on
QP_ENTRYPOINT=${QP_ENTRYPOINT:-websecure}
QP_CERTRESOLVER=${QP_CERTRESOLVER-leresolver}   # set it empty for Traefik's default certificate
QP_HOST=${QP_HOST:-qlever.ld.plazi.org}
QP_IMAGE=${QP_IMAGE:-adfreiburg/qlever:latest}
QP_KEEP=${QP_KEEP:-3}
# A build needs about 35 GB while it runs (export, CoL, index); QP_ROOT shares
# its disk with other services, so don't start one with less space than this
QP_MIN_FREE_GB=${QP_MIN_FREE_GB:-50}
QP_MIN_RATIO=${QP_MIN_RATIO:-0.98}
QP_FORCE=${QP_FORCE:-0}
QP_DRAIN_SECONDS=${QP_DRAIN_SECONDS:-30}
HOOKNQ=${HOOKNQ:-https://hooknq.ld.plazi.org}
NQ_URL=${NQ_URL:-$HOOKNQ/nquads}
COL_REPO=${COL_REPO:-plazi/catologueoflife-to-rdf}
LINDAS=${LINDAS:-https://lindas.admin.ch/query}
LIVE_ENDPOINT=${LIVE_ENDPOINT:-https://$QP_HOST/sparql}
CANARY_TREATMENT=${CANARY_TREATMENT:-https://treatment.plazi.org/id/03DC6055C158FFEB52E2CC860DA3FB8F}
# Container name prefix and Traefik router name; change both for a test setup
QP_PREFIX=${QP_PREFIX:-qlever-plazi}
QP_ROUTER=${QP_ROUTER:-qleverplazi}

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PUBLIC=$QP_ROOT/public/status
ROLE_LABEL=org.plazi.qlever.role
ROLE=$QP_PREFIX-server
UIDGID="$(id -u):$(id -g)"

TREATMENT_COUNT_QUERY='SELECT (COUNT(DISTINCT ?t) AS ?n) WHERE { ?t a <http://plazi.org/vocab/treatment#Treatment> }'
COL_VERSION_QUERY='SELECT ?v WHERE { <https://www.catalogueoflife.org/data> <http://www.w3.org/2002/07/owl#versionInfo> ?v }'
KINGDOMS_QUERY='SELECT DISTINCT ?kingdom WHERE { ?taxon <http://rs.tdwg.org/dwc/terms/kingdom> ?kingdom }'
CANARY_QUERY="SELECT (COUNT(*) AS ?n) WHERE { <$CANARY_TREATMENT> ?p ?o }"

log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "FAILED: $*"; exit 1; }

# --- SPARQL helpers ---------------------------------------------------------

# sparql_url ENDPOINT QUERY: SPARQL JSON results from a public endpoint
sparql_url() {
  curl -fsS -m 300 -H 'Accept: application/sparql-results+json' \
    --data-urlencode "query=$2" "$1"
}

# sparql_container CONTAINER QUERY: SPARQL JSON results from a QLever container
sparql_container() {
  docker exec "$1" curl -fsS -m 300 -H 'Accept: application/sparql-results+json' \
    --data-urlencode "query=$2" http://localhost:7019
}

first_value() { jq -r '.results.bindings[0] | to_entries[0].value.value // empty'; }

# --- containers -------------------------------------------------------------

# start_server NAME INDEX_DIR: starts QLever on INDEX_DIR. The container is
# labelled for Traefik but only becomes healthy (and so gets traffic) once
# INDEX_DIR/.promoted exists. The access token is random and never leaves the
# container: nothing here needs privileged operations.
start_server() {
  local name=$1 dir=$2 image
  image=$(jq -r .image "$dir/stamp.json")
  docker run -d --name "$name" --restart unless-stopped \
    -u "$UIDGID" -v "$dir":/data -w /data \
    --network "$QP_NETWORK" \
    --label "$ROLE_LABEL=$ROLE" \
    --label "org.plazi.qlever.index=$(basename "$dir")" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.$QP_ROUTER.rule=Host(\`$QP_HOST\`)" \
    --label "traefik.http.routers.$QP_ROUTER.entrypoints=$QP_ENTRYPOINT" \
    --label "traefik.http.routers.$QP_ROUTER.tls=true" \
    ${QP_CERTRESOLVER:+--label "traefik.http.routers.$QP_ROUTER.tls.certresolver=$QP_CERTRESOLVER"} \
    --label "traefik.http.services.$QP_ROUTER.loadbalancer.server.port=7019" \
    --health-cmd 'test -f /data/.promoted && curl -fsS -o /dev/null "http://localhost:7019/?cmd=stats"' \
    --health-interval 5s --health-retries 1 --health-start-period 30m \
    --entrypoint sh "$image" -c \
    'exec qlever start --run-in-foreground --description "Plazi Treatments" --access-token "$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 32)"' \
    > /dev/null
}

# wait_until_answering NAME: waits until the server answers queries
wait_until_answering() {
  for _ in $(seq 600); do
    if docker exec "$1" curl -fsS -o /dev/null "http://localhost:7019/?cmd=stats" 2>/dev/null; then
      return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || break
    sleep 2
  done
  return 1
}

# wait_for_health NAME STATUS: waits until the container's health is STATUS
wait_for_health() {
  for _ in $(seq 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = "$2" ] && return 0
    sleep 2
  done
  return 1
}

# go_live NAME: makes indexes/NAME the served index. Its container must be
# answering already. Traefik routes only to healthy containers, so the new one
# gets traffic once its index is marked promoted; each old one is drained by
# removing that mark and only stopped once it is unhealthy (out of rotation)
# and its running queries had QP_DRAIN_SECONDS to finish.
go_live() {
  local name=$1 container=$QP_PREFIX-$1 old
  touch "$QP_ROOT/indexes/$name/.promoted"
  wait_for_health "$container" healthy || die "$container did not become healthy"
  ln -sfn "indexes/$name" "$QP_ROOT/current.new"
  mv -Tf "$QP_ROOT/current.new" "$QP_ROOT/current"
  # From here on the new index is live: whatever fails below, the exit trap
  # must not remove its container or directory.
  CANDIDATE='' BUILD_DIR=''
  log "live: $name"
  for old in $(docker ps -a --filter "label=$ROLE_LABEL=$ROLE" --format '{{.Names}}'); do
    [ "$old" = "$container" ] && continue
    log "draining $old"
    # Its index may live outside QP_ROOT (e.g. after QP_ROOT was moved)
    rm -f "$(data_dir "$old")/.promoted"
    wait_for_health "$old" unhealthy || log "$old did not turn unhealthy, stopping it anyway"
    sleep "$QP_DRAIN_SECONDS"
    { docker stop "$old" > /dev/null && docker rm "$old" > /dev/null; } ||
      log "WARNING: could not remove $old, it no longer gets traffic; remove it by hand"
  done
}

# data_dir CONTAINER: the host directory mounted at the container's /data
data_dir() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$1"
}

ensure_status_server() {
  local source
  source=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{end}}' "$QP_PREFIX-status" 2>/dev/null || true)
  if [ -n "$source" ] && [ "$source" != "$QP_ROOT/public" ]; then
    log "status server serves $source, recreating it for $QP_ROOT/public"
    docker rm -f "$QP_PREFIX-status" > /dev/null
  fi
  case $(docker inspect -f '{{.State.Running}}' "$QP_PREFIX-status" 2>/dev/null) in
    true) return ;;
    false) docker start "$QP_PREFIX-status" > /dev/null; return ;;
  esac
  docker run -d --name "$QP_PREFIX-status" --restart unless-stopped \
    -v "$QP_ROOT/public":/usr/share/nginx/html:ro \
    --network "$QP_NETWORK" \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.$QP_ROUTER-status.rule=Host(\`$QP_HOST\`) && PathPrefix(\`/status\`)" \
    --label "traefik.http.routers.$QP_ROUTER-status.entrypoints=$QP_ENTRYPOINT" \
    --label "traefik.http.routers.$QP_ROUTER-status.tls=true" \
    ${QP_CERTRESOLVER:+--label "traefik.http.routers.$QP_ROUTER-status.tls.certresolver=$QP_CERTRESOLVER"} \
    --label "traefik.http.services.$QP_ROUTER-status.loadbalancer.server.port=80" \
    nginx:alpine > /dev/null
}

# --- download verification --------------------------------------------------

# verify_export FILE: the turtle-hook-nq export must end with
# `# END till=<commit> lines=<n> sha256=<hex>` matching the lines before it.
# Sets NQ_TILL.
verify_export() {
  local file=$1 end lines sha actual_lines actual_sha
  end=$(tail -n 1 "$file")
  [[ $end =~ ^#\ END\ till=([0-9a-f]{40})\ lines=([0-9]+)\ sha256=([0-9a-f]{64})$ ]] ||
    die "export is truncated: last line is not the # END sentinel: ${end:0:200}"
  NQ_TILL=${BASH_REMATCH[1]} lines=${BASH_REMATCH[2]} sha=${BASH_REMATCH[3]}
  actual_lines=$(head -n -1 "$file" | wc -l)
  actual_sha=$(head -n -1 "$file" | sha256sum | cut -d' ' -f1)
  [ "$actual_lines" = "$lines" ] || die "export has $actual_lines lines, sentinel says $lines"
  [ "$actual_sha" = "$sha" ] || die "export sha256 is $actual_sha, sentinel says $sha"
  log "export verified: till=$NQ_TILL lines=$lines sha256=$sha"
}

# --- status -----------------------------------------------------------------

# write_status RESULT MESSAGE: status.json, status.svg, health and runs.json
write_status() {
  local result=$1 message=$2 stamp='{}' live_count lindas_count healthy=false ratio=null
  [ -f "$QP_ROOT/current/stamp.json" ] && stamp=$(cat "$QP_ROOT/current/stamp.json")
  live_count=$(sparql_url "$LIVE_ENDPOINT" "$TREATMENT_COUNT_QUERY" 2>/dev/null | first_value || true)
  lindas_count=$(sparql_url "$LINDAS" "$TREATMENT_COUNT_QUERY" 2>/dev/null | first_value || true)
  if [ -n "$live_count" ] && [ -n "$lindas_count" ]; then
    ratio=$(awk -v a="$live_count" -v b="$lindas_count" 'BEGIN { printf "%.4f", a / b }')
    if [ "$result" != failed ] && awk -v r="$ratio" -v m="$QP_MIN_RATIO" 'BEGIN { exit !(r >= m) }'; then
      healthy=true
    fi
  fi
  mkdir -p "$PUBLIC"
  jq -n --arg checked "$(date -u +%FT%TZ)" --arg run "$RUN_ID" --arg result "$result" \
    --arg message "$message" --argjson index "$stamp" --arg live "${live_count:-}" \
    --arg lindas "${lindas_count:-}" --argjson ratio "$ratio" --argjson healthy "$healthy" '{
      checked_at: $checked, run: $run, result: $result, message: $message,
      log: "logs/\($run).txt", healthy: $healthy,
      treatments: { live: ($live | tonumber? // null), lindas: ($lindas | tonumber? // null), ratio: $ratio },
      index: $index,
      index_age_hours: (try ((now - ($index.built_at | fromdateiso8601)) / 3600 | floor) catch null)
    }' > "$PUBLIC/status.json.new"
  mv -f "$PUBLIC/status.json.new" "$PUBLIC/status.json"
  if [ "$healthy" = true ]; then echo ok > "$PUBLIC/health"; else rm -f "$PUBLIC/health"; fi
  "$REPO_DIR/scripts/status-badge.sh" "$PUBLIC/status.json" > "$PUBLIC/status.svg.new"
  mv -f "$PUBLIC/status.svg.new" "$PUBLIC/status.svg"
  # runs.json: newest first, like hooknq's jobs.json
  { jq -c '{run, result, message, log, checked_at}' "$PUBLIC/status.json"
    [ -f "$PUBLIC/runs.json" ] && jq -c '.[]' "$PUBLIC/runs.json"
  } | head -n 200 | jq -s . > "$PUBLIC/runs.json.new"
  mv -f "$PUBLIC/runs.json.new" "$PUBLIC/runs.json"
  ls -1t "$PUBLIC/logs"/*.txt 2>/dev/null | tail -n +201 | xargs -r rm -f
}

# --- indexes ----------------------------------------------------------------

# prune: keeps the newest QP_KEEP indexes (and the live one in any case), and
# removes the build directories of runs that were killed before their cleanup
prune() {
  local old
  for old in "$QP_ROOT"/indexes/.build-*/; do
    [ -d "$old" ] || continue
    log "removing $(basename "$old"), left by an interrupted run"
    rm -rf "${old%/}"
  done
  ls -1 "$QP_ROOT/indexes" | { grep -v '^\.' || true; } | sort -r | tail -n +"$((QP_KEEP + 1))" | while read -r old; do
    [ "$QP_ROOT/indexes/$old" -ef "$QP_ROOT/current" ] && continue
    log "removing old index $old"
    rm -rf "${QP_ROOT:?}/indexes/$old"
  done
}

# --- commands ---------------------------------------------------------------

cmd_run() {
  local jobs col_release col_tag col_url live_stamp live_till='' live_col='' work name dir
  local col_version nq_treatments image count baseline col_marker kingdoms canary lindas_count

  jobs=$(curl -fsS "$HOOKNQ/jobs.json?from=0&till=2") || die "cannot read $HOOKNQ/jobs.json"
  local till
  till=$(jq -r '[.[] | select(.status == "completed")][0].job.till // empty' <<< "$jobs")
  [ -n "$till" ] || die "no completed hooknq job in $HOOKNQ/jobs.json?from=0&till=2"
  col_release=$(curl -fsS "https://api.github.com/repos/$COL_REPO/releases/latest") ||
    die "cannot read the latest $COL_REPO release"
  col_tag=$(jq -r .tag_name <<< "$col_release")
  col_url=$(jq -r '[.assets[] | select(.name | test("^col\\.(nt|ttl)\\.gz$"))][0].browser_download_url // empty' <<< "$col_release")
  [ -n "$col_url" ] || die "no col.nt.gz/col.ttl.gz asset in $COL_REPO release $col_tag"
  log "latest: hooknq till=$till, CoL release $col_tag"

  live_stamp=$QP_ROOT/current/stamp.json
  if [ -f "$live_stamp" ]; then
    live_till=$(jq -r .till "$live_stamp"); live_col=$(jq -r .col_release "$live_stamp")
    log "live:   hooknq till=$live_till, CoL release $live_col ($(readlink "$QP_ROOT/current"))"
  fi
  if [ "$till" = "$live_till" ] && [ "$col_tag" = "$live_col" ] && [ "$QP_FORCE" != 1 ]; then
    log "skipped — no change"
    RESULT=skipped MESSAGE="no change"
    return
  fi

  # Whatever is due to go goes first, so that it counts as free
  prune
  local free_gb
  free_gb=$(df --output=avail -BG "$QP_ROOT" | tail -n 1 | tr -dc 0-9 || true)
  [ -n "$free_gb" ] || die "cannot tell the free space on the disk of $QP_ROOT"
  [ "$free_gb" -ge "$QP_MIN_FREE_GB" ] ||
    die "only ${free_gb} GB free on the disk of $QP_ROOT, a build needs at least $QP_MIN_FREE_GB (QP_MIN_FREE_GB)"
  log "${free_gb} GB free on the disk of $QP_ROOT"

  work=$QP_ROOT/indexes/.build-$RUN_ID
  BUILD_DIR=$work
  mkdir -p "$work"
  cp "$REPO_DIR/Qleverfile" "$work/Qleverfile"

  log "downloading $NQ_URL"
  curl -fsS "$NQ_URL" -o "$work/treatments.nq"
  log "treatments.nq: $(stat -c %s "$work/treatments.nq") bytes"
  verify_export "$work/treatments.nq"
  # The export names the newest job completed when it started, which may be
  # newer than the one gated on above if a job finished meanwhile; anything
  # not among the recently completed jobs is a stale export.
  if [ "$NQ_TILL" != "$till" ]; then
    curl -fsS "$HOOKNQ/jobs.json?from=0&till=20" |
      jq -e --arg t "$NQ_TILL" 'any(.[]; .status == "completed" and .job.till == $t)' > /dev/null ||
      die "export is of till=$NQ_TILL, which is not among the recently completed hooknq jobs (latest: $till)"
    log "export is of till=$NQ_TILL, completed after the gate read $till"
  fi
  nq_treatments=$(grep -c -F '<http://plazi.org/vocab/treatment#Treatment> <' "$work/treatments.nq" || true)
  log "treatments in export: $nq_treatments"

  log "downloading CoL release $col_tag: $col_url"
  curl -fsSL "$col_url" | gunzip -c > "$work/col.nt"
  col_version=$(grep -m 1 -F '<https://www.catalogueoflife.org/data> <http://www.w3.org/2002/07/owl#versionInfo> ' "$work/col.nt" |
    sed -E 's/.*"([^"]*)".*/\1/')
  [ -n "$col_version" ] || die "col.nt has no owl:versionInfo on <https://www.catalogueoflife.org/data>"
  log "col.nt: $(wc -l < "$work/col.nt") lines, CoL version $col_version"

  docker pull -q "$QP_IMAGE" > /dev/null
  image=$(docker image inspect -f '{{index .RepoDigests 0}}' "$QP_IMAGE")
  log "indexing with $image"
  docker run --rm --name "$QP_PREFIX-index-$RUN_ID" -u "$UIDGID" -v "$work":/data -w /data \
    --entrypoint qlever "$image" index
  rm -f "$work/treatments.nq" "$work/col.nt"

  name="${RUN_ID}_${NQ_TILL:0:7}_col-${col_version}"
  dir=$QP_ROOT/indexes/$name
  jq -n --arg built "$(date -u +%FT%TZ)" --arg till "$NQ_TILL" --arg col_release "$col_tag" \
    --arg col_version "$col_version" --arg image "$image" --arg n "$nq_treatments" '{
      built_at: $built, till: $till, col_release: $col_release, col_version: $col_version,
      image: $image, treatments_in_export: ($n | tonumber)
    }' > "$work/stamp.json"
  [ ! -e "$dir" ] || die "$dir exists already"
  mv "$work" "$dir"
  BUILD_DIR=$dir

  log "starting candidate server on $name"
  CANDIDATE=$QP_PREFIX-$name
  start_server "$CANDIDATE" "$dir"
  wait_until_answering "$CANDIDATE" || die "candidate server did not start"

  log "checks"
  count=$(sparql_container "$CANDIDATE" "$TREATMENT_COUNT_QUERY" | first_value)
  baseline=$(sparql_url "$LIVE_ENDPOINT" "$TREATMENT_COUNT_QUERY" 2>/dev/null | first_value || true)
  if [ -z "$baseline" ] && [ -f "$live_stamp" ]; then
    baseline=$(jq -r '.treatments // empty' "$live_stamp")
    log "live endpoint not answering, using the count of the live index stamp"
  fi
  if [ -n "$baseline" ]; then
    log "  treatments: $count, live: $baseline"
    awk -v c="$count" -v b="$baseline" -v m="$QP_MIN_RATIO" 'BEGIN { exit !(c >= m * b) }' ||
      die "new index has $count treatments, less than $QP_MIN_RATIO of the live $baseline"
  elif [ "$QP_FORCE" = 1 ]; then
    log "  treatments: $count, no live count to compare with (first build, QP_FORCE=1)"
  else
    die "no live treatment count to compare with (set QP_FORCE=1 for a first build without one)"
  fi
  col_marker=$(sparql_container "$CANDIDATE" "$COL_VERSION_QUERY" | first_value)
  log "  CoL marker: $col_marker"
  [ "$col_marker" = "$col_version" ] || die "CoL marker is '$col_marker', expected '$col_version'"
  kingdoms=$(sparql_container "$CANDIDATE" "$KINGDOMS_QUERY" | jq -r '.results.bindings[].kingdom.value')
  log "  kingdoms: $(echo "$kingdoms" | wc -l)"
  grep -qx Plantae <<< "$kingdoms" || die "kingdoms canary does not return Plantae"
  canary=$(sparql_container "$CANDIDATE" "$CANARY_QUERY" | first_value)
  log "  <$CANARY_TREATMENT>: $canary triples"
  [ "${canary:-0}" -gt 0 ] || die "<$CANARY_TREATMENT> does not resolve"
  lindas_count=$(sparql_url "$LINDAS" "$TREATMENT_COUNT_QUERY" 2>/dev/null | first_value || true)
  log "  LINDAS: ${lindas_count:-unavailable} treatments (not a gate)"
  jq --arg n "$count" '.treatments = ($n | tonumber)' "$dir/stamp.json" > "$dir/stamp.json.new"
  mv -f "$dir/stamp.json.new" "$dir/stamp.json"

  go_live "$name"
  RESULT=promoted MESSAGE="$name: $count treatments"
  prune
}

cmd_rollback() {
  local name=${1:?usage: qlever-plazi.sh rollback NAME}
  [ -f "$QP_ROOT/indexes/$name/stamp.json" ] || die "no index $name (see: qlever-plazi.sh list)"
  [ "$(readlink "$QP_ROOT/current")" = "indexes/$name" ] && die "$name is already live"
  log "rolling back to $name"
  docker rm -f "$QP_PREFIX-$name" > /dev/null 2>&1 || true
  rm -f "$QP_ROOT/indexes/$name/.promoted"
  start_server "$QP_PREFIX-$name" "$QP_ROOT/indexes/$name"
  CANDIDATE=$QP_PREFIX-$name
  wait_until_answering "$CANDIDATE" || die "server on $name did not start"
  go_live "$name"
  RESULT=promoted MESSAGE="rollback to $name"
}

cmd_list() {
  local current
  current=$(readlink "$QP_ROOT/current" 2>/dev/null || true)
  for d in "$QP_ROOT"/indexes/*/; do
    d=${d%/}
    [ -f "$d/stamp.json" ] || continue
    printf '%s %s %s\n' "$([ "indexes/$(basename "$d")" = "$current" ] && echo '*' || echo ' ')" \
      "$(basename "$d")" "$(jq -c '{treatments, till: .till[0:7], col_version}' "$d/stamp.json")"
  done
}

# KEY=value lines; install.sh reads the settings from here, so that it gets
# the same values as the runs
cmd_settings() {
  local key
  for key in "${SETTINGS[@]}"; do
    echo "$key=${!key}"
  done
}

# settings_problem: what is wrong with the settings, if anything
settings_problem() {
  if [ -n "$CONFIG_ERROR" ]; then
    echo "$CONFIG_ERROR"
  elif [ -z "$QP_NETWORK" ] && [ ! -e "$QP_CONFIG" ]; then
    echo "no $QP_CONFIG with the settings of this host (see qlever-plazi.env.example)"
  elif [ -z "$QP_NETWORK" ]; then
    echo "QP_NETWORK is not set in $QP_CONFIG: the Docker network Traefik uses"
  elif [[ ! $QP_KEEP =~ ^[0-9]+$ || ! $QP_MIN_FREE_GB =~ ^[0-9]+$ ]]; then
    echo "QP_KEEP and QP_MIN_FREE_GB must be whole numbers"
  fi
}

# Cleanup and status for run/rollback: a failed build leaves the live index
# untouched and is removed, except for its log.
finish() {
  local code=$?
  if [ -n "${CANDIDATE:-}" ]; then
    docker rm -f "$CANDIDATE" > /dev/null 2>&1 || true
  fi
  if [ "$code" != 0 ]; then
    RESULT=failed MESSAGE=$(grep -h 'FAILED: ' "$LOG" | tail -n 1 | sed 's/.*FAILED: //' || true)
    MESSAGE=${MESSAGE:-exit code $code, see log}
    [ -n "${BUILD_DIR:-}" ] && rm -rf "$BUILD_DIR"
    log "the live index is unchanged"
  fi
  write_status "${RESULT:-failed}" "${MESSAGE:-}" || log "could not write status"
  log "done: ${RESULT:-failed} ${MESSAGE:-}"
}

main() {
  local cmd=${1:-} problem
  shift || true
  case $cmd in
    run | rollback | list | settings) ;;
    *) echo "usage: $0 run | rollback NAME | list | settings" >&2; exit 2 ;;
  esac

  # The status is written to QP_ROOT, so this problem only shows in the journal
  # (the service gets a checked QP_ROOT from install.sh)
  if [[ $QP_ROOT != /* || $QP_ROOT == *[[:space:]%]* || $(realpath -ms -- "$QP_ROOT") == / ]]; then
    echo "QP_ROOT must be an absolute path other than /, without spaces or %, not '$QP_ROOT'" >&2
    exit 2
  fi
  problem=$(settings_problem)
  case $cmd in
    list) cmd_list; return ;;
    settings) [ -z "$problem" ] || { echo "$problem" >&2; exit 2; }; cmd_settings; return ;;
  esac

  mkdir -p "$QP_ROOT/indexes" "$PUBLIC/logs"
  exec 9> "$QP_ROOT/.lock"
  flock -n 9 || { echo "another run is active" >&2; exit 1; }

  RUN_ID=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  LOG=$PUBLIC/logs/$RUN_ID.txt
  exec > >(tee -a "$LOG") 2>&1
  trap finish EXIT
  log "qlever-plazi $cmd $* ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
  # Failing here rather than before the trap writes a failed status, which
  # takes down the health file, so that monitoring notices
  [ -z "$problem" ] || die "$problem"
  ensure_status_server
  "cmd_$cmd" "$@"
}

main "$@"
