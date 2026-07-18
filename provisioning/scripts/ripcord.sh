#!/usr/bin/env bash
#
# Emergency teardown of every gcloud resource this repo creates, bypassing
# OpenTofu entirely (`just destroy` needs a working `.terraform/` state --
# this doesn't, which is the point of a ripcord). Ported from rook-gke's
# scripts/ripcord.sh; the resource set here is much smaller and lower-risk
# by design, since this repo's OSD disks are ordinary Tofu-managed
# google_compute_disk resources (not CSI-provisioned PVCs) — there's no
# "orphaned PVC-backed disk" bug class here at all, only the ordinary case
# of a partial/interrupted apply leaving named resources behind.
#
# Deliberately itemized rather than a blanket "delete everything with this
# prefix" filter, so a resource type added later is easy to slot in and
# nothing sharing this project (other unrelated infra) is ever at risk.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

PROJECT_ID=${PROJECT_ID:-"terraform-sandbox-430820"}
CLUSTER_NAME=${CLUSTER_NAME:-"thump-test"}

# Auto-discover zone/region from live resources instead of trusting a
# hardcoded/stale default or a hand-typed env var -- this script exists for
# when Tofu state can't be trusted, so the resources themselves are the only
# source of truth that can't drift out from under it (unlike a zone baked
# into a script or remembered from a previous session -- see 2026-07-17
# incident where terraform.tfvars had moved the whole rig to us-east1-b but
# every "just paste ZONE=..." example still said us-central1-a, and a stale
# manual invocation silently searched the wrong zone). ZONE/REGION env vars,
# if explicitly set, still override -- needed once every instance is already
# gone and there's nothing left to discover from.
if [ -z "${ZONE:-}" ]; then
  ZONE=$(gcloud compute instances list --project="${PROJECT_ID}" \
    --filter="name~'^${CLUSTER_NAME}-'" --format="value(zone)" 2>/dev/null | head -1)
  if [ -z "${ZONE}" ]; then
    echo "No live ${CLUSTER_NAME}-* instances found to auto-detect ZONE from." >&2
    echo "Set ZONE explicitly (e.g. ZONE=us-east1-b) if resources remain in another zone." >&2
    exit 1
  fi
fi
if [ -z "${REGION:-}" ]; then
  REGION=$(gcloud compute addresses list --project="${PROJECT_ID}" \
    --filter="name~'^${CLUSTER_NAME}-control-plane-'" --format="value(region)" 2>/dev/null | head -1)
  REGION=${REGION:-"${ZONE%-*}"}
fi

echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo "Cluster:  ${CLUSTER_NAME}"
echo

# --- 1. Instances (compute.tf: google_compute_instance.control_plane, .node) ---
echo "[1/9] Deleting instances..."
mapfile -t instances < <(gcloud compute instances list --project="${PROJECT_ID}" \
  --filter="name~'^${CLUSTER_NAME}-'" --format="value(name)" 2>/dev/null || true)
