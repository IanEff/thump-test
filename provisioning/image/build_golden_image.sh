#!/usr/bin/env bash
#
# build_golden_image.sh
#
# Builds a pre-baked Google Compute Engine golden image for thump-test nodes.
# Pre-installs all system packages (common.sh), Helm, k3s, ArgoCD CLI, and
# pre-caches core container images in containerd (Rook Ceph, Cilium, Prometheus,
# Tempo, Loki, Flagd, OTel demo).
#
# Booting from this image cuts fresh cluster standup and GitOps convergence
# time from ~6 minutes down to ~45 seconds.
#
# Usage:
#   bash provisioning/image/build_golden_image.sh
#   or: task build-image

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || echo "terraform-sandbox-430820")}"
ZONE="${ZONE:-us-central1-a}"
IMAGE_FAMILY="${IMAGE_FAMILY:-thump-test-golden}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
IMAGE_NAME="${IMAGE_NAME:-thump-test-golden-${TIMESTAMP}}"
BUILDER_NAME="thump-test-image-builder-${TIMESTAMP}"
BASE_IMAGE_FAMILY="ubuntu-2404-lts-amd64"
BASE_IMAGE_PROJECT="ubuntu-os-cloud"

echo "════════════════════════════════════════════════════════════════════"
echo "  ⚡ thump-test — Golden Machine Image Builder                     "
echo "  Project:      ${PROJECT_ID}"
echo "  Zone:         ${ZONE}"
echo "  Target Image: ${IMAGE_NAME} (family: ${IMAGE_FAMILY})"
echo "════════════════════════════════════════════════════════════════════"
echo

cleanup() {
  echo
  echo ">> Cleaning up builder VM..."
  gcloud compute instances delete "${BUILDER_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
}
trap cleanup EXIT

echo "[1/6] Launching ephemeral builder VM (${BUILDER_NAME})..."
gcloud compute instances create "${BUILDER_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type="e2-standard-4" \
  --image-family="${BASE_IMAGE_FAMILY}" \
  --image-project="${BASE_IMAGE_PROJECT}" \
  --boot-disk-size="50GB" \
  --boot-disk-type="pd-balanced" \
  --metadata="enable-oslogin=TRUE" \
  --quiet

echo "[2/6] Waiting for builder VM SSH to be ready..."
for attempt in $(seq 1 30); do
  if gcloud compute ssh "${BUILDER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" \
    --command="echo 'ssh-ready'" --quiet 2>/dev/null | grep -q 'ssh-ready'; then
    echo "  -> SSH is ready."
    break
  fi
  sleep 5
done

echo "[3/6] Running system provisioning (common.sh + tools)..."
# Upload and execute setup script on the builder VM
gcloud compute ssh "${BUILDER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --command="sudo bash -s" <<'REMOTE_SETUP'
set -euo pipefail

echo ">> [Remote] 1. Kernel modules"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
cat > /etc/modules-load.d/rook-ceph.conf <<EOF
rbd
EOF
modprobe overlay || true
modprobe br_netfilter || true
modprobe rbd || true

echo ">> [Remote] 2. Sysctl settings"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null || true

echo ">> [Remote] 3. Registry mirrors"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
      - "https://quay.io"
  registry-1.docker.io:
    endpoint:
      - "https://registry-1.docker.io"
  registry.k8s.io:
    endpoint:
      - "https://registry.k8s.io"
  ghcr.io:
    endpoint:
      - "https://ghcr.io"
  quay.io:
    endpoint:
      - "https://quay.io"
      - "https://registry-1.docker.io"
EOF

echo ">> [Remote] 4. APT Packages"
cat > /etc/apt/apt.conf.d/99robust <<EOF
Acquire::Retries "10";
Acquire::ForceIPv4 "true";
Acquire::https::Timeout "60";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    apt-transport-https ca-certificates curl gpg \
    lvm2 gdisk sg3-utils udev open-iscsi nfs-common \
    git vim bash-completion wget jq \
    ripgrep bat fd-find tmux fish
systemctl enable --now iscsid || true

echo ">> [Remote] 5. Shell Ergonomics"
for TARGET_HOME in /etc/skel /root; do
    mkdir -p "${TARGET_HOME}/.config/fish/conf.d"
    cat > "${TARGET_HOME}/.config/fish/conf.d/thump-test.fish" <<'FISH'
