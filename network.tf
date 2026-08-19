resource "google_compute_network" "main" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Single subnet, no secondary ranges. Unlike GKE (rook-gke's vpc.tf), Cilium
# brings its own pod/service IPAM (POD_CIDR/SERVICE_CIDR in gitops.env) — the
# VPC subnet only needs to cover the VM's own addresses.
resource "google_compute_subnetwork" "main" {
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# Google's fixed IAP TCP-forwarding source range — documented, doesn't vary
# per project (https://cloud.google.com/iap/docs/using-tcp-forwarding). SSH
# and the k3s API are IAP-tunnel-only rather than gated by
# var.allowed_source_ranges: both are admin channels used from a laptop that
# roams between networks (home, coffee shops, ...), and IAP authenticates by
# IAM identity instead of source IP, so there's no client IP to track/allowlist
# at all. Callers need roles/iap.tunnelResourceAccessor on the project (see
# outputs.tf's ssh_control_plane_command) in addition to the existing
# roles/compute.osLoginUser requirement.
locals {
  iap_source_range = "35.235.240.0/20"
}

resource "google_compute_firewall" "allow_ssh" {
  name          = "${var.cluster_name}-allow-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [local.iap_source_range]
  target_tags   = ["${var.cluster_name}-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_k3s_api" {
  name          = "${var.cluster_name}-allow-k3s-api"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [local.iap_source_range]
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
}

# Cilium Gateway (gatewayAPI.hostNetwork mode, pinned to the control-plane
# node — see applications/infrastructure/cilium/values.yaml). 4245 is the
# cleartext Hubble relay listener on the same Gateway.
# Accessible via IAP TCP tunneling (local.iap_source_range) and any optional
# caller-configured CIDR ranges in var.allowed_source_ranges.
resource "google_compute_firewall" "allow_gateway" {
  name          = "${var.cluster_name}-allow-gateway"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = distinct(concat([local.iap_source_range], var.allowed_source_ranges))
  target_tags   = ["${var.cluster_name}-control-plane"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "4245"]
  }
}

# Full mesh within the subnet — cluster traffic (k3s, Cilium overlay/BGP-free
# native routing, Ceph mon/osd/mgr msgr2, NFS/iSCSI for CSI). Mirrors what
# Lima's flat host-only network gave ceph-lab for free.
resource "google_compute_firewall" "allow_internal" {
  name          = "${var.cluster_name}-allow-internal"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
