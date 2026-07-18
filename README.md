# thump-test

A disposable, GitOps-managed Kubernetes testbed: **k3s + Rook Ceph +
Cilium + Prometheus/Grafana/Sloth + Chaos Mesh + Kyverno**, running on
plain GCE VMs and reconciled end-to-end by ArgoCD from this repo. It's
built to be a stable, low-cost place to point a `tilt up`-driven dev loop
at real distributed storage, real service-mesh networking, real SLO
alerting, and real injected chaos — without a laptop VM and without a
managed control plane racking up cost while you're not using it.

It was built as the integration environment for
[`thump`](https://github.com/ianeff/thump), an agentic SRE that reacts to
chaos experiments run against this cluster. Nothing about the cluster
itself is thump-specific, though — swap in any app whose Tiltfile can
target a remote kubecontext and it works the same way (see
[Bringing your own app](#bringing-your-own-app) below).

## What's running

| Layer | What |
|---|---|
| Cluster | k3s (one control-plane + N workers), stock Ubuntu 24.04 GCE VMs |
| GitOps | ArgoCD, reconciling everything below from this repo's git history |
| Storage | Rook Ceph (RBD + CephFS + RGW object store), backed by per-node attached disks |
| Networking | Cilium (CNI, Gateway API ingress, Hubble for flow visibility) |
| Observability | Prometheus + Grafana + Sloth-generated SLO alerting |
| Chaos | Chaos Mesh — Pod/Network/IO chaos experiments against live Ceph daemons |
| Policy | Kyverno — admission-time image-signature verification (currently disabled; see CLAUDE.md gotcha #17) |

Everything under `applications/`/`cluster-bootstrap/` is GitOps config
vendored from a sibling Lima-VM-based project (`ceph-lab`); only the
provisioning layer (OpenTofu + GCE instead of Lima) is native to this
repo. See [CLAUDE.md](CLAUDE.md) for the full architecture and every
deliberate deviation from that upstream.

## Prerequisites

- A GCP project with billing enabled, and `gcloud` authenticated
  (`gcloud auth login`) with `roles/compute.osLoginUser` and
  `roles/iap.tunnelResourceAccessor` at minimum.
- `tofu`, `just`, `kubectl`, `python3`.
- A GitHub repo of your own to hold this GitOps tree (ArgoCD reconciles
  from a real git remote, not your local checkout) — a fork of this one
  works.

## Quick start

```bash
# 1. Set your IP allowlist and GitOps repo (gitignored)
cat > terraform.tfvars <<EOF
allowed_source_ranges = ["YOUR.IP.HERE/32"]
gitops_repo_url        = "https://github.com/YOUR_USERNAME/thump-test.git"
EOF
# Must be https://, not git@ — ArgoCD's Application sources and its
# repo-access Secret are both https:// throughout this repo. See CLAUDE.md
# gotcha #6 for the two separate credential paths (bootstrap push-back vs.
# ArgoCD's own clone) and why mixing them up breaks one or the other.
#
# The deploy key needs WRITE access (for the bootstrap push-back only —
# ArgoCD itself clones anonymously if the repo's public, or via
# gitops_repo_token if not). Put the private half at
# ./deploy_thump-test (gitignored).

# 2. Stand up the cluster (~2-4 min: no GKE control plane, no regional
#    replication — just a handful of GCE VMs booting k3s)
just up

# 3. Open a tunnel to the k3s API — it's IAP-only, so kubectl needs this
#    running in its own terminal for the rest of the session
just tunnel &

# 4. Watch ArgoCD sync the world
kubectl --context thump-test get applications -n argocd -w

# 5. Check Ceph health
kubectl --context thump-test exec -it -n rook-ceph deploy/rook-ceph-tools -- ceph status

# 6. Tear down — true zero cost, nothing left billing
just destroy
```

## Service directory

Once `just up` finishes, these resolve via the `/etc/hosts` entries
`just credentials` writes:

| Service | URL |
|---|---|
| ArgoCD | https://argocd.thump-test.lab |
| Grafana | https://grafana.thump-test.lab |
| Ceph Dashboard | https://dashboard.thump-test.lab |
| Hubble UI | https://hubble.thump-test.lab |
| Prometheus | https://prometheus.thump-test.lab |

## Bringing your own app

The point of this rig is to give a Tiltfile-driven dev loop something
realistic to deploy against — real Ceph-backed PVCs, real Gateway API
ingress, real SLO burn-rate alerts, real chaos — while staying cheap
enough to tear down between sessions. A few things any such app's
Tiltfile needs to account for, using thump's own `CLUSTERS` table
(`Tiltfile` in the `thump` repo) as the reference:

- **kubectl context is `thump-test`**, and it's IAP-tunnel-only — `just
  tunnel` (this repo) has to already be running before `tilt up`. Tilt
  has no hook to start that tunnel itself, and there's no floating LB IP
  to fall back on if it's not.
- **Nodes are real GCE VMs on `linux/amd64`**, not your Mac's
  architecture — `docker_build(..., platform='linux/amd64')` if you're
  building from Apple Silicon.
- **Push images somewhere the cluster can actually pull from.** These
  nodes are on GCP's network with no route back to a local/laptop
  registry; a container registry your nodes have pull access to (GHCR,
  Artifact Registry, etc.) is the only thing that works here, unlike a
  fully-local kind/k3d setup.
- **`allow_k8s_contexts` needs the context named explicitly.** `thump-test`
  doesn't match Tilt's built-in "known local cluster" name patterns
  (`kind-*`, `minikube`, ...), so Tilt refuses to deploy to it unless the
  Tiltfile allow-lists it by name.
- **If your app needs durable object storage independent of the Ceph
  cluster under test** (so a store backed by the thing you're chaos-testing
  can't be the thing that proves durability against that chaos),
  `storage.tf` provisions a real GCS bucket with an S3-compatible HMAC
  credential for exactly that purpose: `thump_s3_endpoint` /
  `thump_s3_bucket` / `thump_s3_access_key` / `thump_s3_secret_key` in
  `outputs.tf`. `just thump-env` (folded into `just up`) syncs those into
  a sibling repo's `.env` for a Tiltfile `local_resource` to pick up —
  `provisioning/scripts/sync_thump_env.py` is a template for wiring the
  same pattern to a different app.
- Any Secret your app's chart expects (API keys, credentials) that would
  otherwise come from a real secrets pipeline in production is a good
  candidate for a `local_resource` that `kubectl apply`s it from a
  gitignored `.env` under Tilt — see `thump-anthropic-secret` /
  `thump-s3-secret` in the `thump` Tiltfile for the pattern.

## Chaos testing

Chaos Mesh is deployed at sync wave 40 (after Rook settles). Run an
experiment against a live OSD and watch Grafana/Prometheus — or your
app, if it's watching the same signals — reflect it:

```bash
kubectl --context thump-test apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-one-osd
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [rook-ceph]
    labelSelectors:
      app: rook-ceph-osd
EOF
```

## Tearing down

```bash
just destroy
```

Removes every Tofu-managed resource — instances, OSD disks, the GCS
bucket, static IPs, firewall rules, subnet, VPC. Nothing is
CSI-provisioned outside of Tofu's own state, so nothing is left orphaned
or billing after this runs.

See [CLAUDE.md](CLAUDE.md) for the full architecture, what's vendored
from `ceph-lab` unchanged, and every deliberate deviation from it.
