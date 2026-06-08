#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Copy .env.example to .env and set HOST_IP."
  exit 1
fi

echo "Pulling latest images..."
docker compose pull

echo "Starting LGTM stack..."
docker compose up -d

echo "Waiting for Grafana to be ready..."
until curl -sf http://localhost:3000/api/health > /dev/null 2>&1; do
  sleep 2
done

echo ""
echo "Stack is up."
echo ""
echo "  Grafana:  http://localhost:3000"
echo "  Mimir:    http://localhost:9009  (remote_write to /api/v1/push)"
echo "  Loki:     http://localhost:3100  (push to /loki/api/v1/push)"
echo "  Tempo:    http://localhost:3200  (OTLP gRPC :4317 / HTTP :4318)"
echo ""
echo "From the cluster, replace 'localhost' with: $(grep HOST_IP .env | cut -d= -f2)"
