#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="bom-relay"
CONTAINER_NAME="bom-relay"
PORT="${PORT:-8080}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[deploy_oracle] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl

log "Building relay image (${IMAGE_NAME}) from ${WORKDIR}..."
docker build -t "${IMAGE_NAME}" "${WORKDIR}"

if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  log "Removing existing container ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null
fi

log "Starting container ${CONTAINER_NAME} on port ${PORT}..."
docker run -d \
  --restart unless-stopped \
  --name "${CONTAINER_NAME}" \
  -e PORT="${PORT}" \
  -p "${PORT}:${PORT}" \
  "${IMAGE_NAME}" >/dev/null

log "Waiting for health endpoint..."
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null; then
    break
  fi
  sleep 1
done

log "Relay response:"
curl -fsS "http://127.0.0.1:${PORT}" || {
  echo "Relay failed health check" >&2
  exit 1
}

echo
log "Done. Ensure Oracle Security List + host firewall allow TCP ${PORT}."
