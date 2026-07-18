# thump-test

## 0. Current status (check TaskList first)

The Tofu root module, provisioning scripts, cluster-bootstrap/argocd/, and the applications/
GitOps tree were ported from rook-gce-k3s. **⚠️ ARCHITECTURE CORRECTED 2026-07-18 — the initial
port (commit `2f2584a`) DROPPED Rook/Ceph; that was wrong and must be undone.** thump-test is a
**faithful full COPY of rook-gce-k3s that KEEPS Ceph and ADDS the OTel demo alongside it** — one
cluster, two orthogonal applications. Not a lean OTel-only sibling, and *not* mutually exclusive
with rook-gce-k3s: **rook-gce-k3s is retired**, thump-test replaces it as *the* rig. Re-add
everything the `2f2584a` prune removed (see §6) before doing app-domain work. **Not yet real**:
no GitHub repo exists for this code yet (still local-only), no deploy key generated, no
`terraform.tfvars`, no justfile wired, no OTel demo Application, no collector metrics pipeline, no
`tofu apply` has run, no demo SLOs. Run `TaskList` for the live, granular to-do sequence (task IDs
and blockers) — it's more current than this section will stay; update this paragraph only if it
drifts meaningfully out of sync, don't treat it as the source of truth over TaskList.

**Two headline risks (from rook-gce-k3s's own CLAUDE.md — read them before planning):**
1. **Capacity.** 12-vCPU `CPUS_ALL_REGIONS` quota, self-service increase DENIED (gotcha #16).
   Ceph already sits at ~13 (fudged under via `node_machine_type_overrides`). Adding the demo
   on top is the crux — shrink Ceph (loop-device OSDs + single-replica pools) and trim the demo
   (`components.<name>.enabled: false`), measure-then-size. Confront it in Wave 0.
2. **The otel-collector is traces-only** (`otlp/jaeger → otlp` to Tempo, no metrics pipeline). A
   Prometheus metrics pipeline is a BUILD task, not a check — the demo SLOs are dead without it.

## 1. What this repo is

The rig for **`thump`** (`~/projects/go/thump`), a generic agentic-reliability engine (rattle →
clank → hiss → thump → click). thump has so far only been proven against Ceph, via `rook-gce-k3s`.
This repo is a **faithful copy of that rig — Ceph kept — that ADDS a second, unrelated application
alongside it**: the **OpenTelemetry Astronomy Shop demo**, a microservices app whose failures are
injected and remediated via **flagd feature flags** (flip ON = inject a failure, flip OFF = the
fix — the same switch, both directions, which makes the remediation cleanly reversible). The point
isn't the demo app; it's proving thump's engine carries no Ceph-specific knowledge by making it
reason over **two orthogonal domains on one cluster** — a Ceph PG-degradation and a demo-service
failure share no signal, no failure class, no catalog action, so thump's decisions on one can't
bleed into the other. All of that separation lives in *config* (SLO ids, `catalog-info.yaml`
topology, catalog actions); the engine learns nothing about either domain.

Full mission spec: `~/Documents/vault/Projects/thump/otel-demo-second-domain-guide.md`. Read it
before doing app-domain work (§"The failure surface = the remediation surface", §"Robust SLOs")
— this file summarizes and operationalizes it but isn't a substitute.

**The reference to copy is `rook-gce-k3s`** (not `ceph-lab`, which the vault guide's early drafts
named — that's stale) — a GCE cluster provisioned by OpenTofu, hardened over real iteration
(Cilium-on-GCP quirks, ArgoCD sync-wave retry tuning, IAP-only access, disk device-path
stability). `thump-test` is a **faithful copy** of it — same GCP project
(`terraform-sandbox-430820`), same OpenTofu stack, **Ceph kept** — that adds the OTel demo. It
**replaces** rook-gce-k3s rather than sitting beside it: the ~12-vCPU `CPUS_ALL_REGIONS` quota
only fits one GCE cluster at a time, and there's no reason to keep the Ceph-only rig once
thump-test carries Ceph *and* the demo. Retire rook-gce-k3s (`just destroy` it) once this copy is
proven; don't run both.

## 2. Source-of-truth repos

- **`~/projects/ceph/rook-gce-k3s`** — port the OpenTofu stack and provisioning scripts from here
  *near-verbatim*. Don't re-derive what already took days to harden.
- **`~/projects/ceph/ceph-lab`** — `docs/gitops-argocd-lessons.md` (ArgoCD OutOfSync debugging
  playbook) still applies; its Ceph/Rook app-layer manifests do not.
- **`~/projects/go/thump`** — owns `config/thump-test/{whir,rattle}` (SLO watch list, topology,
  evidence queries), the catalog actions, the actuator verb, and hiss policy for this domain.
  That's a parallel track in that repo, **not built here** — see §8.
- **The vault guide** (`~/Documents/vault/Projects/thump/otel-demo-second-domain-guide.md`) —
  canonical mission doc.

## 3. Key commands

Ported from `rook-gce-k3s`'s `justfile` (verify each still applies once the Tofu files are
actually copied over):

| verb | does |
|---|---|
| `init` | `tofu init` |
| `fmt` | `tofu fmt -recursive` |
| `validate` | `tofu validate` |
| `plan` | `tofu plan` |
| `apply` | `tofu apply -auto-approve` |
| `up` | `apply` + `credentials` + `thump-env`; one-shot bootstrap |
| `destroy` | `tofu destroy -auto-approve` + host/kubeconfig cleanup |
| `credentials` | `kubeconfig` + `hosts` |
| `kubeconfig` | fetch kubeconfig via `gcloud compute ssh` + OS Login |
| `hosts` / `hosts-remove` | write/remove `*.thump-test.lab`-style `/etc/hosts` entries |
| `ssh target="control-plane"` | `gcloud compute ssh` via IAP tunnel |
| `tunnel` | `gcloud compute start-iap-tunnel` for the k3s API (6443) |
| `boot-timeline` | time each ArgoCD Application reaching Healthy on cold boot |
| `gen-slos` | regenerate Prometheus rules from Sloth specs, splice into `prometheus/values.yaml` |

**Kept (Ceph domain stays):** `wipe-ceph-disks`, `generate-traffic` (seeds the RGW SLOs) — the
Ceph verbs carry over with the rest of the rig.

New, to be authored: `chaos/flag-*.sh` — flip a named flagd flag ON (chaos) or OFF (manual
recovery proof), per the guide's build sequence step 4.

## 4. Architecture

Networking / compute / storage / GitOps, carried from `rook-gce-k3s` **whole — Ceph included**.
The one real constraint is the 12-vCPU quota (headline risk #1): Ceph *and* the demo *and* the obs
stack must fit where Ceph alone already ran at ~13. So **shrink Ceph, don't drop it** — fewer/
smaller OSD workers and single-replica pools (`block-pool.yaml`/`filesystem.yaml`
`replicated.size: 1`) buy headroom while keeping a Ceph that still degrades and recovers (which is
all thump needs to react to) — and **trim the demo** to a connected subset. Exact sizing is an
open decision (§10): bring the copied Ceph rig up, measure real `kubectl describe node` CPU-request
headroom, then size the demo trim + any Ceph shrink to fit — measure-then-size, not guess.

## 5. Ported wholesale — do not re-derive

These took real iteration on `rook-gce-k3s` to get right. Copy them, adapt names
(`rook-gce-k3s` → `thump-test`), don't redesign:

- The **OpenTofu root module**: `compute.tf`, `network.tf`, `storage.tf` (OSD disks **kept** —
  shrink their count/size for quota if needed, don't remove them), `providers.tf`, `variables.tf`,
  `outputs.tf`.
- The **`.tpl` startup-script pattern**: Tofu templates stay thin wrappers (write
  `/etc/thump-test.env`, write the deploy key, `git clone` the repo) and exec plain, untemplated
  bash (`provisioning/scripts/{control-plane,node,common}.sh`) — Terraform's `${VAR}` syntax
  collides with real bash variable expansion if you template the real logic.
- **`cluster-bootstrap/argocd/`** — the `--insecure` ArgoCD install (TLS terminates at the
  Cilium Gateway), `--enable-helm`, the tuned `argocd-cmd-params-cm` concurrency
  (40 status-processors/25 op-processors, needed for a cold multi-wave bootstrap), resource
  requests/limits + node-affinity off the control-plane, NetworkPolicy resources deleted (L7
  control lives at the Cilium Gateway).
- **`applications/config/`** — the `gitops.env` single-source-of-truth + Kustomize Component
  `replacements:` pattern. Never hardcode IPs/hostnames elsewhere.
- The **ApplicationSet git-files-generator** mechanism (`infra-set.yaml` style: glob over
  `config.json` files, template `Application` objects with an explicit
  `retry: {limit:10, backoff:10s×2,max 3m}` block — the ArgoCD default retry budget gives up
  permanently on CRD-registration races otherwise).

**All 19 "what changed vs. ceph-lab" GCE-porting gotchas in `rook-gce-k3s/CLAUDE.md` §5 apply
here verbatim** (same substrate). Highlights — read the full list before touching
`provisioning/` or networking:

1. No L2Announcement on GCP's routed VPC — use `gatewayAPI.hostNetwork` + `NET_BIND_SERVICE`
   capability on `cilium-envoy`, or ports 80/443 silently fail to bind.
2. Cilium must run `routingMode: tunnel` (VXLAN) — `native` routing gets 100% cross-node
   pod-to-pod timeouts on GCP's SDN.
3. Use `devicePathFilter` (`/dev/disk/by-id/google-*`), not `deviceFilter` — GCE doesn't
   guarantee `/dev/sdX` ordering.
4. ArgoCD Applications need the explicit retry budget above for CRD-registration races.
5. `cilium` Application sits "Progressing" forever in hostNetwork mode (no floating LB address)
   — expected, not a bug.
6. SSH (22) and k3s API (6443) are IAP-tunnel-only (IAM-identity-gated), not
   `allowed_source_ranges` — critical for a roaming laptop.
7. Control-plane needs an explicit `NoSchedule` taint — k3s doesn't taint its server node like
   kubeadm does.
8. Vendored Helm chart caches must be **committed to git** (no shared virtiofs mount like Lima).
9. GitOps push-back credential needs **write** access — `install_argocd.sh` commits+pushes a
   `CONTROL_PLANE_IP`-substituted `gitops.env` back to the remote.
10. `node_machine_type_overrides` is the escape hatch for `CPUS_ALL_REGIONS` quota limits —
    already needed once on `rook-gce-k3s` and may be needed again here.

(Full 19, plus the ArgoCD OutOfSync debugging playbook from `ceph-lab/docs/gitops-argocd-lessons.md`,
live at `rook-gce-k3s/CLAUDE.md` §5 and `ceph-lab/docs/gitops-argocd-lessons.md` — read both
before debugging any sync issue.)

## 6. ⚠️ RE-ADD vs. rook-gce-k3s — the initial prune was wrong

**The `2f2584a` port DROPPED the whole Ceph domain. That was the mistake. thump-test KEEPS Ceph
(it's one of the two orthogonal apps) — re-add everything below** (shrink for quota per §4, don't
remove). The list is the exact undo list:

- `applications/rook/*` (operator/cluster/storage/gateway/dashboards) — **keep**.
- `applications/infrastructure/ceph-latency-bridge/`, `s3-traffic-generator/` — **keep** (RGW
  latency bridge feeds `ceph-osd-latency`; the traffic generator seeds the RGW SLOs).
- `applications/infrastructure/l7-policies/{ceph-clients,rook-ceph}/` — **keep**.
- `provisioning/scripts/wipe_ceph_disks.sh`, `ceph_dashboard_access.sh`, `ceph_latency_exporter.py`
  — **keep**.
- The Ceph `PrometheusServiceLevel`s in `applications/infrastructure/sloth/prometheusservicelevels.yaml`
  (`ceph-rgw-availability`, `ceph-rgw-saturation`, `ceph-osd-latency`, `ceph-health`,
  `ceph-redundancy`) — **keep** (they run *alongside* the new demo SLOs, and are the fidelity
  models to copy — see §7).
- `storage.tf`'s per-node OSD `google_compute_disk` resources — **keep** (fewer/smaller for quota
  is fine; removing them removes Ceph).
- `chaos-mesh` — **keep** (Ceph chaos still targets `rook-ceph-osd`/`mon`/`mgr` pods; flagd chaos
  is a separate ConfigMap-patch script, not a chaos-mesh CR). `kyverno` was already disabled on
  rook-gce-k3s independently — carry its disabled state over as-is.

## 7. Added vs. rook-gce-k3s

- **OTel demo Helm chart** (`open-telemetry/opentelemetry-demo`) as an ArgoCD Application.
  Values modeled on `~/projects/infra/learning/Observability-with-Grafana/OTEL-Demo.yaml`:
  disable the chart's bundled `opentelemetry-collector`/`jaeger`/`prometheus`/`grafana`, point
  its OTLP exporter at the rig's existing `otel-collector` service, **keep `loadgenerator`
  (Locust) enabled**.
- **BUILD a metrics pipeline on the otel-collector** (headline risk #2). Its live config
  (`applications/infrastructure/otel-collector/kustomization.yaml`) is traces-only —
  `receivers:[otlp,jaeger] → exporters:[otlp]` to Tempo, no metrics path at all. Add a `metrics`
  pipeline with a `prometheus`/`prometheusremotewrite` exporter (± a `spanmetrics` connector) so
  the demo's OTLP metrics become Prometheus series. This is real work, not a check, and the demo
  SLOs are dead without it — do it before authoring any SLO.
- **flagd chaos scripts** (`chaos/flag-*.sh`).
- **3–4 demo-service SLOs** in `applications/infrastructure/sloth/prometheusservicelevels.yaml`.
  Non-negotiable rules from the guide (hard lessons from Ceph SLO bugs):
  - SLI must be a real 0–1 fraction: `avg_over_time( (sli_value > bool <threshold>)[{{.window}}:1m] )`,
    never a raw ratio fed into Sloth's burn math.
  - Verify every metric name live (`curl -s "$PROM/api/v1/label/__name__/values"`) before
    trusting it — OTel demo's `http.server.request.duration`/`rpc.server.duration` histograms
    get renamed by the OTLP→prometheus exporter.
  - Match window to the SLI's sensitivity (1m sub-windows), use histogram buckets that actually
    exist.
  - One SLO per service, orthogonal — no catch-all "app health" SLO (that was `ceph-health`'s
    mistake, overlapping `ceph-redundancy`).

## 8. The thump-repo boundary (not built here)

`~/projects/go/thump` builds, in parallel, against `config/thump-test/` — **additive: both domains
side by side, the existing Ceph overlay keeps working**:
- `rattle/watch.yaml` — **both** the Ceph SLOs and the new demo SLOs.
- `whir/catalog-info.yaml` — **both** topologies: Ceph services and demo services + their deps.
- `whir/state-queries.yaml`, `whir/evidence-queries.yaml` — per-dependency health + read-only
  PromQL for clank's `metrics` tool, demo domain alongside Ceph.
- Catalog actions: one `disable-<flag>-failure` `ActionContract` per armed flag — `blastTier:
  low`, reversible, auto-band eligible.
- Actuator verb: flip flagd flag = merge-patch the flagd ConfigMap, likely reusing
  `internal/actuate`'s existing dynamic-client merge-patch path (no new `os/exec`).
- hiss policy: floors/bands for the new failure classes — should auto-approve given
  reversible + low-blast.

This repo's job is cluster + obs + app + SLOs + chaos scripts only.

## 9. Build sequence (waves, owner-tagged)

0. **[rig]** Faithful copy of `rook-gce-k3s` → `thump-test` (Ceph kept, fork renamed); make the
   capacity call (Ceph shrink + demo trim); `just up`; ArgoCD healthy, Ceph `HEALTH_OK`.
1. **[rig]** Obs stack green (prometheus/sloth/otel-collector/tempo/loki/grafana).
2. **[rig]** Collector **metrics pipeline** added — demo metrics reach Prometheus, not just Tempo.
3. **[rig]** OTel demo deployed (trimmed to fit), load gen running.
4. **[rig]** flagd chaos scripts (flip ON + manual OFF to prove reversibility by hand first),
   fault duration > pipeline latency.
5. **[rig]** Demo SLOs authored + verified live (metric names reconciled, ~0 burn at baseline,
   burns under a manually-flipped flag) — copying the `ceph-redundancy`/`ceph-rgw-saturation` shape.
6. **[thump]** `config/thump-test/*` overlay (both domains) + catalog actions + actuator verb +
   hiss policy.
7. **[both]** Live proof: flag ON → SLO burn → rattle → clank → hiss → thump → flag OFF → SLO
   recovers. Then a run with two eligible actions to exercise the ranker.

## 10. Open decisions for Ian

- **Capacity fit (the crux)** — how far to shrink Ceph (OSD node count/size, single-replica pools)
  and how far to trim the demo (`components.<name>.enabled: false`) so Ceph + demo + obs fit the
  12-vCPU quota that Ceph alone already strained. Measure-then-size on first bring-up.
- **Which 3–4 flagd flags to arm** — recommend one availability failure (e.g.
  `productCatalogFailure`), one latency/saturation failure (e.g. `recommendationCacheFailure`),
  and one where a second action is also plausible so the ranker has a real choice. Verify exact
  flag names against the deployed chart version — they drift by release.
- **GCS bucket strategy for thump's WAL/transcript storage** — new bucket dedicated to this rig
  (mirrors `rook-gce-k3s`'s `storage.tf` pattern) vs. reuse a single shared bucket across rigs.
- **click/learn write scope** — recommend out of scope, same deferral as everywhere else in
  thump v1.

## 11. Operating discipline

- **Repo-first**: fix manifests and `git commit`, don't hand-patch the live cluster with
  `kubectl edit`/`patch`/`set`.
- **Full autonomy granted on this cluster specifically.** Unlike `rook-gce-k3s` and `ceph-lab`
  (where destructive ops prompt for confirmation), Ian has explicitly authorized unprompted
  `tofu destroy`, `kubectl delete`, and other destructive ops here — this cluster exists solely
  to be broken and rebuilt in service of testing `thump`. Don't second-guess or add confirmation
  gates back in; `.claude/settings.json` reflects this deliberately.
- `thump-test` **replaces** `rook-gce-k3s` — they share one 12-vCPU GCP quota and can't both be
  up. Until rook-gce-k3s is formally retired, confirm it's `just destroy`'d before `just up` here.
  Once thump-test is proven (Ceph + demo both live), retire rook-gce-k3s for good.
