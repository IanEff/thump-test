#!/bin/bash
# rook-gce-k3s — install_cilium.sh
# Installs Gateway API CRDs (must precede Cilium) then Cilium via Helm.
# Called by control-plane.sh; can also be re-run idempotently.
#
# Unlike ceph-lab's version, this reuses the SAME values.yaml ArgoCD later
# reconciles against (applications/infrastructure/cilium/values.yaml) via -f,
# only overriding the two truly instance-specific values (the control-plane's
# IP, unknown until `tofu apply`) on top with --set. Everything else,
# including static-but-easy-to-forget settings like routingMode, belongs IN
# values.yaml itself — not duplicated here or in
# kustomization.yaml's valuesInline — precisely because this script's `-f`
# doesn't go through Kustomize at all. Ported from a version that duplicated
# every setting as a separate --set flag — that duplication is exactly what
# let this bootstrap-time install drift from the ArgoCD-managed one
# (ceph-lab's install_cilium.sh still has l2announcements.enabled=true, which
# doesn't even apply on GCP's routed VPC).
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
CONTROL_PLANE_INTERNAL_IP="${CONTROL_PLANE_INTERNAL_IP:?CONTROL_PLANE_INTERNAL_IP not set}"

export KUBECONFIG=/root/.kube/config

echo "[cilium] Gateway API CRDs (${GATEWAY_API_VERSION}) — must precede Cilium install"
kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "[cilium] Waiting for Gateway API CRDs to be established..."
kubectl wait --for=condition=Established \
    crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io \
    crd/gatewayclasses.gateway.networking.k8s.io \
    crd/grpcroutes.gateway.networking.k8s.io \
    --timeout=60s

echo "[cilium] Installing Cilium ${CILIUM_VERSION} via Helm (local vendored chart)"
CHART_DIR="/ceph-lab/applications/infrastructure/cilium/charts/cilium-${CILIUM_VERSION}/cilium"
[ -d "${CHART_DIR}" ] || { echo "[ERROR] Vendored Cilium chart not found at ${CHART_DIR}"; exit 1; }

helm upgrade --install cilium "${CHART_DIR}" \
    --namespace kube-system \
    -f /ceph-lab/applications/infrastructure/cilium/values.yaml \
    --set k8sServiceHost="${CONTROL_PLANE_INTERNAL_IP}" \
    --set k8sServicePort="6443" \
    --wait --timeout 10m

echo "[cilium] Installing Hubble CLI"
ARCH=$(dpkg --print-architecture)
# Not derived from CILIUM_VERSION — Hubble CLI releases don't reliably track
# every Cilium point release 1:1. Pinned to the same tag ceph-lab verified
# exists; bump deliberately, don't auto-compute.
HUBBLE_VERSION="v1.19.3"
curl --fail --show-error --silent --location \
     --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 \
     -o /tmp/hubble.tar.gz \
     "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${ARCH}.tar.gz"
tar -xzf /tmp/hubble.tar.gz -C /tmp hubble
install -m 755 /tmp/hubble /usr/local/bin/hubble
rm -f /tmp/hubble.tar.gz /tmp/hubble

echo "✓ Cilium ${CILIUM_VERSION} installed with Hubble + Gateway API (hostNetwork mode) support"
