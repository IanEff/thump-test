# Workspace Log

## 2026-08-05 - Go GCP SDK Consultation
- Evaluated Go Cloud Client Libraries (`cloud.google.com/go/compute/apiv1`) vs `provisioning/scripts/ripcord.sh` for infrastructure standup and teardown.
- Created detailed architectural writeup and Go reference implementation in `~/Documents/vault/Projects/thump-test.md`.

## 2026-08-14 - Accelerate Prometheus and GitOps Convergence
- Root-cause analyzed cold-boot GitOps convergence latency for Prometheus and core infrastructure.
- Identified primary delay vectors:
  1. Missing Prometheus Operator CRD pre-bootstrap in `provisioning/scripts/install_argocd.sh`, causing initial sync failures for `prometheus`, `sloth`, and `ceph-latency-bridge`.
  2. Aggressive exponential retry backoff (`duration: 10s`, `factor: 2`, `maxDuration: 3m`) causing multi-minute idle stalls when transient CRD registration races occurred.
  3. Unvendored Helm charts requiring runtime network fetches by `argocd-repo-server`.
- Remediated by:
  - Vendoring all missing chart caches (`prometheus-operator-crds`, `grafana`, `loki`, `promtail`, `chaos-mesh`, `kyverno`).
  - Adding Prometheus Operator CRD pre-bootstrap step (`[4b]`) to `install_argocd.sh`.
  - Tuning Application retry backoff to `duration: 5s`, `factor: 2`, `maxDuration: 1m` across `infra-set.yaml`, `rook-set.yaml`, `apps-set.yaml`, `rook-cluster.yaml`, and `s3-traffic-generator.yaml`.
  - Adding `reposerver.parallelism.limit: "20"` to `argocd-cmd-params-cm` in `cluster-bootstrap/argocd/kustomization.yaml`.

## 2026-08-16 - Context Guarding, Go SDK Parallel Ripcord, and Golden Image Pipeline
- Explicitly guarded all `kubectl` invocations in `justfile` (and `boot_timeline.py`) with `--context={{cluster_name}}` to prevent unintended operations against live/dev clusters when ambient contexts differ.
- Implemented native Go SDK parallel DAG ripcord engine in `provisioning/cmd/ripcord/main.go` using `cloud.google.com/go/compute/apiv1`, `cloud.google.com/go/storage`, and `golang.org/x/sync/errgroup`:
  - Layer 1: Parallel asynchronous deletion of Instances, OSD Disks, Static IPs, Firewalls, Storage HMAC keys, and GCS WAL buckets with LRO concurrency.
  - Layer 2: Subnetwork deletion triggered upon Layer 1 instance & firewall termination.
  - Layer 3: VPC Network & Service Account deletion triggered upon Subnetwork cleanup.
  - Added auto-discovery, verification pass, and automatic `terraform.tfstate` cleanup.
  - Wired `just pull-ripcord` to `go run ./provisioning/cmd/ripcord`.
- Created golden machine image builder in `provisioning/image/build_golden_image.sh` (`just build-image`):
  - Pre-bakes baseline apt packages, kernel module configurations, k3s/helm/argocd binaries.
  - Pre-populates containerd image cache with Rook Ceph, Cilium, Prometheus, Tempo, Loki, Flagd, and OTel demo images.
  - Added `var.boot_image` in `variables.tf` and `compute.tf` to seamlessly switch between vanilla Ubuntu and pre-baked images.
