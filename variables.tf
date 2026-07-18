variable "project_id" {
  description = "The GCP Project ID where resources will be provisioned."
  type        = string
  default     = "terraform-sandbox-430820"
}

variable "region" {
  description = "The GCP region to provision the subnet in."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Single GCP zone for every instance. Zonal (not regional) on purpose — this is a test rig for thump, not an HA service; a single zone means no cross-zone control-plane replication tax on standup/teardown."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Prefix for every named resource (instances, disks, network, firewall rules)."
  type        = string
  default     = "thump-test"
}

variable "num_ceph_nodes" {
  description = "Number of k3s agent + Ceph OSD worker nodes."
  type        = number
  default     = 3
}

variable "osd_disks_per_node" {
  description = "Number of raw OSD disks attached to each worker node."
  type        = number
  default     = 2
}

variable "osd_disk_size_gb" {
  description = "Size of each OSD disk in GiB. Kept small on purpose — this is a low-traffic test cluster, not a capacity benchmark."
  type        = number
  default     = 10
}

variable "control_plane_machine_type" {
  description = "Machine type for the k3s server node."
  type        = string
  default     = "e2-medium"
}

variable "node_machine_type" {
  description = "Machine type for each k3s agent / Ceph OSD node. e2-standard-4 (4 vCPU/16GB), not e2-standard-2 — once the control-plane taint (see control-plane.sh) pushed Prometheus/Tempo/chaos-mesh/ArgoCD-server/etc. onto the 3 workers, their combined CPU *requests* (not usage) hit 100% on every worker (2/2 vCPU each) with 32 pods stuck Pending needing ~2.64 more vCPU just to clear the backlog — confirmed via `kubectl describe node`'s Allocated resources section. Memory stayed under 50% throughout, so this is purely a CPU-request shortfall; a 4th e2-standard-2 worker was considered (cheaper, ~$0.076/hr vs. ~$0.201/hr for this bump) but only brings total capacity to 8 vCPU against ~8.64 vCPU of demand — still short, and adding an OSD-hosting node changes Ceph's failure-domain topology, a bigger decision than 'add headroom.'"
  type        = string
  default     = "e2-standard-4"
}

variable "node_machine_type_overrides" {
  description = "Sparse per-node machine_type override, keyed by node index as a string (\"0\", \"1\", ...), applied instead of var.node_machine_type for that node only. Exists solely to fit under a GCP project's CPUS_ALL_REGIONS quota without changing the shared default every user of this repo gets — e.g. this project's 12 vCPU quota (denied on a self-service increase request, both +4 and +1) is exactly 1 vCPU short of 3x e2-standard-4 workers, so terraform.tfvars downsizes one node to e2-standard-2 (gitignored, per-environment — not committed here). Leave empty ({}) if your quota has room for the uniform default."
  type        = map(string)
  default     = {}
}

variable "boot_disk_size_gb" {
  description = "Boot disk size for every instance. Sized to comfortably hold /var/lib/rancher (k3s data dir) on the boot disk itself — no separate Lima-style 'rancher' data disk is needed on GCE."
  type        = number
  default     = 30
}

variable "allowed_source_ranges" {
  description = "CIDR allowlist for the Cilium Gateway (80/443/4245) firewall rule only — SSH (22) and the k3s API (6443) are IAP-tunnel-only (see network.tf's iap_source_range) and don't consume this variable. No default on purpose — every user of this repo must explicitly scope this to their own IP (and thump's, if it runs elsewhere) rather than inherit a silently-permissive default."
  type        = list(string)
}

variable "subnet_cidr" {
  description = "CIDR range for the single custom subnet. Clear of k3s's pod (10.244.0.0/16) and service (10.96.0.0/12) CIDRs."
  type        = string
  default     = "10.10.0.0/24"
}

variable "k3s_channel" {
  description = "k3s release channel."
  type        = string
  default     = "v1.33"
}

variable "gitops_repo_url" {
  description = "Git URL of this repo (SSH or HTTPS) — passed to install_argocd.sh so ArgoCD can reconcile from it. Required for ArgoCD auto-bootstrap; leave blank and set install_argocd=false to skip."
  type        = string
  default     = ""
}

variable "gitops_repo_token" {
  description = "GitHub token for HTTPS repo access (leave blank when using an SSH deploy key instead). Needs WRITE access, not just read — unlike ceph-lab, install_argocd.sh commits+pushes the CONTROL_PLANE_IP-substituted gitops.env back to this repo (see its step [5c]), because Cilium's Application is reconciled by ArgoCD from the real git remote on an ongoing basis, not just read once from the local bootstrap clone."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gitops_ssh_key_path" {
  description = "Local path to the SSH deploy private key (relative to repo root). Matches ceph-lab's convention: the key pair lives at the repo root and is gitignored. Leave blank to use gitops_repo_token (HTTPS) instead. Needs WRITE access — see gitops_repo_token's note on why."
  type        = string
  default     = "deploy_thump-test"
}

variable "install_argocd" {
  description = "Auto-bootstrap ArgoCD + the root Application during the control-plane's startup script. Requires gitops_repo_url."
  type        = bool
  default     = true
}
