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

| script prefix | flag | class | target service |
|---|---|---|---|
| `flag-product-catalog` | `productCatalogFailure` | availability | product-catalog |
| `flag-recommendation-cache` | `recommendationCacheFailure` | latency / saturation | recommendation |
| `flag-cart` | `cartFailure` | availability | cart |
| `flag-cart-readiness` | `failedReadinessProbe` | availability (probe) | cart |

`cartFailure` and `failedReadinessProbe` both hit **cart** by different
surfaces — that's the deliberate "second plausible remediation" case §10 asked
for, so thump's ranker has a real choice (disable-the-flag vs. restart-the-pod
both look reasonable from outside). Flag names were verified against this exact
chart's `flagd/demo.flagd.json` (chart 0.40.10, flagd v0.12.9); they drift by
release, so re-check after any chart bump.

## How the flip actually reaches flagd (important — not obvious)

The flag definitions live in the **`flagd-config` ConfigMap** (ns `otel-demo`,
data key `demo.flagd.json`, a single embedded JSON blob). So `flag_set` is a
**read-modify-write**: get the blob → `jq` one flag's `defaultVariant` → patch
the whole blob back. Not a partial strategic-merge of individual flags.

But **patching the ConfigMap alone does NOT reach the running flagd.** flagd is
started with `--uri file:./etc/flagd/demo.flagd.json`, and that file is a copy
in a `config-rw` emptyDir that an **init container seeds from the ConfigMap at
pod start** (the flagd-ui sidecar writes to the same emptyDir). The live flagd
reads the emptyDir copy, not the ConfigMap. So `flag_set` patches the ConfigMap
**and `rollout restart deployment/flagd`** so the init container re-copies the
patched blob. Confirmed against chart 0.40.10.

## ArgoCD self-heal reverts flips — handled in apps-set.yaml

The `opentelemetry-demo` Application runs `automated.selfHeal: true`, and
`flagd-config` is chart-managed, so a bare `kubectl patch` gets reverted to the
git desired-state ("all flags off") within seconds — the flip never sticks.
Fixed by `ignoreDifferences` on `flagd-config`'s `/data/demo.flagd.json` (plus
`RespectIgnoreDifferences=true`) in
`applications/clusters/thump-test/apps-set.yaml`, so ArgoCD treats that one key
as runtime-owned. This applies to thump's actuator too, not just these scripts.

## ⚠️ Follow-ups

1. **Live-verify each pair** on the next bring-up (this was authored offline
   while the cluster was still settling): flip ON, confirm the demo actually
   degrades via its *own* symptoms (product-catalog errors / recommendation
   latency / cart failures), flip OFF, confirm recovery. Hold the fault longer
   than the telemetry pipeline latency (matching the Ceph-chaos timing lesson).

2. **thump-actuator implications (thump repo, CLAUDE.md §8).** §8 assumes
   "flip flagd flag = merge-patch the ConfigMap" with **no-restart hot-reload**.
   That is **not true of this deployment as-shipped** — see above. Two options
   for that track:
   - the actuator restarts flagd, exactly like these scripts (simplest); or
   - restructure the flagd component to mount `flagd-config` **directly**
     (the chart supports it:
     `components.flagd.mountedConfigMaps: [{name: config-ro, mountPath: /etc/flagd, existingConfigMap: flagd-config}]`,
     dropping the init-container copy / `config-rw` emptyDir / flagd-ui sidecar)
     so a ConfigMap patch hot-reloads with **no restart**. Two things to confirm
     live before committing that: (a) Helm actually drops the chart-default
     `initContainers`/`mountedEmptyDirs` when overridden (empty-list coalescing
     is a known Helm footgun), and (b) flagd v0.12.9's file watcher picks up the
     ConfigMap volume's atomic `..data` symlink swap. If both hold, the scripts
     here simplify to a bare `kubectl patch configmap` (drop the rollout
     restart). Left as a deliberate decision rather than an unverified guess.
