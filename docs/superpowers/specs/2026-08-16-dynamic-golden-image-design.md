# Dynamic & Robust Golden Machine Image Builder (Python + uv)

**Date:** 2026-08-16  
**Status:** Approved for Implementation  
**Owner:** Ian / Antigravity  

## 1. Overview & Goal

The golden machine image builder creates a pre-baked Google Compute Engine (GCE) image containing base operating system configuration, system tools, and pre-cached container images in containerd. This cuts cold-boot cluster standup and GitOps convergence time from ~6 minutes to ~45 seconds.

This redesign implements a Python-based CLI powered by `uv` (with PEP 723 inline script metadata) to replace the brittle `build_golden_image.sh`. It achieves:
1. **Eliminating Provisioning Duplication:** Runs `provisioning/scripts/common.sh` directly on the builder VM rather than duplicating APT packages, kernel modules, sysctl, and shell configurations in a fragile heredoc.
2. **Repo-Driven Image Extraction:** Replaces the static `IMAGES=(...)` array with a dynamic YAML/manifest scanner that inspects `applications/`, `cluster-bootstrap/`, and pinned version configs to generate an exact, deduplicated bill of materials.
3. **Robust Orchestration:** Provides rich terminal feedback (tables, progress steps, elapsed time), structured retry logic with exponential backoff for image pulls, robust SSH readiness polling, pre-snapshot verification, and guaranteed ephemeral builder cleanup.

---

## 2. Architecture & Workflow

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Local Host (via uv run)                         │
│                                                                        │
│  1. Scan Repository (ManifestScanner)                                  │
│     ├── Walk applications/, cluster-bootstrap/                         │
│     ├── Parse Pod specs, Deployments, CephCluster CRs, Helm values     │
│     ├── Read provisioning/versions.env (Cilium, ArgoCD, Helm, k3s)     │
│     └── Emits categorized & deduplicated ImageManifest                 │
│                                                                        │
│  2. Ephemeral VM Orchestration (GCEBuilderSession)                     │
│     ├── Create GCE VM (e2-standard-4, Ubuntu 24.04, 50GB pd-balanced)  │
│     ├── Poll SSH readiness with backoff                                │
│     └── Upload provisioning/ + generated image_manifest.txt via SCP    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ gcloud compute ssh / scp
┌───────────────────────────────────▼────────────────────────────────────┐
│                         Ephemeral Builder VM                           │
│                                                                        │
│  3. Remote Setup                                                       │
│     ├── Execute provisioning/scripts/common.sh directly                │
│     └── Install pinned tools (Helm, ArgoCD CLI, k3s installer)         │
│                                                                        │
│  4. Containerd Pre-Caching & Verification                              │
│     ├── Start k3s containerd daemon                                    │
│     ├── Pre-pull all manifest images with retry backoff                │
│     └── Verify resident images in containerd k8s.io namespace          │
│                                                                        │
│  5. System Generalization                                              │
│     ├── Stop k3s & purge cluster database/certs/node state             │
│     └── Truncate /etc/machine-id & run cloud-init clean                │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ gcloud compute images create
┌───────────────────────────────────▼────────────────────────────────────┐
│                      GCE Golden Image Artifact                         │
│          thump-test-golden-YYYYMMDD-HHMMSS (family: golden)            │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Design

### 3.1 Pinned Versions Single Source of Truth (`provisioning/versions.env`)
A centralized environment file sourced by scripts and parsed by the image extractor:
```bash
HELM_VERSION="v3.16.3"
ARGOCD_CLI_VERSION="v2.13.0"
CILIUM_VERSION="1.19.3"
HUBBLE_VERSION="v1.19.3"
GATEWAY_API_VERSION="v1.5.1"
ARGOCD_VERSION="v2.13.0"
K3S_CHANNEL="v1.31"
```

### 3.2 Dynamic Image Scanner (`ManifestScanner` in `provisioning/image/build_golden_image.py`)
- Traverses the repo looking for all `.yaml`, `.yml`, and `.env` files.
- Extracts container images using multi-pass detection:
  1. Standard k8s container specs: `image: <registry>/<repo>:<tag>`.
  2. Helm `values.yaml` structures (`repository: ...` + `tag: ...`).
  3. Custom Resource Definitions (CephCluster `spec.cephVersion.image`, etc.).
  4. Pinned bootstrap versions from `provisioning/versions.env` (Cilium CNI, ArgoCD, etc.).
- Normalizes and filters:
  - Strips template variables (`{{ ... }}`, `$VAR`) and test fixtures (e.g. `bats/bats`).
  - Groups images by tier:
    - **Tier 1: Core Bootstrap** (k3s pause, Cilium agent/operator/envoy/hubble, ArgoCD server/repo-server/redis, Rook Ceph operator & daemon).
    - **Tier 2: Infrastructure & Observability** (Prometheus, Alertmanager, Grafana, Loki, Tempo, Promtail, OTel Collector Contrib, Sloth, Kyverno, Cert-Manager).
    - **Tier 3: Apps & Demos** (OpenTelemetry Astronomy Shop microservices, Flagd, Acme demo, S3 Traffic Generator, Chaos Mesh).

### 3.3 Builder Orchestrator (`GCEBuilderSession`)
- Built with Python `subprocess`, `rich`, and `pyyaml`.
- Flags:
  - `--extract-only`: Display extracted image inventory without creating GCP resources.
  - `--dry-run`: Mock VM execution steps.
  - `--project`, `--zone`, `--family`, `--name`: GCP configuration.
  - `--keep-builder`: Keep builder VM on error for interactive debugging.
- Safe lifecycle:
  - Uses `try...finally` to ensure builder VM is deleted even on keyboard interrupt or error.
  - Uploads `provisioning/` to `/tmp/thump-provisioning/` on the builder VM.
  - Executes `sudo bash /tmp/thump-provisioning/scripts/common.sh`.
  - Runs remote image pull script with progress output and per-image retry logic.
  - Validates containerd content store before stopping VM.
  - Triggers `gcloud compute images create`.

### 3.4 Taskfile Integration
Update `Taskfile.yaml`:
```yaml
  build-image:
    desc: Build golden GCE machine image with pre-installed packages and cached container images
    cmds:
      - uv run provisioning/image/build_golden_image.py {{.CLI_ARGS}}

  list-images:
    desc: List all container images dynamically extracted from the repository
    cmds:
      - uv run provisioning/image/build_golden_image.py --extract-only
```

---

## 4. Testing & Verification

1. **Unit Testing:**
   - Create `provisioning/image/test_extract_images.py` to verify image extraction against real repo manifests and edge cases (template variables, helm values, CephCluster CRs).
   - Run tests via `uv run pytest provisioning/image/test_extract_images.py`.
2. **Dynamic Inventory Verification:**
   - Run `task list-images` and inspect categorized image list.
3. **Build Execution:**
   - Run `task build-image` to construct the GCE golden image.
