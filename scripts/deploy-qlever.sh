#!/usr/bin/env bash
set -euo pipefail

# Deploy script for the qlever service
# - Builds docker image from this repo
# - Pushes image to registry as plazi/qleverplazi:TAG (default TAG=latest)
# - Pulls the image in the target compose file and recreates the `qleverplazi` service
#
# Cron installation (example):
# 1) Ensure the user running cron can run `docker` (belongs to the docker group or use root).
# 2) Use absolute paths in crontab. Example daily at 02:00 and log output:
#    0 2 * * * /bin/bash -lc 'cd /home/reto/qlever-plazi && ./scripts/deploy-qlever.sh >> /var/log/deploy-qlever.log 2>&1'
# 3) To avoid concurrent runs, use `flock` (recommended):
#    0 2 * * * /usr/bin/flock -n /var/lock/deploy-qlever.lock /bin/bash -lc 'cd /home/reto/qlever-plazi && ./scripts/deploy-qlever.sh >> /var/log/deploy-qlever.log 2>&1'
# 4) Make the script executable once:
#    chmod +x /home/reto/qlever-plazi/scripts/deploy-qlever.sh
#
# Notes:
#  - Cron provides a minimal environment; ensure `docker` is on PATH or use full path to docker binary.
#  - The compose file must reference the same image name (with or without tag). If the compose pins a tag,
#    pass that tag to this script.

REPO_DIR="/home/reto/qlever-plazi"
IMAGE_NAME="plazi/qleverplazi"
COMPOSE_FILE="/fastssd/vmi178314-config/docker-compose.yml"
SERVICE="qleverplazi"
TAG="${1:-latest}"

echo "Using tag: $TAG"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found in PATH" >&2
  exit 2
fi

if [ ! -d "$REPO_DIR" ]; then
  echo "Repository directory $REPO_DIR not found" >&2
  exit 3
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Compose file $COMPOSE_FILE not found" >&2
  exit 4
fi

echo "Building image ${IMAGE_NAME}:${TAG} from $REPO_DIR"
cd "$REPO_DIR"
docker build -t "${IMAGE_NAME}:${TAG}" .

echo "Pushing image ${IMAGE_NAME}:${TAG}"
docker push "${IMAGE_NAME}:${TAG}"

echo "Telling docker-compose to pull the new image and recreate service $SERVICE"
docker compose -f "$COMPOSE_FILE" pull "$SERVICE" || true
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE"

echo "Done. Service $SERVICE recreated using ${IMAGE_NAME}:${TAG}."

cat <<'USAGE'
Usage:
  ./scripts/deploy-qlever.sh [TAG]

Examples:
  ./scripts/deploy-qlever.sh            # builds/pushes plazi/qleverplazi:latest and recreates service
  ./scripts/deploy-qlever.sh v1.2.3     # builds/pushes plazi/qleverplazi:v1.2.3 and recreates service

Notes:
  - Ensure you are logged in to the registry (e.g. `docker login`) before running the script.
  - The compose file must reference the same image name (with or without tag) for pull/up to use the pushed image.
USAGE