if [ "${#instances[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  gcloud compute instances delete "${instances[@]}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>&1 \
    || echo "  -> some deletes failed, check manually."
fi
echo

# --- 2. OSD disks (compute.tf: google_compute_disk.osd) ---
echo "[2/9] Deleting OSD disks..."
mapfile -t osd_disks < <(gcloud compute disks list --project="${PROJECT_ID}" \
  --filter="name~'^${CLUSTER_NAME}-osd-'" --format="value(name)" 2>/dev/null || true)
if [ "${#osd_disks[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  gcloud compute disks delete "${osd_disks[@]}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet 2>&1 \
    || echo "  -> some deletes failed, check manually."
fi
echo

# --- 3. Static IPs (compute.tf: google_compute_address.control_plane_internal/_external) ---
echo "[3/9] Deleting static IPs..."
gcloud compute addresses delete "${CLUSTER_NAME}-control-plane-internal" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> internal address already deleted or not found."
gcloud compute addresses delete "${CLUSTER_NAME}-control-plane-external" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> external address already deleted or not found."
echo

# --- 4. Firewall rules (network.tf) ---
echo "[4/9] Deleting firewall rules..."
for fw in allow-ssh allow-k3s-api allow-gateway allow-internal; do
  gcloud compute firewall-rules delete "${CLUSTER_NAME}-${fw}" \
    --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> ${CLUSTER_NAME}-${fw} already deleted or not found."
done
echo

# --- 5. Subnetwork (network.tf: google_compute_subnetwork.main) ---
echo "[5/9] Deleting subnetwork..."
gcloud compute networks subnets delete "${CLUSTER_NAME}-subnet" \
  --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 6. VPC network (network.tf: google_compute_network.main) ---
echo "[6/9] Deleting VPC network..."
gcloud compute networks delete "${CLUSTER_NAME}-vpc" \
  --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 7. thump storage HMAC key (storage.tf: google_storage_hmac_key.thump_storage) ---
# Deleted before the service account it belongs to -- an HMAC key isn't
# automatically cleaned up when its service account is deleted, it just goes
# permanently orphaned/unusable, so it has to be deactivated+deleted explicitly.
echo "[7/9] Deleting thump storage HMAC key..."
sa_email="${CLUSTER_NAME}-thump-storage@${PROJECT_ID}.iam.gserviceaccount.com"
mapfile -t hmac_keys < <(gcloud storage hmac list --service-account="${sa_email}" \
  --project="${PROJECT_ID}" --format="value(metadata.accessId)" 2>/dev/null || true)
if [ "${#hmac_keys[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  for key in "${hmac_keys[@]}"; do
    gcloud storage hmac update "${key}" --deactivate --project="${PROJECT_ID}" --quiet 2>&1 \
      || echo "  -> deactivate of ${key} failed, check manually."
    gcloud storage hmac delete "${key}" --project="${PROJECT_ID}" --quiet 2>&1 \
      || echo "  -> delete of ${key} failed, check manually."
  done
fi
echo

# --- 8. thump storage service account (storage.tf: google_service_account.thump_storage) ---
echo "[8/9] Deleting thump storage service account..."
gcloud iam service-accounts delete "${sa_email}" \
  --project="${PROJECT_ID}" --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 9. thump WAL/transcript bucket (storage.tf: google_storage_bucket.thump_wal) ---
# Name carries a random suffix (global bucket-name uniqueness, see storage.tf),
# so it's matched by prefix rather than looked up by exact name like the SA above.
echo "[9/9] Deleting thump WAL/transcript bucket..."
mapfile -t thump_buckets < <(gcloud storage buckets list --project="${PROJECT_ID}" \
  --filter="name~'^${CLUSTER_NAME}-thump-wal-'" --format="value(name)" 2>/dev/null || true)
if [ "${#thump_buckets[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  for bucket in "${thump_buckets[@]}"; do
    # --recursive deletes all object versions and the bucket itself in one call.
    gcloud storage rm --recursive "gs://${bucket}" --quiet 2>&1 \
      || echo "  -> delete of ${bucket} failed, check manually."
  done
fi
echo

# --- Verify: re-list every resource type independently rather than trusting
# delete exit codes (a delete can report failure on something already gone).
echo "Verifying teardown..."
status=0

check_gone() {
  local label="$1" list_cmd="$2"
  local left
  left=$(eval "$list_cmd" 2>/dev/null || true)
  if [ -n "$left" ]; then
    echo "  [FAIL] ${label} still present: $(echo "$left" | tr '\n' ' ')"
    status=1
  else
    echo "  [ok]   ${label} gone."
  fi
}

check_gone "Instances" \
  "gcloud compute instances list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-'\" --format='value(name)'"
check_gone "OSD disks" \
  "gcloud compute disks list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-osd-'\" --format='value(name)'"
check_gone "Static IPs" \
  "gcloud compute addresses list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-control-plane-'\" --format='value(name)'"
check_gone "Firewall rules" \
  "gcloud compute firewall-rules list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-allow-'\" --format='value(name)'"
check_gone "Subnetwork" \
  "gcloud compute networks subnets list --project '${PROJECT_ID}' --filter=\"name=${CLUSTER_NAME}-subnet\" --format='value(name)'"
check_gone "VPC network" \
  "gcloud compute networks list --project '${PROJECT_ID}' --filter=\"name=${CLUSTER_NAME}-vpc\" --format='value(name)'"
check_gone "thump storage HMAC keys" \
  "gcloud storage hmac list --service-account '${sa_email}' --project '${PROJECT_ID}' --format='value(metadata.accessId)'"
check_gone "thump storage service account" \
  "gcloud iam service-accounts list --project '${PROJECT_ID}' --filter=\"email=${sa_email}\" --format='value(email)'"
check_gone "thump WAL/transcript bucket" \
  "gcloud storage buckets list --project '${PROJECT_ID}' --filter=\"name~'^${CLUSTER_NAME}-thump-wal-'\" --format='value(name)'"

echo
if [ "$status" -eq 0 ]; then
  if [ -f terraform.tfstate ] || [ -f terraform.tfstate.backup ]; then
    rm -f terraform.tfstate terraform.tfstate.backup
    echo "Local terraform.tfstate cleared (was describing now-deleted resources)."
  fi
  echo "Ripcord complete -- all resources confirmed gone. Cost is zero from here."
else
  echo "Ripcord finished with leftovers -- see [FAIL] lines above. Investigate manually before re-applying."
  echo "Local terraform.tfstate left untouched since teardown was incomplete."
fi
exit "$status"