abbr -a ceph-status    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status'
abbr -a ceph-df        'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph df detail'
abbr -a ceph-osd-tree  'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree'
abbr -a ceph-health    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail'
abbr -a k              'kubectl'
abbr -a kgp            'kubectl get pods -A'
abbr -a kga            'kubectl get applications -n argocd'
FISH
done

echo ">> [Remote] 6. Pre-install Helm, k3s, and ArgoCD CLI"
HELM_VERSION="v3.16.3"
ARCH=$(dpkg --print-architecture)
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C /tmp
install -m 755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf "/tmp/linux-${ARCH}"

ARGOCD_CLI_VERSION=$(curl -sL https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep '"tag_name"' | cut -d'"' -f4 || echo "v2.13.0")
curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}" || true
chmod +x /usr/local/bin/argocd || true

curl -fsSL -o /usr/local/bin/k3s-install.sh https://get.k3s.io
chmod +x /usr/local/bin/k3s-install.sh

touch /etc/thump-test-common.done
echo ">> System baseline preparation complete."
REMOTE_SETUP

echo "[4/6] Pre-caching core container images into containerd..."
gcloud compute ssh "${BUILDER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --command="sudo bash -s" <<'REMOTE_IMAGES'
set -euo pipefail

# Temporarily start k3s to spin up containerd and pull images into k8s.io namespace
INSTALL_K3S_SKIP_ENABLE=true \
INSTALL_K3S_EXEC="server --disable-network-policy --disable-kube-proxy --disable traefik --disable servicelb" \
/usr/local/bin/k3s-install.sh

systemctl start k3s
until /usr/local/bin/k3s ctr images list &>/dev/null; do sleep 2; done

IMAGES=(
  # Rook Ceph
  "docker.io/rook/ceph:v1.15.5"
  "quay.io/ceph/ceph:v18.2.4"
  # Cilium
  "quay.io/cilium/cilium:v1.16.4"
  "quay.io/cilium/operator-generic:v1.16.4"
  "quay.io/cilium/cilium-envoy:v1.30.7-1736159676-fbcfe852bc5d36e2fba3d5fc186358dbb830d1ff"
  "quay.io/cilium/hubble-relay:v1.16.4"
  # Monitoring & Obs
  "quay.io/prometheus/prometheus:v2.54.1"
  "quay.io/prometheus/node-exporter:v1.8.2"
  "quay.io/prometheus-operator/prometheus-operator:v0.77.1"
  "docker.io/grafana/grafana:11.2.0"
  "docker.io/grafana/loki:3.0.0"
  "docker.io/grafana/promtail:3.0.0"
  "docker.io/grafana/tempo:2.6.0"
  # Flagd & OTel Demo
  "ghcr.io/open-feature/flagd:v0.12.9"
  "ghcr.io/open-telemetry/opentelemetry-collector-contrib/opentelemetry-collector-contrib:0.108.0"
)

echo ">> Pulling ${#IMAGES[@]} critical images into containerd image store..."
for img in "${IMAGES[@]}"; do
  echo "   -> pulling ${img}..."
  /usr/local/bin/k3s ctr images pull "${img}" || echo "Warning: failed to pre-pull ${img}, will fetch on cold boot."
done

# Stop and reset k3s service state while keeping containerd content store intact
systemctl stop k3s
/usr/local/bin/k3s-killall.sh || true
rm -rf /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/tls /etc/rancher/node

# Generalize VM for image capture (clear machine-id, temporary logs)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
cloud-init clean || true

echo ">> Image cache populated and system generalized."
REMOTE_IMAGES

echo "[5/6] Stopping builder VM..."
gcloud compute instances stop "${BUILDER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet

echo "[6/6] Creating GCE image ${IMAGE_NAME}..."
gcloud compute images create "${IMAGE_NAME}" \
  --project="${PROJECT_ID}" \
  --source-disk="${BUILDER_NAME}" \
  --source-disk-zone="${ZONE}" \
  --family="${IMAGE_FAMILY}" \
  --description="thump-test golden image with pre-baked packages and containerd image cache" \
  --quiet

echo
echo "════════════════════════════════════════════════════════════════════"
echo "  ✓ Golden image successfully created!"
echo "  Image Name:   ${IMAGE_NAME}"
echo "  Image Family: ${IMAGE_FAMILY}"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "To use this golden image in your clusters, add this to terraform.tfvars:"
echo "  boot_image = \"global/images/family/${IMAGE_FAMILY}\""
echo
