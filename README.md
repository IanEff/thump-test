# thump-test

A disposable, GitOps-managed Kubernetes testbed running on plain Google Compute Engine (GCE) VMs via OpenTofu: **k3s + Rook Ceph + OTel Astronomy Shop + Cilium + Prometheus/Grafana/Tempo/Loki/Sloth + Chaos Mesh + cert-manager + flagd**, reconciled end-to-end by ArgoCD from git.

`thump-test` is designed as a low-cost, high-fidelity integration rig for [`thump`](https://github.com/ianeff/thump)—an agentic SRE engine that observes SLO burn-rate alerts, diagnoses multi-system root causes, and executes automated remediations.

---

## Architecture & Design Rationale

Unlike single-domain testbeds, `thump-test` runs **two orthogonal application domains side-by-side on a single cluster**:

1. **Storage Domain (Rook Ceph)**: Distributed block (RBD), shared filesystem (CephFS), and S3-compatible object storage (RGW) backed by dedicated GCE persistent disks per worker node.
2. **Application Domain (OpenTelemetry Astronomy Shop)**: A 17-microservice e-commerce stack whose failure modes are controlled and injected dynamically via **`flagd` feature flags**.

### Why Dual-Domain?
Running Ceph and the OTel Astronomy Shop on the same cluster proves that `thump`'s reasoning engine relies on declarative configuration (topology maps, SLO definitions, catalog actions) rather than domain-specific hardcoding. A Ceph Placement Group (PG) degradation and a demo service cart failure share no metrics, signals, or remediation paths; `thump` must analyze and react to both independently without cross-domain signal bleeding.

---

## What's Running (Full System Matrix)

| Category | Component | Description & Functionality |
|---|---|---|
| **Cluster & Compute** | **k3s** | Lightweight Kubernetes (`v1.36` channel). 1x control-plane node (`e2-medium`, tainted `NoSchedule`) + 3x worker nodes (`e2-standard-4` x2, `e2-standard-2` x1). |
| **Infrastructure IaC** | **OpenTofu** | Pure GCP VM provisioning (instances, GCE persistent disks, VPC, subnets, firewall rules, static IPs, and external GCS bucket). |
| **GitOps Engine** | **ArgoCD** | Multi-wave GitOps reconciler using ApplicationSets (`infra-set`, `rook-set`, `apps-set`) with explicit CRD-registration retry budgets. |
| **Storage (Domain 1)** | **Rook Ceph** | Ceph v19 (`Squid`) managing RBD block devices, CephFS filesystems, and RGW object storage. Custom tuned CSI sidecars and PG ceilings (`mon_max_pg_per_osd: "400"`). |
| **Application (Domain 2)**| **OTel Astronomy Shop** | 17 microservices (frontend, cart, checkout, product-catalog, valkey-cart, postgresql, kafka, recommendation, load-generator, etc.) driving realistic e-commerce traffic. |
| **Networking & Ingress** | **Cilium & Gateway API** | eBPF-based CNI with VXLAN tunneling (`routingMode: tunnel`), `gatewayAPI.hostNetwork` with `NET_BIND_SERVICE` for host-bound Envoy ingress (ports 80/443). |
| **Network Visibility** | **Cilium Hubble** | Deep eBPF packet inspection and L7 flow visibility UI and API. |
| **Observability Stack** | **Prometheus + Grafana + Tempo + Loki** | Complete telemetry pipeline: Prometheus for metrics, Grafana for visualization, Tempo for OTLP distributed traces, and Loki + Promtail for log aggregation. |
| **SLO Alerting Engine** | **Sloth** | Declarative `PrometheusServiceLevel` specs compiled (`task gen-slos`) directly into Prometheus alerting rules for multi-window burn-rate detection. |
| **In-Cluster PKI** | **cert-manager** | Jetstack cert-manager v1.21.0 creating a private cluster CA (`Issuer` → `CA Certificate` → `ClusterIssuer` in namespace `cert-manager`) for internal TLS. |
| **Wire & Data Security** | **WireGuard & Encryption** | Cilium WireGuard mesh encryption for pod-to-pod transit, Ceph `msgr2_secure_mode` wire encryption, and k3s cluster `secrets-encryption` at rest. |
| **Chaos Engineering** | **Chaos Mesh & flagd** | Chaos Mesh for Ceph pod/network/IO chaos; custom `flagd` shell scripts for instant, reversible microservice failure injection. |

---

## Prerequisites

- **GCP Project**: Billing enabled, and `gcloud` authenticated (`gcloud auth login`) with `roles/compute.osLoginUser` and `roles/iap.tunnelResourceAccessor` at minimum.
- **CLI Tools**: `tofu` (or `terraform`), `task` (Go-Task), `kubectl`, `python3`, `gcloud`, `yq` (optional, for `gen-slos`).
- **GitHub Repository**: A git remote to hold your GitOps tree (ArgoCD reconciles directly from git).
- **SSH Deploy Key**: A deploy key with **write** permissions placed at `./deploy_thump-test` (gitignored), used by the bootstrap script to push initial cluster config back to git.

---

## Quick Start

```bash
# 1. Configure your IP allowlist and GitOps remote (gitignored)
cat > terraform.tfvars <<EOF
allowed_source_ranges = ["YOUR.IP.HERE/32"]
gitops_repo_url        = "https://github.com/YOUR_USERNAME/thump-test.git"
EOF

# Note: Ensure the private deploy key with write access lives at ./deploy_thump-test

# 2. Provision GCE infrastructure & bootstrap k3s + ArgoCD (~2-4 min)
task up

# 3. Open an IAP tunnel to the k3s API (run in a separate terminal session)
task tunnel &

# 4. Watch ArgoCD synchronize all applications
kubectl --context thump-test get applications -n argocd -w

# 5. Verify Ceph storage cluster health
kubectl --context thump-test exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# 6. Tear down infrastructure completely (zero cost when destroyed)
task destroy
```

---

## Service Directory

Once `task up` completes, `manage_hosts.py` automatically injects the control-plane IP into `/etc/hosts`. The following services are accessible locally via HTTPS:

| Service | Local URL | Description |
|---|---|---|
| **ArgoCD** | `https://argocd.thump-test.lab` | GitOps deployment management & sync status |
| **Grafana** | `https://grafana.thump-test.lab` | System dashboards, Ceph metrics, and OTel traces |
| **Ceph Dashboard** | `https://dashboard.thump-test.lab` | Rook Ceph storage cluster management & telemetry |
| **Hubble UI** | `https://hubble.thump-test.lab` | Cilium eBPF network flow map and L7 HTTP/gRPC inspection |
| **Prometheus** | `https://prometheus.thump-test.lab` | PromQL metrics database and Sloth burn-rate alerts |
| **OTel Demo** | `https://otel-demo.thump-test.lab` | Astronomy Shop e-commerce frontend & checkout flow |

*Default login credentials for services are retrieved or generated during `task credentials`.*

---

## Capacity Sizing & Quota Optimization (Wave 0b)

GCP projects often run under a strict 12-vCPU `CPUS_ALL_REGIONS` quota limit. The node architecture allocates:
- **Control-plane**: 1x `e2-medium` (2 vCPU, tainted `NoSchedule`)
- **Worker nodes**: 2x `e2-standard-4` (8 vCPU) + 1x `e2-standard-2` (2 vCPU) = **10 vCPU allocatable budget**

### Measure-then-Size Adjustments
Stock Ceph installs with unoptimized CSI sidecars consume upwards of 9.5 vCPU in requests alone (96% of capacity) before any workload runs. `thump-test` implements two critical optimizations to fit both Ceph and OTel Demo within budget:

1. **CSI Resource Tuning** (`applications/rook/operator/kustomization.yaml`):
   - Provisioner CPU requests reduced from 100m → 30m.
   - Main driver plugin requests reduced from 250m → 100m.
   - Provisioner replicas set to 1 (`provisionerReplicas: 1`).
   - *Savings*: ~2.98 vCPU freed.
2. **OSD Disk Sizing** (`osd_disks_per_node = 1`):
   - OSD count set to 1 per worker node (3 OSDs cluster-wide), cutting OSD daemon CPU requests in half (2100m → 1050m).
   - `mon_max_pg_per_osd` bumped to `400` in `cephcluster.yaml` to accommodate `replicated.size: 3` across 3 nodes.

**Result**: Worker node CPU requests dropped from **96% (9575m)** down to **56.9% (5685m)**, creating ~4.3 vCPU of headroom for the OTel Astronomy Shop microservices and observability stack.

---

## Microservices & Chaos Injection

### OTel Astronomy Shop (Trimmed Core Shopping Path)
The OpenTelemetry Astronomy Shop runs 17 active components:
`frontend`, `frontend-proxy`, `flagd`, `image-provider`, `load-generator`, `ad`, `cart`, `valkey-cart`, `checkout`, `currency`, `email`, `payment`, `product-catalog`, `quote`, `recommendation`, `shipping`, `kafka`, `postgresql`.

### `flagd` Feature Flag Chaos Scripts
Failure modes in the OTel Demo are controlled via `flagd` feature flags stored in Kubernetes ConfigMaps. Flip ON to inject a fault; flip OFF to remediate instantly.

Pre-packaged chaos scripts are available in `chaos/`:

```bash
# Inject Cart Service failure (EmptyCart gRPC status 9 errors)
./chaos/flag-cart-on.sh

# Remediate Cart Service failure
./chaos/flag-cart-off.sh

# Inject Product Catalog failure (HTTP 500 errors on catalog queries)
./chaos/flag-product-catalog-on.sh

# Remediate Product Catalog failure
./chaos/flag-product-catalog-off.sh
```

### Ceph Storage Chaos (Chaos Mesh)
Chaos Mesh is deployed at sync wave 40. Inject pod, network, or disk IO failures directly against Ceph OSD/MON/MGR daemons:

```bash
# Kill an active Ceph OSD daemon
kubectl --context thump-test apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-one-osd
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [rook-ceph]
    labelSelectors:
      app: rook-ceph-osd
EOF
```

---

## Observability & Sloth SLO Engine

### Metrics Pipeline
The custom `otel-collector` pipeline receives OTLP traces and metrics from the microservices and exports them into Prometheus series (`app_frontend_requests_total`, `rpc_server_duration_milliseconds_*`, `http_server_duration_milliseconds_bucket`), enabling real-time PromQL SLI evaluation.

### Sloth PrometheusServiceLevels
SLOs are authored as Sloth YAML definitions in `applications/infrastructure/sloth/prometheusservicelevels.yaml`.

- **Ceph Domain SLOs**: `ceph-rgw-availability`, `ceph-rgw-saturation`, `ceph-osd-latency`, `ceph-health`, `ceph-redundancy`.
- **OTel Demo Domain SLOs**: `cart-availability` (tracking `checkout` → `CartService` gRPC error ratio), `product-catalog-availability`.

Run `task gen-slos` to re-compile Sloth specs into Prometheus rules and automatically update `applications/infrastructure/prometheus/values.yaml`.

---

## Developer Automation ("Toys, Bells & Whistles")

`thump-test` includes a rich set of developer commands and lifecycle utilities powered by `task` (`Taskfile.yaml`):

### Key `task` Commands

| Command | Category | Description |
|---|---|---|
| `task up` | Lifecycle | Complete one-shot cluster bring-up: `tofu apply`, fetch kubeconfig, write `/etc/hosts`, and sync GCS credentials. |
| `task destroy` | Lifecycle | Complete zero-cost infrastructure teardown. Removes all VMs, disks, subnets, and state. |
| `task build-image` | Image Baking | Bakes a golden GCE machine image with pre-installed packages and cached containerd images. |
| `task list-images` | Image Baking | Evaluates the GitOps tree and lists all 61 container images to be pre-cached. |
| `task images` | Image Baking | Lists custom GCE golden machine images present in the GCP project. |
| `task prune-images` | Image Baking | Prunes older golden images in GCP, keeping only the most recent build. |
| `task delete-image NAME=...`| Image Baking| Deletes a specific custom GCE machine image by name. |
| `task tunnel` | Connectivity | Opens an IAP-gated SSH tunnel to `localhost:6443` for `kubectl` access without exposing public ports. |
| `task credentials` | Connectivity | Fetches cluster kubeconfig via OS Login and updates local `/etc/hosts` with `*.thump-test.lab` records. |
| `task ssh [TARGET=...]` | Debugging | Connects to nodes via IAP tunnel (`TARGET="control-plane"` (default) or `"node-1"`, `"node-2"`, `"node-3"`). |
| `task generate-traffic [N=...]`| Workload | Scales `s3-traffic-generator` to `N` pods (default 1), polls readiness, and launches backgrounded S3 traffic loops targeting RGW. |
| `task wipe-ceph-disks` | Operations | **Destructive**: Wipes Rook Ceph CRDs and zeroes out raw OSD block devices without destroying GCE VMs. |
| `task gen-slos` | Observability | Compiles Sloth SLO specs into Prometheus alerting rules and splices them into Prometheus Helm values. |
| `task boot-timeline` | Profiling | Launches `boot_timeline.py` to time every ArgoCD application reaching `Healthy` state from cold boot. |
| `task thump-env` | Integration | Runs `sync_thump_env.py` to export GCS S3 bucket credentials into consumer `.env` files. |
| `task pull-ripcord [-- args]` | Emergency | **Nuclear**: Out-of-band GCP resource eraser (`ripcord`) bypassing Tofu state if state is corrupted or unresponsive. |

### Golden Machine Image Baking (`task build-image`, `task list-images`, `task images`)

Fresh GCE node standup on stock Ubuntu cloud images spends ~6 minutes downloading ~15GB of container images across 61 workloads over the public internet, competing for registry rate limits and bandwidth during ArgoCD sync waves.

`task build-image` bakes a pre-cached GCE golden image that drops cold-boot cluster convergence to ~45 seconds:

1. **Dynamic GitOps Extraction**: `build_golden_image.py` (invoked via `uv`) traverses `applications/` and `cluster-bootstrap/`, evaluating every `kustomization.yaml` with `kubectl kustomize --enable-helm`. It extracts the exact 61 images ArgoCD reconciles in-cluster without maintaining a static list.
2. **Ephemeral Builder VM**: Launches an ephemeral `e2-standard-4` builder VM in the configured zone (`us-east1-b`), transfers `provisioning/`, and runs `common.sh` directly with root privileges (kernel modules, sysctl, APT packages, fish/bash ergonomics).
3. **Containerd Pre-Caching**: Starts a transient k3s server (`v1.36`) to bring up containerd, pulls all 61 extracted images into the `k8s.io` namespace with exponential backoff retries, then purges cluster state (`/var/lib/rancher/k3s/server/db`, TLS certs, machine-id) while leaving the containerd layer cache intact.
4. **Image Freeze**: Captures a GCE image tagged under the `thump-test-golden` family and destroys the builder VM.

```bash
# Preview the discovered container image inventory without touching GCP
task list-images

# Bake the golden GCE machine image
task build-image

# Inspect custom golden images in your GCP project
task images

# Prune older golden images, keeping only the newest build
task prune-images

# Delete a specific custom image
task delete-image NAME=thump-test-golden-YYYYMMDD-HHMMSS
```

To boot newly provisioned clusters from the golden image, set in `terraform.tfvars`:
```hcl
boot_image = "global/images/family/thump-test-golden"
```

### Diagnostic & Integration Utilities

- **`boot_timeline.py` (`task boot-timeline`)**: A Python profiling tool that monitors ArgoCD application sync states during cluster bootstrap, generating detailed time-stamped CSV reports in `boot-timelines/`.
- **`s3-traffic-generator` (`task generate-traffic N=<n>`)**: Idempotent Python/bash load-generation pods that stream S3 read/write operations against Ceph RGW, outputting logs directly to pod stdout for easy `kubectl logs` inspection.
- **`ceph_latency_exporter.py`**: A Prometheus exporter bridge that measures real-time Ceph RGW request latency and feeds `ceph-osd-latency` SLOs.
- **`ripcord` (`task pull-ripcord`)**: Emergency teardown utility using native Go Cloud SDK parallel DAG engine directly to discover and purge all project resources matching `thump-test-*` when OpenTofu state is locked or missing.

---

## Security & In-Cluster Encryption (Phase R)

`thump-test` incorporates enterprise-grade security and encryption invariants across all layers:

1. **Private Identity-Gated Control Plane**: API server (port 6443) and SSH (port 22) have **no public listeners**. Access is strictly gated via GCP Cloud IAP Tunnels using OS Login IAM policies.
2. **In-Cluster PKI (cert-manager)**: Private self-signed CA hierarchy (`cert-manager` namespace) providing internal TLS certificates without reliance on public Let's Encrypt or external trust managers.
3. **Network Transit Encryption**: Cilium WireGuard mesh encrypts all pod-to-pod network traffic across worker nodes.
4. **Storage & Data Encryption**:
   - Ceph Wire Encryption: `msgr2_secure_mode` enabled for all Ceph daemon-to-daemon and client communications.
   - Kubernetes Secrets at Rest: k3s `secrets-encryption` enabled via AES-CBC encryption configuration (`/etc/rancher/k3s/secrets-encryption.yaml`).
   - GCS Bucket Security: Public access prevention enforced on external state storage.

---

## Bringing Your Own Application

`thump-test` can serve as a disposable remote Kubernetes integration target for any application driven by a `Tiltfile`:

1. **Remote Context**: Set `allow_k8s_contexts('thump-test')` in your `Tiltfile`. Ensure `task tunnel &` is running locally.
2. **Architecture**: GCE VMs run `linux/amd64`. Configure `docker_build(..., platform='linux/amd64')` if developing on Apple Silicon.
3. **Container Registry**: Nodes pull images from external registries (GHCR, Artifact Registry, Docker Hub). Local laptop registries (`kind`/`k3d`) are not accessible.
4. **External S3 Storage Integration**: If your app requires durable object storage isolated from Ceph chaos, run `task thump-env` to copy the GCS S3 bucket credentials into your app's `.env` file.

---

## Teardown

To release all GCE resources and avoid incurring GCP billing charges:

```bash
task destroy
```

This destroys all OpenTofu-managed VMs, persistent disks, firewall rules, static IPs, subnets, VPCs, and external GCS buckets.
