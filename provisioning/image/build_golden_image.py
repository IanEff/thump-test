#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyyaml>=6.0",
#     "rich>=13.0",
# ]
# ///
"""
thump-test — Dynamic Golden Machine Image Builder

Builds a pre-baked Google Compute Engine golden image for thump-test nodes.
Extracts required container images dynamically from the repository manifests,
runs provisioning/scripts/common.sh on an ephemeral GCE builder VM, pre-caches
container images into containerd, and captures the image.

Usage:
  uv run provisioning/image/build_golden_image.py
  uv run provisioning/image/build_golden_image.py --extract-only
  uv run provisioning/image/build_golden_image.py --dry-run
"""

import argparse
import atexit
import datetime
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Set

import yaml
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()


def load_env_file(filepath: Path) -> Dict[str, str]:
    """Parse a simple KEY=VALUE bash environment file."""
    env = {}
    if not filepath.is_file():
        return env
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                env[key.strip()] = val.strip().strip('"\'')
    return env


class ManifestScanner:
    """Scans the repository to extract all declared container images."""

    def __init__(self, repo_root: Optional[str] = None):
        if repo_root:
            self.repo_root = Path(repo_root).resolve()
        else:
            self.repo_root = Path(__file__).resolve().parent.parent.parent

        self.versions_file = self.repo_root / "provisioning" / "versions.env"
        self.versions = load_env_file(self.versions_file)

    def scan_repo(self) -> Dict[str, List[str]]:
        """Scan applications, cluster-bootstrap, and versions to return categorized images."""
        found_images: Set[str] = set()

        # 1. Add synthesized images from centralized versions
        self._add_pinned_bootstrap_images(found_images)
        self._add_opentelemetry_demo_images(found_images)

        # 2. Walk repo_root
        ignored_dirs = {".git", ".terraform", ".pytest_cache", "__pycache__", "tests", "test"}
        for root, dirs, files in os.walk(self.repo_root):
            # Prune ignored directories in-place
            dirs[:] = [d for d in dirs if d not in ignored_dirs and not d.startswith(".")]

            for fname in files:
                if fname.endswith((".yaml", ".yml")):
                    fpath = Path(root) / fname
                    self._scan_yaml_file(fpath, found_images)

        # 3. Clean, filter, and categorize
        cleaned = self._clean_and_filter(found_images)
        return self._categorize(cleaned)

    def _add_opentelemetry_demo_images(self, found: Set[str]) -> None:
        """Inject OTel Astronomy Shop microservice images."""
        otel_services = [
            "adservice",
            "cartservice",
            "checkoutservice",
            "currencyservice",
            "emailservice",
            "frontend",
            "frontendproxy",
            "imageprovider",
            "loadgenerator",
            "paymentservice",
            "productcatalogservice",
            "quoteservice",
            "recommendationservice",
            "shippingservice",
        ]
        for svc in otel_services:
            found.add(f"ghcr.io/open-telemetry/demo:2.2.0-{svc}")

    def _clean_and_filter(self, raw_images: Set[str]) -> List[str]:
        """Sanitize image names, remove template variables and test artifacts."""
        cleaned = set()
        for img in raw_images:
            img = img.strip().strip("\"'")
            # Discard template interpolation & variables
            if any(c in img for c in ["{{", "}}", "$", "<", ">", " ", "\\"]):
                continue
            # Discard invalid/placeholder tags
            if img.endswith(":null") or img.endswith(":None") or img.endswith(":") or ":" not in img:
                continue
            # Discard test frameworks and unpinned helper tools from vendored charts
            if any(bad in img for bad in ["bats/bats", "bitnami/os-shell", "istio/ztunnel", "keycloak-proxy"]):
                continue
            # Discard multiple conflicting older versions of cilium/etcd
            if "quay.io/cilium/cilium:v1.10" in img or "quay.io/cilium/cilium:v1.18" in img:
                continue
            if "quay.io/cilium/clustermesh-apiserver:v1.18" in img:
                continue
            if "quay.io/cilium/hubble-relay:v1.18" in img:
                continue
            if "quay.io/cilium/operator:v1.18" in img:
                continue

            cleaned.add(img)

        return sorted(list(cleaned))

    def get_flat_image_list(self) -> List[str]:
        """Return a sorted, deduplicated flat list of all required images."""
        tiers = self.scan_repo()
        flat = []
        for tier_imgs in tiers.values():
            flat.extend(tier_imgs)
        return sorted(list(set(flat)))

    def _add_pinned_bootstrap_images(self, found: Set[str]) -> None:
        """Inject core bootstrap images derived from versions.env."""
        cilium_ver = self.versions.get("CILIUM_VERSION", "1.19.3")
        if not cilium_ver.startswith("v"):
            cilium_tag = f"v{cilium_ver}"
        else:
            cilium_tag = cilium_ver

        hubble_ver = self.versions.get("HUBBLE_VERSION", "v1.19.3")
        if not hubble_ver.startswith("v"):
            hubble_tag = f"v{hubble_ver}"
        else:
            hubble_tag = hubble_ver

        argocd_ver = self.versions.get("ARGOCD_VERSION", "v2.13.0")
        if not argocd_ver.startswith("v") and argocd_ver != "stable" and argocd_ver != "latest":
            argocd_tag = f"v{argocd_ver}"
        else:
            argocd_tag = argocd_ver

        found.add(f"quay.io/cilium/cilium:{cilium_tag}")
        found.add(f"quay.io/cilium/operator-generic:{cilium_tag}")
        found.add(f"quay.io/cilium/hubble-relay:{hubble_tag}")
        found.add(f"quay.io/argoproj/argocd:{argocd_tag}")
        found.add("docker.io/library/redis:7.2.4-alpine")
        found.add("quay.io/ceph/ceph:v19.2.3")
        found.add("docker.io/rook/ceph:v1.15.5")

    def _scan_yaml_file(self, fpath: Path, found: Set[str]) -> None:
        """Scan a single YAML file for image references."""
        try:
            with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
        except Exception:
            return

        # Fast regex passes
        img_re = re.compile(r"""(?:image:\s*["']?|["']image["']:\s*["']?)([a-zA-Z0-9_.\-/]+:[a-zA-Z0-9_.\-]+)""")
        repo_tag_re = re.compile(
            r"""repository:\s*["']?([a-zA-Z0-9_.\-/]+)["']?\s*\n\s*tag:\s*["']?([a-zA-Z0-9_.\-]+)["']?"""
        )

        for match in img_re.finditer(content):
            found.add(match.group(1).strip("\"'"))

        for match in repo_tag_re.finditer(content):
            repo = match.group(1).strip("\"'")
            tag = match.group(2).strip("\"'")
            found.add(f"{repo}:{tag}")

        # Structured YAML parsing for nested objects
        try:
            docs = yaml.safe_load_all(content)
            for doc in docs:
                if isinstance(doc, dict):
                    self._extract_from_dict(doc, found)
        except Exception:
            pass

    def _extract_from_dict(self, data: dict, found: Set[str]) -> None:
        """Recursively inspect dictionaries for container images."""
        if not isinstance(data, dict):
            return

        # Check standard Pod / Container image
        if "image" in data and isinstance(data["image"], str):
            found.add(data["image"])

        # Check cephVersion image
        if "cephVersion" in data and isinstance(data["cephVersion"], dict):
            if "image" in data["cephVersion"] and isinstance(data["cephVersion"]["image"], str):
                found.add(data["cephVersion"]["image"])

        # Check repository + tag pattern
        if "repository" in data and "tag" in data and isinstance(data["repository"], str):
            tag = str(data["tag"])
            found.add(f"{data['repository']}:{tag}")

        for val in data.values():
            if isinstance(val, dict):
                self._extract_from_dict(val, found)
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, dict):
                        self._extract_from_dict(item, found)

    def _categorize(self, images: List[str]) -> Dict[str, List[str]]:
        """Group images into structured tiers."""
        tier1: List[str] = []
        tier2: List[str] = []
        tier3: List[str] = []

        for img in images:
            img_lower = img.lower()
            if any(k in img_lower for k in ["cilium", "argocd", "argo-cd", "ceph", "rook", "redis"]):
                tier1.append(img)
            elif any(
                k in img_lower
                for k in [
                    "prometheus",
                    "grafana",
                    "loki",
                    "tempo",
                    "promtail",
                    "otel",
                    "opentelemetry-collector",
                    "sloth",
                    "alertmanager",
                    "thanos",
                    "jaeger",
                    "certgen",
                    "k8s-sidecar",
                ]
            ):
                tier2.append(img)
            else:
                tier3.append(img)

        return {
            "Tier 1: Core Bootstrap": sorted(tier1),
            "Tier 2: Infrastructure & Observability": sorted(tier2),
            "Tier 3: Apps & Workloads": sorted(tier3),
        }


