#!/usr/bin/env bash
set -euo pipefail

#
# Cloud-Native SCADA — Bootstrap Script
# Installs Flux and bootstraps the GitOps repository on Docker Desktop Kubernetes
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_PATH="clusters/local"

echo "=== Cloud-Native SCADA Bootstrap ==="
echo ""

# ── Pre-flight checks ──────────────────────────────────────────────────

echo "Checking prerequisites..."

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Install it first."
  exit 1
fi

if ! command -v flux &>/dev/null; then
  echo "ERROR: flux CLI not found. Install with:"
  echo "  brew install fluxcd/tap/flux"
  exit 1
fi

# Verify we're talking to docker-desktop
CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ "$CONTEXT" != "docker-desktop" ]]; then
  echo "WARNING: Current kubectl context is '$CONTEXT', expected 'docker-desktop'."
  read -rp "Continue anyway? (y/N): " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "kubectl context: $CONTEXT"
echo ""

# ── Check Flux prerequisites ──────────────────────────────────────────

echo "Running Flux pre-flight checks..."
flux check --pre
echo ""

# ── Install Flux ──────────────────────────────────────────────────────

echo "Installing Flux components..."
flux install
echo ""

echo "Waiting for Flux controllers to be ready..."
kubectl -n flux-system wait --for=condition=available --timeout=120s \
  deployment/helm-controller \
  deployment/kustomize-controller \
  deployment/notification-controller \
  deployment/source-controller
echo "Flux controllers are ready."
echo ""

# ── Initialize git repo if needed ─────────────────────────────────────

cd "$REPO_ROOT"
if [[ ! -d .git ]]; then
  echo "Initializing git repository..."
  git init
  git add -A
  git commit -m "Initial commit: Cloud-Native SCADA stack"
  echo ""
fi

# ── Create GitRepository source ───────────────────────────────────────
# For local development, we use a local git source via port-forward or
# apply manifests directly. For a real setup, replace with your Git URL.

echo "Applying infrastructure and apps Kustomizations..."

# Apply cluster-level Flux Kustomizations
# Since we're running locally without a remote Git repo, we apply the
# kustomize manifests directly for the initial bootstrap.

echo "Creating namespaces..."
kubectl apply -f "$REPO_ROOT/infrastructure/namespaces/namespaces.yaml"

echo "Applying Helm repositories..."
kubectl apply -f "$REPO_ROOT/infrastructure/sources/"

echo ""
echo "Applying infrastructure components..."
kubectl apply -k "$REPO_ROOT/infrastructure/minio/"
echo "Waiting for MinIO to be ready..."
kubectl -n industrial-iot wait --for=condition=available --timeout=180s \
  deployment/minio 2>/dev/null || echo "  (MinIO deployment may use a different name from Helm — check with kubectl get pods -n industrial-iot)"

echo ""
echo "Applying AutoMQ..."
kubectl apply -k "$REPO_ROOT/infrastructure/automq/"

echo ""
echo "Applying InfluxDB..."
kubectl apply -k "$REPO_ROOT/infrastructure/influxdb/"

echo ""
echo "Applying Nessie catalog..."
kubectl apply -k "$REPO_ROOT/infrastructure/nessie/"

echo ""
echo "Applying Trino..."
kubectl apply -k "$REPO_ROOT/infrastructure/trino/"

echo ""
echo "Applying Iceberg init job..."
kubectl apply -k "$REPO_ROOT/infrastructure/iceberg-init/"

echo ""
echo "Applying Spark compaction..."
kubectl apply -k "$REPO_ROOT/infrastructure/spark/"

echo ""
echo "Applying Grafana..."
kubectl apply -k "$REPO_ROOT/infrastructure/grafana/"

echo ""
echo "Applying application components..."
kubectl apply -k "$REPO_ROOT/apps/opcua-mock/"
kubectl apply -k "$REPO_ROOT/apps/akri/"
kubectl apply -k "$REPO_ROOT/apps/opcua-kafka-bridge/"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n industrial-iot     # Check IIoT workloads"
echo "  kubectl get pods -n monitoring         # Check monitoring stack"
echo "  kubectl get pods -n flux-system        # Check Flux controllers"
echo ""
echo "Access services:"
echo "  Grafana:       http://localhost:30300   (admin/admin)"
echo "  MinIO Console: http://localhost:30301   (minioadmin/minio-secret-key-change-me)"
echo "  Kafka UI:      http://localhost:30302   (no auth)"
echo "  Trino:         http://localhost:30303   (no auth)"
echo ""
echo "Port-forward shortcuts:"
echo "  kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo "  kubectl port-forward -n industrial-iot svc/minio-console 9001:9001"
echo "  kubectl port-forward -n industrial-iot svc/trino 8080:8080"
echo ""
echo "Verify Akri discovered OPC UA server:"
echo "  kubectl get akrii -n industrial-iot"
echo ""
echo "Check AutoMQ topics:"
echo "  kubectl exec -n industrial-iot automq-broker-0 -- kafka-topics.sh --bootstrap-server localhost:9092 --list"
