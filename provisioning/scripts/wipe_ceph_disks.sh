#!/bin/bash
# thump-test — wipe_ceph_disks.sh
# DESTRUCTIVE: deletes all Rook Ceph resources and zeroes OSD disks.
# Use this to reinstall Rook without rebuilding VMs (tofu destroy/apply).
# Run from the REPO ROOT on your Mac.
#
# Ported from ceph-lab's version: `limactl shell <node> -- sudo bash -s`
# becomes `gcloud compute ssh <node> --zone --tunnel-through-iap --command`
# (port 22 is IAP-only, see network.tf); OSD disk device names
# are discovered by globbing /dev/disk/by-id/google-osd-* (matches
# cephcluster.yaml's devicePathFilter) instead of the fixed Lima vdc/vdd
# names; node names come from `gcloud compute instances list` rather than a
# NUM_NODES env var, so it stays correct regardless of num_ceph_nodes.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:?Set ZONE, e.g. ZONE=\$(tofu output -raw zone) -- don't hand-type a remembered value, it drifts (see terraform.tfvars)}"
CLUSTER_NAME="${CLUSTER_NAME:-thump-test}"
NAMESPACE="rook-ceph"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "  ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗ "
echo "  ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝ "
echo "  ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗"
echo "  ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║"
echo "  ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝"
echo "   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝ "
echo -e "${NC}"
echo -e "${YELLOW}This will DESTROY all Rook Ceph resources and zero all OSD disks.${NC}"
echo "VMs will NOT be destroyed — Rook can be reinstalled afterwards."
echo ""

NODE_NAMES=$(gcloud compute instances list --project="${PROJECT_ID}" \
    --filter="name~'^${CLUSTER_NAME}-node-'" --format='value(name)')
[ -n "$NODE_NAMES" ] || { echo "No ${CLUSTER_NAME}-node-* instances found in project ${PROJECT_ID}."; exit 1; }

echo "Ceph namespace: ${NAMESPACE}"
echo "OSD nodes:"
echo "$NODE_NAMES" | sed 's/^/  /'
echo ""
read -rp "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo ""
echo "─── Step 1: Delete Ceph StorageClasses ─────────────────────────────────"
kubectl delete storageclass rook-ceph-block rook-cephfs rook-ceph-bucket \
    --ignore-not-found=true

echo "─── Step 2: Delete Ceph CRs ─────────────────────────────────────────────"
for kind in CephFilesystem CephObjectStore CephBlockPool CephFilesystemSubVolumeGroup; do
    kubectl delete "$kind" --all -n "$NAMESPACE" --ignore-not-found=true --timeout=60s || true
done

echo "─── Step 3: Delete CephCluster ──────────────────────────────────────────"
kubectl patch cephcluster rook-ceph -n "$NAMESPACE" \
    -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl delete cephcluster rook-ceph -n "$NAMESPACE" \
    --ignore-not-found=true --timeout=60s || true

echo "─── Step 4: Uninstall Rook operator Helm release ────────────────────────"
helm uninstall rook-ceph -n "$NAMESPACE" 2>/dev/null || true
helm uninstall rook-ceph-cluster -n "$NAMESPACE" 2>/dev/null || true

echo "─── Step 5: Force-delete rook-ceph namespace ────────────────────────────"
kubectl get namespace "$NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
    | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=30s || true

echo "─── Step 6: Zero OSD disks on each worker node ──────────────────────────"
for NODE in $NODE_NAMES; do
    echo "  Wiping ${NODE}..."
    gcloud compute ssh "${NODE}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --command='
        set -e
        for dev in /dev/disk/by-id/google-osd-*; do
            [ -e "$dev" ] || continue
            REAL=$(readlink -f "$dev")
            for part in "${REAL}"?*; do
                [ -b "$part" ] && sudo umount "$part" 2>/dev/null || true
            done
            sudo dd if=/dev/zero of="$REAL" bs=4096 count=2048 2>/dev/null || true
            sudo wipefs -a "$REAL" 2>/dev/null || true
            sudo sgdisk --zap-all "$REAL" 2>/dev/null || true
            echo "  ${dev} (${REAL}) wiped"
        done
        sudo rm -rf /var/lib/rook
    '
done

echo ""
echo "✓ Wipe complete. Push updated manifests and let ArgoCD sync rook-* apps,"
echo "  or run: kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph"
