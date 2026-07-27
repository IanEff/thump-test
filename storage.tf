# S3-compatible object storage for thump's durability layer (WAL segment
# shipper + S3Store transcript checkpoints — github.com/ianeff/thump
# internal/beat/objectstore.go, internal/publish/s3_sink.go). thump's own
# design rules this out of living on the Ceph cluster under test (a store
# backed by the thing being chaos-tested can't survive the chaos it's meant
# to prove durability against) — a real GCS bucket sidesteps that
# entirely, and needs no in-cluster Deployment/PVC the way a MinIO fallback
# would.
#
# thump's S3 client (aws-sdk-go-v2, region hardcoded to "us-east-1",
# path-style addressing — see objectstore.go) talks to GCS via its
# S3-compatible XML/interop API at a fixed, non-regional endpoint
# (https://storage.googleapis.com), authenticated with an HMAC keypair
# rather than the VM's own instance identity — so this is a self-contained
# credential, decoupled from node service-account scopes. Not yet proven
# live against this exact SDK version; treat the first real WAL-ship as the
# smoke test.

# Global bucket-name uniqueness (GCS bucket names are a single global
# namespace, unlike Kubernetes-scoped or even per-project names) — a random
# suffix means re-running `tofu apply` after a `destroy` never collides with
# the previous incarnation's name.
resource "random_id" "thump_wal_suffix" {
  byte_length = 4
}

locals {
  # Derived from var.zone rather than the separately-settable var.region --
  # they're two independent variables that must otherwise be kept in sync by
  # hand (same drift class as the 2026-07-17 zone/region-default mismatch
  # that broke fetch_kubeconfig.py/ripcord.sh's defaults). GCP zone names are
  # always <region>-<single-letter>, so this can't fall out of sync with
  # wherever the cluster's instances actually live.
  bucket_region = substr(var.zone, 0, length(var.zone) - 2)
}

resource "google_storage_bucket" "thump_wal" {
  name     = "${var.cluster_name}-thump-wal-${random_id.thump_wal_suffix.hex}"
  location = upper(local.bucket_region)

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true

  # Google-managed keys, not CMEK: a KMS keyring/IAM binding/rotation policy
  # is real overhead on a bucket whose lifecycle_rule below deletes everything
  # after 7 days anyway, against a threat model where the attacker who can
  # read the bucket can already read the HMAC key from the same project.
  public_access_prevention = "enforced"

  # Disposable by design, same as the rest of this rig (justfile's destroy
  # recipe) — a non-empty bucket would otherwise block `tofu destroy`.
  force_destroy = true

  # Auto-expire chaos-test artifacts after a week — this bucket only ever
  # needs to hold whatever the current session's WAL segments/transcripts
  # are, not an accumulating archive.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

# Dedicated service account, not the VM's default one — the HMAC key it
# issues is a standing credential that will live in thump's Kubernetes
# Secret, so its blast radius is scoped to exactly one bucket via the IAM
# binding below, nothing project-wide.
resource "google_service_account" "thump_storage" {
  account_id   = "${var.cluster_name}-thump-storage"
  display_name = "thump S3-compatible WAL/transcript storage"
}

resource "google_storage_bucket_iam_member" "thump_storage_write" {
  bucket = google_storage_bucket.thump_wal.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.thump_storage.email}"
}

# The actual S3-compatible credential thump's beats authenticate with.
# `secret` only ever appears in Tofu state and `tofu output -raw` — never in
# plan/apply logs (see the `sensitive` output in outputs.tf).
resource "google_storage_hmac_key" "thump_storage" {
  service_account_email = google_service_account.thump_storage.email
}
