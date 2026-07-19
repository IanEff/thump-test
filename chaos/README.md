# chaos/ — flagd fault-injection scripts (Wave 4)

Manual chaos for the **OTel demo** domain. Each armed flagd flag has an
`-on.sh` (inject the fault) and `-off.sh` (clear it) wrapper; both call
`flag_set` in `_flagd.sh`. This is the demo counterpart to the Ceph domain's
Chaos Mesh CRs — a **different mechanism on purpose**: no Chaos Mesh CR, just a
flagd flag flip.

## Usage

```bash
./flag-product-catalog-on.sh      # inject productCatalogFailure
# ... observe the demo degrade + the SLO burn ...
./flag-product-catalog-off.sh     # clear it, observe recovery
```

Env overrides: `KUBE_CONTEXT` (default `thump-test`), `FLAGD_NAMESPACE`
(default `otel-demo`). Requires `jq` and a reachable cluster (IAP tunnel up).

## Armed flags (per CLAUDE.md §10 + the Wave 3 trim decision)

| script prefix | flag | class | target | live-verified symptom |
|---|---|---|---|---|
| `flag-product-catalog` | `productCatalogFailure` | availability | product-catalog | frontend returns HTTP 500 for product `OLJCESPC7Z` (200 for others) |
| `flag-cart` | `cartFailure` | availability | cart | cart health check → `Unhealthy` (`connection failed`), cart RPCs fail |

Two flags, both availability. The **ranker's "second plausible remediation"**
case (§10) is covered by `cartFailure` alone: from outside, *restart the cart
pod* looks as reasonable as *disable the flag*, but only disabling the flag
actually clears it (a pod restart won't) — a real wrong-vs-right choice for
thump to rank.

**Dropped: the latency/saturation flag (was `recommendationCacheFailure`).**
Wave 5 recon (2026-07-19) found the trimmed demo has **no clean, reversible
latency signal** to hang an SLO on, so no latency-class flag is armed:
- `recommendationCacheFailure` — recommendation (Python) emits no request-latency
  histogram and there are no spanmetrics; its only movable signal is process
  memory, which the trimmed loadgen (~0 rec/s) never grows and which wouldn't
  reset on flag-off anyway (breaks reversibility).
- `adHighCpu` / `adManualGc` — ad's `rpc_server_duration` is far too sparse
  (~0.02 req/s, minute-long gaps) to read a baseline or burn.
- `imageSlowLoad` — its 5–10 s injection lands in the frontend-proxy (Envoy)
  layer, not `http_server_duration{service_name="frontend"}`, so it never shows
  in a labeled per-service series.

See memory `demo-slo-latency-signal-gap` for the full live evidence.

**Dropped: `failedReadinessProbe`.** It was going to be the cart "second
surface", but it's a **no-op in this deployment** — the cart Deployment has no
Kubernetes `readinessProbe` wired to cart's health-check service, so a flag that
fails that probe has nothing to act on (verified live: cart stayed `1/1 Ready`
with the flag on while flagd served it `true`). cart *does* expose the health
service, so if a `readinessProbe` is added later this flag becomes usable again.

Flag names verified against this exact chart's `flagd/demo.flagd.json` (chart
0.40.10, flagd v0.12.9); they drift by release, so re-check after any chart bump.

## How the flip reaches flagd (two rig-config pieces make it work)

The flag definitions live in the **`flagd-config` ConfigMap** (ns `otel-demo`,
data key `demo.flagd.json`, a single embedded JSON blob). So `flag_set` is a
**read-modify-write**: get the blob → `jq` one flag's `defaultVariant` → patch
the whole blob back. Not a partial strategic-merge of individual flags.

Getting a bare `kubectl patch` to actually take effect took two rig-config
changes, both discovered during live Wave-4 verification:

1. **flagd mounts `flagd-config` directly** (`values.yaml` overrides
   `components.flagd` to drop the chart's default init-container-copies-into-a-
   `config-rw`-emptyDir wiring, `flagd/values.yaml`). The chart default has flagd
   read an emptyDir *copy* seeded at pod start, which a ConfigMap patch never
   reaches — and restarting flagd to force a re-copy **severs consumers' flag
   streams and leaves them stale** (verified live: product-catalog kept serving
   HTTP 200 on the failing product until it too was restarted, even though
   flagd's OFREP already returned the flag as on). Mounting the ConfigMap
   directly lets flagd's file watcher hot-reload in place and push the change
   over live streams. **Verified: patch on → target 500 at ~t+40s, patch off →
   back to 200, flagd restarts stay 0.**
2. **ArgoCD `ignoreDifferences`** on `flagd-config`'s `/data/demo.flagd.json`
   (+ `RespectIgnoreDifferences=true`) in
   `applications/clusters/thump-test/apps-set.yaml`. The `opentelemetry-demo`
   Application runs `automated.selfHeal: true` and `flagd-config` is
   chart-managed, so without this a runtime patch is reverted to the git
   "all flags off" state within seconds. This treats that one key as
   runtime-owned. Applies to thump's actuator too, not just these scripts.

Propagation isn't instant — the kubelet syncs the mounted ConfigMap on its own
period (~30-60s) before flagd reloads. Fine for chaos (fault duration should
exceed pipeline latency anyway), but the demo won't degrade the instant a
script returns.

## ⚠️ Follow-ups

1. **Remaining live-verify.** `product-catalog` pair verified end-to-end (500 on
   the target product `OLJCESPC7Z`, 200 on a control, recovery on off — all via
   hot-reload, no restarts). Still to run the same way: the `cart` pair — confirm
   it degrades via its own symptom (cart-route 500s / health Unhealthy) and
   recovers, and that `cart-availability` burns then clears.
2. **thump actuator (thump repo, CLAUDE.md §8)** can use the exact same bare
   ConfigMap patch now that pieces 1+2 above are in place — no restart, no
   special-casing. `internal/actuate`'s dynamic-client merge-patch path applies.
