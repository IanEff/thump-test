#!/bin/bash
# thump-test — install_argocd.sh
# Bootstraps ArgoCD and seeds the root Application that drives GitOps.
#
# Requires (from /etc/thump-test.env, written by the Tofu-rendered bootstrap
# wrapper):
#   GITOPS_REPO_URL, GITOPS_REPO_TOKEN, GITOPS_SSH_KEY_PATH
#
# Ported from ceph-lab's version. The "wait for Gateway to acquire LB IP"
# step is gone — gatewayAPI.hostNetwork mode (see cilium/values.yaml) means
# there's no floating LB IP to wait on; the Gateway is reachable as soon as
# the Envoy hostNetwork pod is Running on the control-plane node.
set -euo pipefail

export KUBECONFIG=/root/.kube/config

set -a
[ -f /etc/thump-test.env ] && source /etc/thump-test.env
set +a

GITOPS_REPO_URL="${GITOPS_REPO_URL:-}"
GITOPS_REPO_TOKEN="${GITOPS_REPO_TOKEN:-}"
GITOPS_SSH_KEY_PATH="${GITOPS_SSH_KEY_PATH:-}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

if [ -z "$GITOPS_REPO_URL" ]; then
    echo "ERROR: GITOPS_REPO_URL is not set. Set the gitops_repo_url Tofu variable before applying."
    exit 1
fi

echo "══════════════════════════════════════════"
echo "  thump-test — ArgoCD bootstrap           "
echo "  Repo: ${GITOPS_REPO_URL}                 "
echo "══════════════════════════════════════════"

