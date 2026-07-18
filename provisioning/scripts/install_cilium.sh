#!/bin/bash
# thump-test — install_cilium.sh
# Installs Gateway API CRDs (must precede Cilium) then Cilium via Helm.
# Called by control-plane.sh; can also be re-run idempotently.
#
# Unlike ceph-lab's version, this reuses the SAME values.yaml ArgoCD later
# reconciles against (applications/infrastructure/cilium/values.yaml) via -f,
# only overriding instance-specific/environment-specific values on top with
# --set. Everything else, including static-but-easy-to-forget settings like
# routingMode, belongs IN values.yaml itself — not duplicated here or in
# kustomization.yaml's valuesInline — precisely because this script's `-f`
# doesn't go through Kustomize at all. Ported from a version that duplicated
# every setting as a separate --set flag — that duplication is exactly what
# let this bootstrap-time install drift from the ArgoCD-managed one
# (ceph-lab's install_cilium.sh still has l2announcements.enabled=true, which
# doesn't even apply on GCP's routed VPC).
#
# The k8sServiceHost/Port overrides are the control-plane's IP, unknown until
# `tofu apply`. The four serviceMonitor overrides below are a second,
# different category: values.yaml enables ServiceMonitor CRs for cilium
# (needed once kube-prometheus-stack's operator is live), but THIS particular
# helm invocation runs before ArgoCD — and therefore before
# prometheus-operator-crds — exists at all, so the ServiceMonitor CRD is
# structurally guaranteed not to be registered yet. Without disabling them
# here, this install fails outright with "no matches for kind ServiceMonitor
# in version monitoring.coreos.com/v1", which (running under set -euo
# pipefail, called from control-plane.sh) aborts the entire startup script
# before install_argocd.sh ever runs — confirmed live: nodes stuck NotReady
# with no argocd namespace at all. ArgoCD's later reconciliation of the
# cilium Application (wave -10, after prometheus-operator-crds' wave -11)
# uses the unmodified values.yaml and converges these back to true once the
# CRD actually exists.
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
    --set prometheus.serviceMonitor.trustCRDsExist=false \
    --set envoy.prometheus.serviceMonitor.enabled=false \
    --set operator.prometheus.serviceMonitor.enabled=false \
    --set hubble.metrics.serviceMonitor.enabled=false \
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
