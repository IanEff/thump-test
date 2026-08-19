terraform {
  required_version = ">= 1.6.0"

  backend "gcs" {
    bucket = "thump-test-tfstate-terraform-sandbox-430820"
    prefix = "thump-test/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Only the google provider is needed — unlike rook-gke, Kubernetes-side state
# (Rook, Cilium, Prometheus, ArgoCD's own Applications) is owned entirely by
# ArgoCD reading from git, not by Tofu. There is no kubernetes/helm provider
# here, and therefore no gke-gcloud-auth-plugin PATH dependency either.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