echo "[0a] Install argocd CLI in the background (was step [6], fully serial)"
# Nothing later in this script, and nothing in ArgoCD's own reconciliation,
# depends on /usr/local/bin/argocd existing -- only kubectl access matters
# for GitOps to proceed. Kicking this off first, backgrounded, gives it this
# script's entire remaining runtime to finish over the network instead of
# adding its own serial time at the very end. Output goes to a log instead
# of stdout since it now runs concurrently with the rest of this script.
(
    set -euo pipefail
    ARCH=$(dpkg --print-architecture)
    ARGOCD_CLI_VERSION=$(curl -sL \
        https://api.github.com/repos/argoproj/argo-cd/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    curl -fsSL -o /usr/local/bin/argocd \
        "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_CLI_VERSION}/argocd-linux-${ARCH}"
    chmod +x /usr/local/bin/argocd
    echo "argocd CLI ${ARGOCD_CLI_VERSION} installed."
) > /var/log/argocd-cli-install.log 2>&1 &

echo "[0] Substitute GITOPS_REPO_URL placeholder across all manifests"
# Must run BEFORE [1]'s pre-bootstrap Cilium apply, not after — that apply
# does `kubectl kustomize | kubectl apply` straight from this same clone, so
# if the placeholder sed hasn't happened yet, it re-renders and re-applies
# Cilium with the literal placeholder string, clobbering the correct
# k8sServiceHost install_cilium.sh already set via --set moments earlier
# (this is precisely the crash-loop this ordering used to cause).
find /ceph-lab/applications/clusters /ceph-lab/cluster-bootstrap \
    -type f -name "*.yaml" \
    -exec sed -i "s|GITOPS_REPO_URL|${GITOPS_REPO_URL}|g" {} +

echo "[0b] Substitute CONTROL_PLANE_IP placeholder in gitops.env and cilium/kustomization.yaml"
# Same placeholder-substitution convention as GITOPS_REPO_URL above — see the
# comment in applications/config/gitops.env for why this can't be a static
# committed value.
sed -i "s|GCE_CONTROL_PLANE_IP_PLACEHOLDER|${CONTROL_PLANE_INTERNAL_IP}|g" \
    /ceph-lab/applications/config/gitops.env \
    /ceph-lab/applications/infrastructure/cilium/kustomization.yaml

echo "[0c] Commit and push the substituted values back so ArgoCD (reading from git) picks them up"
cd /ceph-lab
git config user.email "thump-test-bootstrap@localhost"
git config user.name "thump-test-bootstrap"
git add -A
git commit -m "bootstrap: substitute GITOPS_REPO_URL / CONTROL_PLANE_IP placeholders" --quiet || true
# Fatal, not a warn-and-continue: a failed push here leaves ArgoCD reconciling
# the cilium Application from the still-placeholdered remote forever (it
# rejects the k8sServiceHost DNS lookup and crash-loops) — a silent, hours-
# later-discovered failure mode, not a loud one. Fail bootstrap now instead;
# see gitops_repo_token/gitops_ssh_key_path's need for WRITE access in
# variables.tf.
if [ -n "$GITOPS_SSH_KEY_PATH" ] && [ -f "${GITOPS_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="ssh -i ${GITOPS_SSH_KEY_PATH} -o StrictHostKeyChecking=no" git push
else
    git push
fi

echo "[1] Pre-bootstrap Cilium Gateway resources"
CILIUM_APP=/ceph-lab/applications/infrastructure/cilium
bootstrap_ok=0
for attempt in $(seq 1 8); do
    echo "[1] Building and applying Cilium kustomization (attempt ${attempt}/8)..."
    output=$(kubectl kustomize "${CILIUM_APP}" --enable-helm \
        | kubectl apply --server-side --force-conflicts -f - 2>&1) || true
    echo "$output"
    if echo "$output" | grep -qE 'serverside-applied| configured$| created$| unchanged$'; then
        bootstrap_ok=1
        break
    fi
    echo "[1] Attempt ${attempt}/8 incomplete; retrying in 10s..."
    sleep 10
done
if [ "$bootstrap_ok" -eq 1 ]; then
    echo "[1] Cilium resources applied. Waiting for the Gateway's hostNetwork Envoy pod to settle..."
    kubectl rollout status daemonset/cilium -n kube-system --timeout=3m || true
    kubectl wait --for=condition=Programmed gateway/cilium-gateway -n kube-system --timeout=2m || true
else
    echo "[WARN] Pre-bootstrap may be incomplete; ArgoCD will reconcile."
fi

echo "[2] Install ArgoCD (${ARGOCD_VERSION})"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "[3] Apply local bootstrap patches (insecure mode, kustomize-helm, bcrypt password)"
kubectl apply --server-side -k /ceph-lab/cluster-bootstrap/argocd/

echo "[4] Configure repository access"
# Deliberately no SSH-deploy-key branch here: GITOPS_REPO_URL (and every
# Application source built from it) is an https:// URL throughout this repo,
# and ArgoCD picks its auth method from the repo URL's scheme — a Repository
# Secret with url: https://... plus sshPrivateKey set is self-contradictory,
# and ArgoCD fails every clone with "invalid auth method" rather than falling
# back to anonymous HTTPS. The SSH deploy key (GITOPS_SSH_KEY_PATH) is only
# for this bootstrap script's own git push in step [0c]; it was never a
# credential ArgoCD's repo-server can actually use against an https:// source.
if [ -n "$GITOPS_REPO_TOKEN" ]; then
    echo "  Using HTTPS token"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: thump-test-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  password: "${GITOPS_REPO_TOKEN}"
  username: "git"
EOF
else
    echo "  WARNING: No repo credentials configured."
    echo "  If ${GITOPS_REPO_URL} is public, ArgoCD will clone it without auth."
fi

echo "[5] Apply root Application (seeds entire GitOps tree)"
kubectl apply -f /ceph-lab/cluster-bootstrap/bootstrap/root-app.yaml

echo ""
echo "✓ ArgoCD is bootstrapped! (argocd CLI install from step [0a] may still be"
echo "  finishing in the background -- check /var/log/argocd-cli-install.log)"
echo ""
echo "  UI:       https://argocd.thump-test.lab  (after manage_hosts.py has run on the Mac)"
echo "  Login:    admin / password  (CHANGE IN PRODUCTION)"
echo ""
echo "  Watch sync progress:"
echo "    kubectl get applications -n argocd -w"
echo ""
echo "  Sync waves overview:"
echo "    -15: gateway-api CRDs"
echo "    -10: cilium (reconciled)"
echo "     -6: prometheus-operator-crds"
echo "     -5: grafana, prometheus, tempo"
echo "      0: otel-collector"
echo "      1: l7-policies (CiliumNetworkPolicies)"
echo "      5: topology-catalog, loki"
echo "      6: promtail"
echo "     10: argocd-ingress"
echo "     20: rook operator"
echo "     25: rook cluster (CephCluster CR)"
echo "     30: rook storage, ceph-latency-bridge"
echo "     31: rook dashboards"
echo "     35: rook gateway routes"
echo "     40: chaos-mesh, s3-traffic-generator"
