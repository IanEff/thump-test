#!/bin/bash
# thump-test — node.sh
# Joins a worker node to the k3s cluster. Ported from ceph-lab's Lima-based
# node.sh:
#   - No wait-for-node-token-file step — the token is pre-shared via
#     /etc/thump-test.env (Tofu-generated), so there's nothing to poll for
#     and no boot-order race with the control-plane.
#   - Own node IP comes from the GCE metadata server, not a grep over `ip addr`
#     for a hardcoded Lima subnet prefix — works regardless of subnet_cidr.
set -euo pipefail

if [ -f /etc/thump-test-node.done ]; then
    echo "[node.sh] Already provisioned, skipping."
    exit 0
fi

set -a
source /etc/thump-test.env
set +a

echo "[1] Common baseline (kernel modules, sysctl, packages)"
bash /ceph-lab/provisioning/scripts/common.sh

NODE_IP=$(curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
echo "[node] Node IP = ${NODE_IP}"

echo "[2] Joining cluster at ${CONTROL_PLANE_INTERNAL_IP}..."
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 30 --retry 3 --retry-delay 5 \
     -o /tmp/k3s-install.sh https://get.k3s.io
chmod +x /tmp/k3s-install.sh
timeout 300 env \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    K3S_URL="https://${CONTROL_PLANE_INTERNAL_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP}" \
    /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

echo "[3] Waiting for k3s-agent service to become active..."
until systemctl is-active --quiet k3s-agent; do sleep 3; done

touch /etc/thump-test-node.done
echo "✓ node.sh complete — k3s-agent joined cluster"
