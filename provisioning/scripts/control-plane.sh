#!/bin/bash
# rook-gce-k3s — control-plane.sh
# Installs k3s server, Helm, and Cilium CNI on the control plane node. Ported
# from ceph-lab's Lima-based control-plane.sh:
#   - No LIMA_CIDATA sourcing / no per-user kubeconfig copy (see common.sh's
#     note on OS Login not having a fixed username at provisioning time).
#   - No "wait for + publish node-token" step — the k3s token is pre-shared
#     via /etc/rook-gce-k3s.env (Tofu-generated random_password), so workers
#     never have to wait on anything the control-plane produces at runtime.
#   - tls-san includes the internal static IP (other cluster nodes reach this
#     node via it), the external static IP (harmless to keep even though
#     port 6443 is now IAP-only — see network.tf), and 127.0.0.1, since
#     kubectl reaches this node through `just tunnel`'s local IAP tunnel and
#     fetch_kubeconfig.py rewrites the server URL to 127.0.0.1 to match.
set -euo pipefail

if [ -f /etc/rook-gce-k3s-control-plane.done ]; then
    echo "[control-plane.sh] Already provisioned, skipping."
    exit 0
fi

set -a
source /etc/rook-gce-k3s.env
set +a

echo "══════════════════════════════════════════"
echo "  rook-gce-k3s — control-plane setup       "
echo "══════════════════════════════════════════"

echo "[1] Common baseline (kernel modules, sysctl, packages)"
bash /ceph-lab/provisioning/scripts/common.sh

echo "[2] Install Helm"
HELM_VERSION="v3.16.3"
ARCH=$(dpkg --print-architecture)
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/helm.tar.gz \
     "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/helm.tar.gz -C /tmp
install -m 755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

echo "[3] Write k3s server config"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
advertise-address: ${CONTROL_PLANE_INTERNAL_IP}
node-ip: ${CONTROL_PLANE_INTERNAL_IP}
token: ${K3S_TOKEN}
flannel-backend: "none"
disable-network-policy: true
disable-kube-proxy: true
disable:
  - traefik
  - servicelb
cluster-cidr: "10.244.0.0/16"
service-cidr: "10.96.0.0/12"
cluster-domain: "cluster.local"
# k3s doesn't taint its server node the way kubeadm-based clusters do, so
# regular workloads (Prometheus, Tempo, chaos-mesh, promtail, otel-collector,
# kube-state-metrics, ArgoCD's own server/repo-server/redis, ...) are free to
# land here right alongside k3s server + containerd + cilium-agent +
# cilium-envoy — on an e2-medium (2 vCPU/4GB) that's a real problem, not a
# hypothetical one: observed directly as load average 10+ on 2 cores and
# ~130MB free memory, with the API server itself becoming unresponsive to
# kubectl. Both cilium-agent and cilium-envoy already default to a wildcard
# `tolerations: [{operator: Exists}]` in the vendored chart, so they need no
# changes to keep running here; nothing else needs control-plane residency
# specifically, so everything else simply schedules onto a worker instead.
node-taint:
  - "node-role.kubernetes.io/control-plane=true:NoSchedule"
tls-san:
  - "${CONTROL_PLANE_INTERNAL_IP}"
  - "${CONTROL_PLANE_EXTERNAL_IP}"
  - "127.0.0.1"
data-dir: "/var/lib/rancher/k3s"
EOF

echo "[4] Install k3s server (channel: ${K3S_CHANNEL})"
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 30 --retry 3 --retry-delay 5 \
     -o /tmp/k3s-install.sh https://get.k3s.io
chmod +x /tmp/k3s-install.sh
timeout 300 env INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

echo "[5] Wait for API server to respond"
until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes &>/dev/null; do
    sleep 3
done

echo "[6] Set up root kubeconfig (external-facing server URL)"
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed -i "s/127\.0\.0\.1/${CONTROL_PLANE_INTERNAL_IP}/g" /root/.kube/config

echo "[7] Install Cilium CNI"
bash /ceph-lab/provisioning/scripts/install_cilium.sh

echo "[7b] Wait for API server after Cilium install"
export KUBECONFIG=/root/.kube/config
until kubectl get nodes &>/dev/null; do
    sleep 3
done

if [ "${INSTALL_ARGOCD}" = "true" ]; then
    echo "[8] Bootstrap ArgoCD"
    bash /ceph-lab/provisioning/scripts/install_argocd.sh
else
    echo "[8] INSTALL_ARGOCD=false — skipping ArgoCD bootstrap."
fi

touch /etc/rook-gce-k3s-control-plane.done
echo "✓ control-plane.sh complete"
