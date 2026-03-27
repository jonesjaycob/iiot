# Cloud-Native SCADA Replacement

Kubernetes-native IIoT stack replacing traditional SCADA, managed by Flux GitOps on Docker Desktop.

```
       NOAA Weather API
              |
        Spark (fetch + transform)
              |
    +---------+---------+
    |                   |
  MinIO/S3           AutoMQ
  (parquet archive)  (critical alerts topic)
    |
  Spark (compaction CronJob)
    |
  Argo Workflows (orchestration)
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

# 6. Deploy Spark compaction (CronJob)
kubectl apply -k infrastructure/spark/

# 7. Deploy Argo Workflows
kubectl apply -k infrastructure/argo/

# 8. Deploy NOAA alerts pipeline
kubectl apply -k apps/noaa-alerts/
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

# Check Helm releases
kubectl get helmreleases -A

# Verify AutoMQ topics
kubectl exec -n industrial-iot automq-broker-0 -- \
  /opt/kafka/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Verify MinIO buckets
kubectl exec -n industrial-iot deploy/minio -- mc alias set local http://localhost:9000 minioadmin minio-secret-key-change-me
kubectl exec -n industrial-iot deploy/minio -- mc ls local/

# Check Spark compaction CronJob
kubectl get cronjob -n industrial-iot

# Check Argo CronWorkflows
kubectl get cronworkflows -n industrial-iot

# Check NOAA alerts output in MinIO
kubectl exec -n industrial-iot deploy/minio -- mc ls local/process-archive/noaa-alerts/
```

## Access Services

| Service | URL | Credentials |
|---------|-----|-------------|
| MinIO Console | http://localhost:30301 | minioadmin / minio-secret-key-change-me |
| Argo Workflows | http://localhost:30500 | (no auth) |
| AutoMQ (Kafka) | localhost:30092 | (no auth) |

Or use port-forwarding:

```bash
kubectl port-forward -n industrial-iot svc/minio-console 9001:9001
```

### External Kafka Access

AutoMQ exposes an `EXTERNAL` listener on NodePort `30092` for clients running outside the cluster. Use `localhost:30092` as your bootstrap server:

```bash
# Produce
kafka-console-producer.sh --bootstrap-server localhost:30092 --topic test

# Consume
kafka-console-consumer.sh --bootstrap-server localhost:30092 --topic test --from-beginning
```

Any Kafka-compatible client library can connect using `localhost:30092` as the bootstrap address.

## Architecture

### Namespaces

- `industrial-iot` -- AutoMQ, MinIO, Spark, Argo Workflows, NOAA Alerts

### Dependency Order (enforced by Flux)

```
1. Namespaces + Helm sources
2. MinIO            (S3 must be ready for AutoMQ + Spark)
3. AutoMQ           (streaming)
4. Spark            (compaction CronJob, needs MinIO)
5. Argo Workflows   (workflow orchestration)
6. NOAA Alerts      (Argo CronWorkflow, needs Spark + AutoMQ + MinIO)
```

### Components

| Component | Image / Chart | Namespace |
|-----------|--------------|-----------|
| MinIO | `minio/minio` Helm chart | industrial-iot |
| AutoMQ Controller | `automqinc/automq:latest` | industrial-iot |
| AutoMQ Broker | `automqinc/automq:latest` | industrial-iot |
| Spark Compaction | `apache/spark:3.5.4-python3` (CronJob) | industrial-iot |
| Argo Workflows | `argo/argo-workflows` Helm chart | industrial-iot |
| NOAA Alerts | `apache/spark:3.5.4-python3` (Argo CronWorkflow) | industrial-iot |

### NOAA Critical Alerts Pipeline

The `noaa-alerts` app runs as an Argo CronWorkflow every 15 minutes:

1. Fetches active Extreme/Severe weather alerts from the NOAA Weather API (`api.weather.gov`)
2. Parses GeoJSON features into a structured Spark DataFrame
3. Writes partitioned Parquet files to `s3://process-archive/noaa-alerts/` in MinIO
4. Publishes alert summaries to the `noaa-critical-alerts` topic on AutoMQ

Consume alerts from outside the cluster:

```bash
kafka-console-consumer.sh --bootstrap-server localhost:30092 \
  --topic noaa-critical-alerts --from-beginning
```

## Teardown

```bash
# Remove apps
kubectl delete -k apps/noaa-alerts/

# Remove infrastructure (reverse order)
kubectl delete -k infrastructure/argo/
kubectl delete -k infrastructure/spark/
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
| `spark-s3-credentials` | industrial-iot | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

For production, replace with Sealed Secrets or SOPS.
