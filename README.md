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
| OTel demo | https://otel-demo.thump-test.lab |

## Capacity (Wave 0b measure-then-size)

The 3 worker nodes carry the entire CPU-request budget available to
workloads (the control-plane is tainted `NoSchedule`; see
`control-plane.sh`) — 10 vCPU total (2x `e2-standard-4` + 1x
`e2-standard-2`, the whole 12-vCPU `CPUS_ALL_REGIONS` quota minus the
control-plane's `e2-medium`).

First bring-up measured **9575m requested / 10000m allocatable (96%)**
with Ceph + the obs stack alone, before a single OTel-demo pod — leaving
only ~425m free, nowhere near enough for even a trimmed demo. Breakdown by
namespace showed Ceph itself (`rook-ceph`, 7755m) as the dominant
consumer — not the obs stack (720m) or ArgoCD (650m) — and *within*
`rook-ceph`, the CSI driver sidecars (3900m across 2 ctrlplugin replicas x
2 drivers + 1 nodeplugin x2 drivers x3 workers) were larger than the 6 OSD
daemons combined (2100m). That CSI cost was a chart-defaults artifact, not
inherent to running Ceph — `csi.rbd.resources`/`csi.cephfs.resources`
(the first thing tried) isn't a real key in rook-ceph chart v1.19.4 and
was being silently ignored (confirmed via `kubectl get cm
rook-ceph-operator-config -o yaml` showing the CSI_* resource keys blank),
so the operator was running its own hardcoded defaults the whole time.

Two levers applied together:

1. **CSI resource tuning** (`applications/rook/operator/kustomization.yaml`)
   — the real keys (`csiRBDProvisionerResource`, `csiRBDPluginResource`,
   `csiCephFSProvisionerResource`, `csiCephFSPluginResource`,
   `provisionerReplicas`). Provisioner sidecars cut 100m→30m (idle in a
   single-cluster lab with no concurrent volume-op load), main plugin
   driver containers cut 250m→100m (still do real I/O plumbing),
   `provisionerReplicas` 2→1 (no HA need on a disposable rig). Frees
   ~2980m — zero Tofu/GCE cost, pure GitOps re-sync.
2. **OSD count** (`terraform.tfvars`: `osd_disks_per_node = 1`, down from
   the `2` default) — 6 OSDs → 3, halving the OSD daemon CPU footprint
   (2100m → ~1050m). Smaller Ceph failure domain, but a Ceph that still
   degrades and recovers under chaos is all thump needs to react to.

**Validated 2026-07-18** on a clean rebuild (ripcord.sh + fresh `tofu
apply`, not a live patch): worker CPU requests dropped from 9575m/96% to
**5685m/56.9%** — `rook-ceph` alone fell from 7755m to 3965m, almost
exactly matching the predicted savings (2740m CSI + 1050m OSD ≈ 3790m
predicted vs. 3790m actual). ~4315m of real headroom now exists for the
Wave 3 demo. One side effect the prediction missed: dropping to 3 OSDs at
`replicated.size: 3` means every pool's PGs land on all 3 OSDs (no room to
spread further), so "PGs per OSD" degenerates to the cluster-wide `pg_num`
total — tripped Ceph's default 250 ceiling (`applications/rook/cluster/cephcluster.yaml`'s
`mon_max_pg_per_osd: "400"` fix). Re-measure with `kubectl describe node`
after any future bring-up before trusting this number over a fresh one.

## OTel demo trim (Wave 3)

