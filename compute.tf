# Pre-shared k3s join token, known to Tofu (and therefore to every node's
# startup-script template) before any VM boots. Replaces ceph-lab's
# file-polling handshake (workers wait on a virtiofs-shared node-token file
# control-plane publishes after boot) — GCE VMs have no shared host
# filesystem, and this is simpler anyway: no boot-order race, nothing to wait
# on, agents just retry K3S_URL until the API is up.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "google_compute_address" "control_plane_internal" {
  name         = "${var.cluster_name}-control-plane-internal"
  region       = var.region
  subnetwork   = google_compute_subnetwork.main.id
  address_type = "INTERNAL"
}

resource "google_compute_address" "control_plane_external" {
  name         = "${var.cluster_name}-control-plane-external"
  region       = var.region
  address_type = "EXTERNAL"
}

locals {
  gitops_ssh_key_content = fileexists("${path.module}/${var.gitops_ssh_key_path}") ? file("${path.module}/${var.gitops_ssh_key_path}") : ""

  # NOTE on these two templates: they are THIN wrappers only — write a small
  # /etc/thump-test.env (literal values already interpolated by Tofu, no
  # runtime bash expansion needed) plus the SSH deploy key if any, then git
  # clone this repo to /ceph-lab and exec the real, plain-bash, unmodified
  # provisioning/scripts/{control-plane,node}.sh. Deliberately NOT running the
  # actual ported ceph-lab scripts through templatefile() — those are full of
  # legitimate bash ${VAR} expansions that would otherwise need constant `$$`
  # escaping to survive Terraform's own template interpolation. Keeping the
  # templated surface tiny avoids that entirely.
  control_plane_startup_script = templatefile("${path.module}/provisioning/scripts/control-plane-bootstrap.sh.tpl", {
    control_plane_internal_ip = google_compute_address.control_plane_internal.address
    control_plane_external_ip = google_compute_address.control_plane_external.address
    k3s_token                 = random_password.k3s_token.result
    k3s_channel               = var.k3s_channel
    gitops_repo_url           = var.gitops_repo_url
    gitops_repo_token         = var.gitops_repo_token
    gitops_ssh_key_content    = local.gitops_ssh_key_content
    install_argocd            = var.install_argocd
  })

  node_startup_script = templatefile("${path.module}/provisioning/scripts/node-bootstrap.sh.tpl", {
    control_plane_internal_ip = google_compute_address.control_plane_internal.address
    k3s_token                 = random_password.k3s_token.result
    k3s_channel               = var.k3s_channel
    gitops_repo_url           = var.gitops_repo_url
    gitops_repo_token         = var.gitops_repo_token
    gitops_ssh_key_content    = local.gitops_ssh_key_content
  })
}

resource "google_compute_instance" "control_plane" {
  name         = "${var.cluster_name}-control-plane"
  machine_type = var.control_plane_machine_type
  zone         = var.zone
  tags         = ["${var.cluster_name}-node", "${var.cluster_name}-control-plane"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = google_compute_address.control_plane_internal.address
    access_config {
      nat_ip = google_compute_address.control_plane_external.address
    }
  }

  metadata_startup_script = local.control_plane_startup_script

  # OS Login instead of a static injected keypair/fixed username: GCE's stock
  # Ubuntu image doesn't create a Lima-style fixed "ubuntu" user, so `gcloud
  # compute ssh <name> --zone <zone>` (which OS Login makes work out of the
  # box, tied to your gcloud identity/IAM) replaces the whole
  # limactl-shell/fixed-SSH-key path ceph-lab uses.
  metadata = {
    enable-oslogin = "TRUE"
  }

  # Non-preemptible on purpose — chaos experiments are meant to be the only
  # source of disruption thump reacts to; a spot-reclaimed node would be an
  # uncontrolled confound.
  scheduling {
    preemptible       = false
    automatic_restart = true
  }
}

# Small Tofu-managed disks, not Kubernetes-CSI-provisioned PVCs — tofu destroy
# removes them like any other declared resource. This retires the whole class
# of orphaned-disk bug rook-gke's scripts/ripcord.sh exists to mop up.
resource "google_compute_disk" "osd" {
  count = var.num_ceph_nodes * var.osd_disks_per_node

  name = "${var.cluster_name}-osd-${floor(count.index / var.osd_disks_per_node) + 1}-${(count.index % var.osd_disks_per_node) + 1}"
  zone = var.zone
  size = var.osd_disk_size_gb
  type = "pd-standard"
}

resource "google_compute_instance" "node" {
  count        = var.num_ceph_nodes
  name         = "${var.cluster_name}-node-${count.index + 1}"
  machine_type = lookup(var.node_machine_type_overrides, tostring(count.index), var.node_machine_type)
  zone         = var.zone
  tags         = ["${var.cluster_name}-node"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    access_config {} # ephemeral public IP — per-node SSH convenience only, nothing hardcodes it
  }

  # device_name is set explicitly (rather than relying on GCE's sdb/sdc
  # attachment-order default) so cephcluster.yaml's devicePathFilter can match
  # the stable /dev/disk/by-id/google-osd-<node>-<disk> symlink deterministically.
  dynamic "attached_disk" {
    for_each = range(var.osd_disks_per_node)
    content {
      source      = google_compute_disk.osd[count.index * var.osd_disks_per_node + attached_disk.value].id
      device_name = "osd-${count.index + 1}-${attached_disk.value + 1}"
    }
  }

  metadata_startup_script = local.node_startup_script

  metadata = {
    enable-oslogin = "TRUE"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  depends_on = [google_compute_instance.control_plane]
}
