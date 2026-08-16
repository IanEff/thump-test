# Dynamic Golden Machine Image Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the brittle bash `build_golden_image.sh` with a dynamic, repo-driven Python (`uv`) orchestrator that extracts container images directly from `applications/` and `cluster-bootstrap/`, eliminates duplicated provisioning logic by running `common.sh` directly, and hardens GCE image creation.

**Architecture:** A local Python driver (`build_golden_image.py`) powered by `uv` scans GitOps manifests and Helm values to generate a deduplicated image manifest, provisions an ephemeral GCE builder VM, transfers `provisioning/` files, runs `common.sh` and pinned tool installers remotely, pre-pulls all images into containerd with retry backoff, validates the cache, and captures the golden GCE image.

**Tech Stack:** Python 3.11+, `uv` (PEP 723 metadata with `pyyaml`, `rich`), `pytest`, Google Cloud CLI (`gcloud`), OpenTofu/k3s/containerd.

## Global Constraints

- Image extraction must scan all YAML files in `applications/` and `cluster-bootstrap/` and exclude test files (e.g. `bats/bats`).
- Pinned versions must be centralized in `provisioning/versions.env` and sourced consistently.
- Ephemeral GCE builder VM must be reliably cleaned up on completion or failure using `try...finally` / `atexit`.
- The remote execution must run `provisioning/scripts/common.sh` directly without inlined heredoc duplicates.
- All remote image pulls must have retry backoff and pre-capture verification.

---

### Task 1: Centralize Tooling Versions in `provisioning/versions.env`

**Files:**
- Create: `provisioning/versions.env`
- Modify: `provisioning/scripts/install_cilium.sh:34-40`
- Modify: `provisioning/scripts/control-plane.sh:33-43`

**Interfaces:**
- Consumes: None
- Produces: `HELM_VERSION`, `ARGOCD_CLI_VERSION`, `CILIUM_VERSION`, `HUBBLE_VERSION`, `GATEWAY_API_VERSION`, `ARGOCD_VERSION`, `K3S_CHANNEL` environment variables.

- [ ] **Step 1: Create `provisioning/versions.env`**

```bash
# thump-test — centralized tooling and component versions
HELM_VERSION="v3.16.3"
ARGOCD_CLI_VERSION="v2.13.0"
CILIUM_VERSION="1.19.3"
HUBBLE_VERSION="v1.19.3"
GATEWAY_API_VERSION="v1.5.1"
ARGOCD_VERSION="v2.13.0"
K3S_CHANNEL="v1.31"
```

- [ ] **Step 2: Update `install_cilium.sh` and `control-plane.sh` to source `versions.env` if present**

Ensure default fallback remains intact if the file is missing.

- [ ] **Step 3: Verify script syntax**

Run: `bash -n provisioning/scripts/install_cilium.sh && bash -n provisioning/scripts/control-plane.sh`
Expected: Return 0 with no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add provisioning/versions.env provisioning/scripts/install_cilium.sh provisioning/scripts/control-plane.sh
git commit -m "feat(provisioning): centralize component versions in versions.env"
```

---

### Task 2: Implement and Test Repo Image Extractor (`ManifestScanner`)

**Files:**
- Create: `provisioning/image/test_extract_images.py`
- Create: `provisioning/image/build_golden_image.py` (ManifestScanner module)

**Interfaces:**
- Consumes: `applications/`, `cluster-bootstrap/`, `provisioning/versions.env`
- Produces: `ManifestScanner.scan_repo() -> dict[str, list[str]]` returning categorized images (Tier 1: Core Bootstrap, Tier 2: Observability, Tier 3: Workloads).

- [ ] **Step 1: Write unit tests in `provisioning/image/test_extract_images.py`**

```python
from build_golden_image import ManifestScanner