`open-telemetry/opentelemetry-demo` chart `0.40.10` (`appVersion 2.2.0`) ships 22 components.
**Confirmed via `helm show values`: none of them set `resources.requests.cpu`** (only
`resources.limits.memory`), so — unlike Ceph — the demo doesn't draw down the CPU-*request*
headroom measured above at all; the scheduler sees 0m requested per demo pod regardless of how
many are enabled. The trim below is therefore driven by real CPU/memory usage under sustained
`load-generator` traffic and by keeping the failure surface small and connected (per the mission
guide's "the failure surface = the remediation surface"), not by the CPU-request quota fight.

**Enabled** (17 components — the full core shopping path, every service reachable from
`frontend`/`frontend-proxy` on the buy flow, plus the required infra pieces):
`flagd`, `frontend-proxy`, `frontend`, `image-provider`, `load-generator`, `ad`, `cart`,
`valkey-cart`, `checkout`, `currency`, `email`, `payment`, `product-catalog`, `quote`,
`recommendation`, `shipping`, `kafka`, `postgresql`.

`kafka` looked droppable at first (nothing on the core path *consumes* from it) but `checkout`
ships a `wait-for-kafka` initContainer that blocks pod startup until `kafka:9092` is reachable —
so it's a hard dependency of `checkout`, not optional, confirmed by reading the chart's
`values.yaml` rather than assumed.

`postgresql` was originally trimmed too (see below) but had to be added back — **caught live, not
by reading values.yaml**: `product-catalog` crash-loops instantly (empty logs, exit 1) without it.
This chart version (`appVersion 2.2.0`) stores the catalog in Postgres rather than a static file
like older versions did; `product-catalog`'s own `env:` block sets `DB_CONNECTION_STRING` same as
`accounting`/`product-reviews` do, a dependency that isn't obvious from the component's name and
that the static `values.yaml` read alone missed. `product-catalog` is a non-negotiable flag target
(§10's `productCatalogFailure`), so `postgresql` stays enabled to serve it even though its other
two former dependents (`accounting`, `product-reviews`) are disabled.

**Disabled** (`components.<name>.enabled: false` — true leaves, nothing else in the enabled set
depends on them): `accounting`, `fraud-detection` (both are `kafka` consumers only), `product-reviews`,
`llm` (the `product-reviews`→`llm` chain is the demo's newest feature — an LLM-mock pod for one
leaf feature panel on the product page). `product-catalog`'s own crash-loop above is a reminder not
to trust this list without a live check — confirmed live in Phase 5 that `frontend`'s product page
loads fine with `product-reviews` absent (no hard error), not just inferred from the chart's
component graph.

Chosen against the CLAUDE.md §10 flagd-flag recommendation (verified live against this exact
chart's `flagd/demo.flagd.json` — flag names don't drift from what CLAUDE.md assumed): three
candidate flags, all on services kept enabled above —
- `productCatalogFailure` (availability) → `product-catalog`.
- `recommendationCacheFailure` (latency/saturation) → `recommendation` (depends on
  `product-catalog`, so both flags share a service dependency — deliberate, tests that thump's
  catalog action for one doesn't get confused with the other).
- `cartFailure` **and** `failedReadinessProbe` both target `cart` — the "second action plausible"
  case CLAUDE.md §10 asked for: a `cart` failure could plausibly be remediated either by disabling
  the armed flag *or* by restarting/rescheduling the pod (a readiness-probe failure looks like a
  crash-loop from outside, not obviously a feature flag), giving Wave 6's ranker a real choice
  between two catalog actions. Final flag arming decision still belongs to Wave 4 — this just
  confirms the trimmed demo doesn't accidentally disable a service Wave 4 would need.

**Verified live end-to-end on 2026-07-19**, after fixing one more thing the values file alone
couldn't catch: the demo's `OTEL_COLLECTOR_NAME` override initially pointed at
`otel-collector.tracing.svc.cluster.local`, which is `NXDOMAIN` — the otel-collector
Application's Helm `releaseName` (`otel-collector`) doesn't contain its chart name
(`opentelemetry-collector`), so the chart's fullname template falls back to
`<release>-<chart>`. The real Service, confirmed via `kubectl get svc -n tracing`, is
`otel-collector-opentelemetry-collector` — fixed in `values.yaml`. After that: all 18 `otel-demo`
pods `Running`, `product-catalog`'s DB queries and `frontend`'s `/api/products` + individual
product pages all return real `200`s, `load-generator` traces (`user_index`,
`user_get_recommendations`, ...) queryable in Tempo, and OTLP demo metrics
(`app_frontend_requests_total`, `http_server_duration_milliseconds_bucket`,
`rpc_server_duration_milliseconds_*`, ...) queryable in Prometheus — closing the loop Wave 2 left
open (its own DoD was explicitly deferred until a metrics-emitting workload existed).

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
