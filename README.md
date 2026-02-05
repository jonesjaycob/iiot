# Cloud-Native SCADA Replacement

Kubernetes-native IIoT stack replacing traditional SCADA, managed by Flux GitOps on Docker Desktop.

```
OPC UA Mock Server
       |
   Akri (discovers OPC UA endpoints)
       |
  OPC UA -> Kafka Bridge
       |
   AutoMQ (Kafka-compatible, S3-backed via MinIO)
       |
  +----+----+
  |         |
InfluxDB   MinIO/S3
(historian) (raw archive)
  |
Grafana
(dashboards)
```

## Prerequisites

- **Docker Desktop** with Kubernetes enabled
  - Settings -> Kubernetes -> Enable Kubernetes
  - Recommended: 8GB RAM, 4 CPUs allocated to Docker Desktop
- **flux** CLI: `brew install fluxcd/tap/flux`
- **kubectl**: `brew install kubectl`

## Quick Start

```bash
# 1. Install Flux into your cluster
flux install

# 2. Wait for Flux controllers
kubectl -n flux-system wait --for=condition=available --timeout=120s \
  deployment/helm-controller \
  deployment/kustomize-controller \
  deployment/notification-controller \
  deployment/source-controller

# 3. Create namespaces and Helm sources
kubectl apply -f infrastructure/namespaces/namespaces.yaml
kubectl apply -f infrastructure/sources/

# 4. Deploy MinIO (must be first -- AutoMQ depends on it)
kubectl apply -k infrastructure/minio/
kubectl -n industrial-iot wait --for=condition=Ready helmrelease/minio --timeout=300s

# 5. Deploy AutoMQ
kubectl apply -k infrastructure/automq/

# 6. Deploy InfluxDB
kubectl apply -k infrastructure/influxdb/
kubectl -n monitoring wait --for=condition=Ready helmrelease/influxdb2 --timeout=300s

# 7. Deploy Grafana
kubectl apply -k infrastructure/grafana/
kubectl -n monitoring wait --for=condition=Ready helmrelease/grafana --timeout=300s

# 8. Deploy Kafka UI
kubectl apply -k infrastructure/kafka-ui/

# 9. Deploy applications
kubectl apply -k apps/opcua-mock/
kubectl apply -k apps/akri/
kubectl apply -k apps/opcua-kafka-bridge/
```

Or use the bootstrap script:

```bash
./scripts/bootstrap.sh
```

## Verify

```bash
# Check all pods
kubectl get pods -n flux-system
kubectl get pods -n industrial-iot
kubectl get pods -n monitoring

# Check Helm releases
kubectl get helmreleases -A

# Verify Akri discovered the OPC UA server
kubectl get akrii -n industrial-iot

# Verify AutoMQ topics
kubectl exec -n industrial-iot automq-broker-0 -- \
  /opt/kafka/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Verify MinIO buckets
kubectl exec -n industrial-iot deploy/minio -- mc alias set local http://localhost:9000 minioadmin minio-secret-key-change-me
kubectl exec -n industrial-iot deploy/minio -- mc ls local/
```

## Access Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:30300 | admin / admin |
| MinIO Console | http://localhost:30301 | minioadmin / minio-secret-key-change-me |
| Kafka UI | http://localhost:30302 | (no auth) |

Or use port-forwarding:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
kubectl port-forward -n industrial-iot svc/minio-console 9001:9001
```

## Architecture

### Namespaces

- `industrial-iot` -- Akri, OPC UA mock, AutoMQ, bridge, MinIO
- `monitoring` -- InfluxDB, Grafana

### Dependency Order (enforced by Flux)

```
1. Namespaces + Helm sources
2. MinIO         (S3 must be ready for AutoMQ)
3. AutoMQ        (streaming must be ready for bridge)
4. InfluxDB      (historian must be ready for Grafana)
5. Grafana
6. OPC UA Mock
7. Akri          (discovers mock server)
8. Bridge        (connects OPC UA to AutoMQ)
```

### Components

| Component | Image / Chart | Namespace |
|-----------|--------------|-----------|
| MinIO | `minio/minio` Helm chart | industrial-iot |
| AutoMQ Controller | `automqinc/automq:latest` | industrial-iot |
| AutoMQ Broker | `automqinc/automq:latest` | industrial-iot |
| InfluxDB 2.x | `influxdata/influxdb2` Helm chart | monitoring |
| Grafana | `grafana/grafana` Helm chart | monitoring |
| Kafka UI (Kafbat) | `ghcr.io/kafbat/kafka-ui:latest` | industrial-iot |
| OPC UA Mock | `mcr.microsoft.com/iotedge/opc-plc:latest` | industrial-iot |
| Akri | `akri-helm-charts/akri` Helm chart | industrial-iot |
| Bridge | Placeholder (alpine) -- see below | industrial-iot |

### OPC UA Kafka Bridge

The bridge deployment is currently a **placeholder**. To make it functional, build a custom container that:

1. Connects to the OPC UA server using an OPC UA client library (e.g., `node-opcua`, `asyncua`)
2. Subscribes to the node IDs listed in the ConfigMap
3. Publishes telemetry to AutoMQ via a Kafka producer (e.g., `kafkajs`, `confluent-kafka-python`)
4. Optionally writes directly to InfluxDB

The ConfigMap at `apps/opcua-kafka-bridge/configmap.yaml` has the endpoint and topic configuration ready.

## Teardown

```bash
# Remove apps
kubectl delete -k apps/opcua-kafka-bridge/
kubectl delete -k apps/akri/
kubectl delete -k apps/opcua-mock/

# Remove infrastructure (reverse order)
kubectl delete -k infrastructure/kafka-ui/
kubectl delete -k infrastructure/grafana/
kubectl delete -k infrastructure/influxdb/
kubectl delete -k infrastructure/automq/
kubectl delete -k infrastructure/minio/

# Remove namespaces and sources
kubectl delete -f infrastructure/sources/
kubectl delete -f infrastructure/namespaces/namespaces.yaml

# Uninstall Flux
flux uninstall
```

## Secrets (Local Dev Only)

| Secret | Namespace | Keys |
|--------|-----------|------|
| `minio-credentials` | industrial-iot | `rootUser`, `rootPassword` |
| `influxdb-auth` | monitoring | `admin-password`, `admin-token` |
| `influxdb-auth` | industrial-iot | `admin-token` (copy for bridge) |

For production, replace with Sealed Secrets or SOPS.