def test_extract_images_from_repo():
    scanner = ManifestScanner()
    images_by_tier = scanner.scan_repo()
    all_images = [img for imgs in images_by_tier.values() for img in imgs]
    
    # Assert core images are present
    assert any("rook/ceph" in img or "ceph/ceph" in img for img in all_images)
    assert any("cilium" in img for img in all_images)
    assert any("prometheus" in img for img in all_images)
    assert any("flagd" in img for img in all_images)
    
    # Assert test fixtures are excluded
    assert not any("bats/bats" in img for img in all_images)
```

- [ ] **Step 2: Run test to verify it fails before implementation**

Run: `uv run pytest provisioning/image/test_extract_images.py`
Expected: FAIL (module not yet defined).

- [ ] **Step 3: Implement `ManifestScanner` in `provisioning/image/build_golden_image.py`**

Implement recursive YAML parsing, regex fallback for helm values / templating, image filtering, and tier categorization.

- [ ] **Step 4: Run tests and verify they pass**

Run: `uv run pytest provisioning/image/test_extract_images.py`
Expected: PASS with 100% assertions passing.

- [ ] **Step 5: Commit**

```bash
git add provisioning/image/build_golden_image.py provisioning/image/test_extract_images.py
git commit -m "feat(image): implement dynamic repo manifest image extractor"
```

---

### Task 3: Implement GCE Builder Session Orchestrator & CLI

**Files:**
- Modify: `provisioning/image/build_golden_image.py`
- Modify: `Taskfile.yaml:154-162`
- Delete / Replace: `provisioning/image/build_golden_image.sh`

**Interfaces:**
- Consumes: `ManifestScanner`, `gcloud` CLI, `provisioning/scripts/common.sh`
- Produces: CLI commands `build-image` and `list-images` via `Taskfile.yaml`.

- [ ] **Step 1: Implement `GCEBuilderSession` in `build_golden_image.py`**

Implement:
- Ephemeral VM creation (`e2-standard-4`, 50GB `pd-balanced`, Ubuntu 24.04).
- Guaranteed cleanup on exit (`atexit` / `try...finally`).
- SSH readiness polling with timeout.
- SCP upload of `provisioning/` and generated `image_manifest.txt`.
- Remote execution of `common.sh`, pinned tool installers, k3s containerd start, retry pull loop, content store verification, k3s cleanup, and cloud-init generalization.
- Instance stop & `gcloud compute images create`.
- Rich CLI tables for `--extract-only` and progress bars during build.

- [ ] **Step 2: Update `Taskfile.yaml` and replace `build_golden_image.sh`**

Wire `task build-image` and `task list-images` to `uv run provisioning/image/build_golden_image.py`.
Make `build_golden_image.sh` a thin shim calling `uv run` for backward compatibility.

- [ ] **Step 3: Test CLI `--extract-only` and `--dry-run` modes**

Run: `task list-images`
Expected: Outputs a clean Rich table with categorized image counts and full deduplicated image list.

Run: `uv run provisioning/image/build_golden_image.py --dry-run`
Expected: Displays planned build steps and image counts without creating GCP resources.

- [ ] **Step 4: Commit**

```bash
git add Taskfile.yaml provisioning/image/build_golden_image.py provisioning/image/build_golden_image.sh
git commit -m "feat(image): complete dynamic golden image builder with uv CLI"
```

---

### Task 4: End-to-End Image Build & Verification

**Files:**
- Output: GCE Golden Machine Image `thump-test-golden-<TIMESTAMP>` in `us-central1-a`.

- [ ] **Step 1: Execute `task build-image`**

Run: `task build-image`
Expected:
1. Manifest scanner discovers ~30-40 unique images.
2. Ephemeral builder VM spins up in `us-central1-a`.
3. `common.sh` runs cleanly.
4. Containerd pre-caches images with verified success.
5. Golden image is created in GCE under family `thump-test-golden`.
6. Builder VM is automatically cleaned up.

- [ ] **Step 2: Verify created GCE image**

Run: `gcloud compute images list --filter="family=thump-test-golden" --project="$(gcloud config get-value project)"`
Expected: Golden image listed in READY state.

- [ ] **Step 3: Commit and update documentation**

```bash
git add .
git commit -m "docs: document dynamic golden image builder usage"
```