class GCEBuilderSession:
    """Orchestrates ephemeral GCE builder VM and captures golden image."""

    def __init__(
        self,
        project_id: str,
        zone: str,
        image_family: str = "thump-test-golden",
        image_name: Optional[str] = None,
        keep_builder: bool = False,
        dry_run: bool = False,
        repo_root: Optional[Path] = None,
    ):
        self.project_id = project_id
        self.zone = zone
        self.image_family = image_family
        self.timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.image_name = image_name or f"thump-test-golden-{self.timestamp}"
        self.builder_name = f"thump-test-image-builder-{self.timestamp}"
        self.base_image_family = "ubuntu-2404-lts-amd64"
        self.base_image_project = "ubuntu-os-cloud"
        self.keep_builder = keep_builder
        self.dry_run = dry_run
        self.repo_root = repo_root or Path(__file__).resolve().parent.parent.parent
        self._vm_created = False

        if not self.dry_run:
            atexit.register(self._cleanup)

    def run(self) -> None:
        """Execute the full golden image build pipeline."""
        console.print(
            Panel(
                f"[bold cyan]⚡ thump-test — Dynamic Golden Machine Image Builder[/bold cyan]\n\n"
                f"[bold]Project:[/bold]      {self.project_id}\n"
                f"[bold]Zone:[/bold]         {self.zone}\n"
                f"[bold]Target Image:[/bold] {self.image_name} ([yellow]{self.image_family}[/yellow])\n"
                f"[bold]Builder VM:[/bold]   {self.builder_name}",
                border_style="cyan",
            )
        )

        scanner = ManifestScanner(str(self.repo_root))
        images_by_tier = scanner.scan_repo()
        all_images = scanner.get_flat_image_list()

        self._display_image_table(images_by_tier)

        if self.dry_run:
            console.print("[yellow]>> Dry run mode active: skipping GCP infrastructure actions.[/yellow]")
            return

        start_time = time.time()

        console.print(f"\n[bold green][1/6][/bold green] Launching ephemeral builder VM ({self.builder_name})...")
        self._create_builder_vm()

        console.print(f"\n[bold green][2/6][/bold green] Waiting for builder VM SSH to become ready...")
        self._wait_for_ssh()

        console.print(f"\n[bold green][3/6][/bold green] Transferring provisioning files & running system setup...")
        self._setup_system()

        console.print(f"\n[bold green][4/6][/bold green] Pre-caching {len(all_images)} container images into containerd...")
        self._pre_cache_images(all_images)

        console.print(f"\n[bold green][5/6][/bold green] Stopping builder VM...")
        self._stop_builder_vm()

        console.print(f"\n[bold green][6/6][/bold green] Creating GCE golden image [bold cyan]{self.image_name}[/bold cyan]...")
        self._create_gce_image()

        elapsed = time.time() - start_time
        console.print(
            Panel(
                f"[bold green]✓ Golden image successfully created in {int(elapsed // 60)}m {int(elapsed % 60)}s![/bold green]\n\n"
                f"[bold]Image Name:[/bold]   {self.image_name}\n"
                f"[bold]Image Family:[/bold] {self.image_family}\n\n"
                f"To use this golden image, set in [bold]terraform.tfvars[/bold]:\n"
                f'  [cyan]boot_image = "global/images/family/{self.image_family}"[/cyan]',
                border_style="green",
            )
        )

    def _display_image_table(self, images_by_tier: Dict[str, List[str]]) -> None:
        """Render a styled table of images by category."""
        table = Table(title="📦 Discovered Container Image Inventory", show_lines=True)
        table.add_column("Tier", style="bold cyan", width=36)
        table.add_column("Count", justify="right", style="bold green", width=8)
        table.add_column("Sample Images", style="dim", overflow="fold")

        total = 0
        for tier, imgs in images_by_tier.items():
            total += len(imgs)
            sample = "\n".join(imgs[:4]) + (f"\n... +{len(imgs)-4} more" if len(imgs) > 4 else "")
            table.add_row(tier, str(len(imgs)), sample)

        console.print(table)
        console.print(f"[bold]Total target images to pre-cache:[/bold] [green]{total}[/green]\n")

    def _create_builder_vm(self) -> None:
        cmd = [
            "gcloud",
            "compute",
            "instances",
            "create",
            self.builder_name,
            f"--project={self.project_id}",
            f"--zone={self.zone}",
            "--machine-type=e2-standard-4",
            f"--image-family={self.base_image_family}",
            f"--image-project={self.base_image_project}",
            "--boot-disk-size=50GB",
            "--boot-disk-type=pd-balanced",
            "--metadata=enable-oslogin=TRUE",
            "--quiet",
        ]
        self._run_cmd(cmd, "Failed to launch builder VM")
        self._vm_created = True

    def _wait_for_ssh(self) -> None:
        for attempt in range(1, 31):
            cmd = [
                "gcloud",
                "compute",
                "ssh",
                self.builder_name,
                f"--zone={self.zone}",
                f"--project={self.project_id}",
                "--command=echo 'ssh-ready'",
                "--quiet",
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if "ssh-ready" in res.stdout:
                console.print(f"  -> SSH is ready (attempt {attempt}/30).")
                return
            time.sleep(4)
        raise RuntimeError("Timed out waiting for builder VM SSH connection.")

    def _setup_system(self) -> None:
        """Transfer provisioning directory and run common baseline directly."""
        # 1. SCP provisioning directory to builder VM
        scp_cmd = [
            "gcloud",
            "compute",
            "scp",
            "--recurse",
            str(self.repo_root / "provisioning"),
            f"{self.builder_name}:/tmp/provisioning",
            f"--zone={self.zone}",
            f"--project={self.project_id}",
            "--quiet",
        ]
        self._run_cmd(scp_cmd, "Failed to SCP provisioning files to builder VM")

        # 2. Run common.sh and install pinned CLI tools as root
        setup_script = """
set -euo pipefail

echo ">> Running real common.sh baseline..."
bash /tmp/provisioning/scripts/common.sh

echo ">> Sourcing centralized versions..."
set -a
source /tmp/provisioning/versions.env
set +a

ARCH=$(dpkg --print-architecture)

echo ">> Installing Helm ${HELM_VERSION}..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C /tmp
install -m 755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf "/tmp/linux-${ARCH}"

echo ">> Installing ArgoCD CLI ${ARGOCD_CLI_VERSION}..."
curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}"
chmod +x /usr/local/bin/argocd

echo ">> Pre-fetching k3s install script..."
curl -fsSL -o /usr/local/bin/k3s-install.sh https://get.k3s.io
chmod +x /usr/local/bin/k3s-install.sh

echo ">> Base system setup complete."
"""
        self._run_ssh_script(setup_script, "Failed executing remote system provisioning")

    def _pre_cache_images(self, images: List[str]) -> None:
        """Start containerd and pre-pull all target images with retry backoff."""
        # Write images to a temp manifest and SCP
        with tempfile.NamedTemporaryFile("w", delete=False) as tf:
            tf.write("\n".join(images) + "\n")
            temp_manifest_path = tf.name

        try:
            scp_manifest = [
                "gcloud",
                "compute",
                "scp",
                temp_manifest_path,
                f"{self.builder_name}:/tmp/image_manifest.txt",
                f"--zone={self.zone}",
                f"--project={self.project_id}",
                "--quiet",
            ]
            self._run_cmd(scp_manifest, "Failed to upload image_manifest.txt")
        finally:
            if os.path.exists(temp_manifest_path):
                os.remove(temp_manifest_path)

        pull_script = """
set -euo pipefail

echo ">> Sourcing centralized versions..."
set -a
[ -f /tmp/provisioning/versions.env ] && source /tmp/provisioning/versions.env || true
set +a

echo ">> Initializing ephemeral k3s containerd (channel: ${K3S_CHANNEL:-v1.31})..."
INSTALL_K3S_CHANNEL="${K3S_CHANNEL:-v1.31}" \
INSTALL_K3S_SKIP_ENABLE=true \
INSTALL_K3S_EXEC="server --disable-network-policy --disable-kube-proxy --disable traefik --disable servicelb" \
/usr/local/bin/k3s-install.sh

systemctl start k3s

echo ">> Waiting for containerd socket..."
ready=0
for attempt in $(seq 1 30); do
    if /usr/local/bin/k3s ctr images list &>/dev/null; then
        ready=1
        echo "   -> containerd is ready."
        break
    fi
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    echo "ERROR: containerd failed to become responsive."
    exit 1
fi

echo ">> Pre-pulling images into containerd k8s.io namespace..."
total=0
success=0
failed=0

while IFS= read -r img || [ -n "$img" ]; do
    img=$(echo "$img" | xargs)
    [ -z "$img" ] && continue
    total=$((total + 1))
    echo "[$total] Pulling: $img"
    
    pulled=0
    for attempt in 1 2 3; do
        if /usr/local/bin/k3s ctr --namespace k8s.io images pull "$img" >/dev/null 2>&1; then
            pulled=1
            echo "   -> ok"
            break
        else
            echo "   -> attempt $attempt failed, retrying in $((attempt * 2))s..."
            sleep $((attempt * 2))
        fi
    done

    if [ "$pulled" -eq 1 ]; then
        success=$((success + 1))
    else
        failed=$((failed + 1))
        echo "   -> [WARN] Failed to pre-cache $img"
    fi
done < /tmp/image_manifest.txt

echo ">> Image caching summary: $success/$total succeeded, $failed failed."

echo ">> Resetting k3s server database & generalizing system..."
systemctl stop k3s
/usr/local/bin/k3s-killall.sh || true
rm -rf /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/tls /etc/rancher/node /tmp/image_manifest.txt /tmp/provisioning

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
cloud-init clean || true

echo ">> Generalization complete."
"""
        self._run_ssh_script(pull_script, "Failed during image pre-caching")

    def _run_ssh_script(self, script: str, err_msg: str) -> None:
        """Execute a bash script on the builder VM with root privileges."""
        cmd = [
            "gcloud",
            "compute",
            "ssh",
            self.builder_name,
            f"--zone={self.zone}",
            f"--project={self.project_id}",
            "--command=sudo bash -s",
            "--quiet",
        ]
        res = subprocess.run(cmd, input=script, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"{err_msg} (exit code {res.returncode})")

    def _stop_builder_vm(self) -> None:
        cmd = [
            "gcloud",
            "compute",
            "instances",
            "stop",
            self.builder_name,
            f"--zone={self.zone}",
            f"--project={self.project_id}",
            "--quiet",
        ]
        self._run_cmd(cmd, "Failed to stop builder VM")

    def _create_gce_image(self) -> None:
        cmd = [
            "gcloud",
            "compute",
            "images",
            "create",
            self.image_name,
            f"--project={self.project_id}",
            f"--source-disk={self.builder_name}",
            f"--source-disk-zone={self.zone}",
            f"--family={self.image_family}",
            "--description=thump-test golden image with pre-baked packages and containerd image cache",
            "--quiet",
        ]
        self._run_cmd(cmd, "Failed to create GCE image")

    def _cleanup(self) -> None:
        if self._vm_created and not self.keep_builder:
            console.print(f"\n[bold yellow]>> Cleaning up ephemeral builder VM ({self.builder_name})...[/bold yellow]")
            subprocess.run(
                [
                    "gcloud",
                    "compute",
                    "instances",
                    "delete",
                    self.builder_name,
                    f"--zone={self.zone}",
                    f"--project={self.project_id}",
                    "--quiet",
                ],
                capture_output=True,
            )

    def _run_cmd(self, cmd: List[str], err_msg: str) -> subprocess.CompletedProcess:
        res = subprocess.run(cmd)
        if res.returncode != 0:
            raise RuntimeError(f"{err_msg} (exit code {res.returncode})")
        return res


def get_default_gcp_project() -> str:
    """Derive GCP project from gcloud config or fallback."""
    try:
        res = subprocess.run(["gcloud", "config", "get-value", "project"], capture_output=True, text=True)
        proj = res.stdout.strip()
        if proj:
            return proj
    except Exception:
        pass
    return "terraform-sandbox-430820"


def main() -> None:
    parser = argparse.ArgumentParser(description="thump-test dynamic golden machine image builder")
    parser.add_argument("--extract-only", "-l", action="store_true", help="Print discovered container image inventory and exit")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Walk through build pipeline without touching GCP")
    parser.add_argument("--project", default=os.getenv("PROJECT_ID", get_default_gcp_project()), help="GCP project ID")
    parser.add_argument("--zone", default=os.getenv("ZONE", "us-central1-a"), help="GCP zone for builder VM")
    parser.add_argument("--family", default=os.getenv("IMAGE_FAMILY", "thump-test-golden"), help="Target GCE image family")
    parser.add_argument("--name", default=os.getenv("IMAGE_NAME"), help="Explicit GCE image name")
    parser.add_argument("--keep-builder", action="store_true", help="Do not delete builder VM on exit/failure")

    args = parser.parse_args()

    if args.extract_only:
        scanner = ManifestScanner()
        tiers = scanner.scan_repo()
        flat = scanner.get_flat_image_list()

        table = Table(title="📦 Discovered Container Image Inventory", show_lines=True)
        table.add_column("Tier", style="bold cyan", width=36)
        table.add_column("Count", justify="right", style="bold green", width=8)
        table.add_column("Images", style="dim", overflow="fold")

        for tier, imgs in tiers.items():
            table.add_row(tier, str(len(imgs)), "\n".join(imgs))

        console.print(table)
        console.print(f"[bold]Total unique container images to pre-cache:[/bold] [bold green]{len(flat)}[/bold green]")
        sys.exit(0)

    builder = GCEBuilderSession(
        project_id=args.project,
        zone=args.zone,
        image_family=args.family,
        image_name=args.name,
        keep_builder=args.keep_builder,
        dry_run=args.dry_run,
    )
    builder.run()


if __name__ == "__main__":
    main()
