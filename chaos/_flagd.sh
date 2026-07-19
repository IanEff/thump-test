# Shared helpers for the flagd chaos scripts. Sourced, not executed.
#
# Mechanism (verified live against chart opentelemetry-demo 0.40.10 / flagd
# v0.12.9): the demo's flag definitions live in the `flagd-config` ConfigMap
# (namespace otel-demo, data key `demo.flagd.json`, a single embedded JSON blob).
# We flip a flag by rewriting that blob's `defaultVariant` for one flag. Two
# pieces of rig config make a bare `kubectl patch` actually take effect:
#
#   1. flagd mounts `flagd-config` DIRECTLY (values.yaml overrides
#      components.flagd to drop the chart's default init-container-copy-into-
#      emptyDir wiring). So a ConfigMap patch reaches flagd's file, and flagd's
#      file watcher hot-reloads it IN PLACE -- no pod restart -- then pushes the
#      change over consumers' live flag streams. Verified: patch on -> target
#      product 500 at ~t+40s; patch off -> back to 200; flagd restarts stay 0.
#   2. ArgoCD ignoreDifferences on /data/demo.flagd.json (apps-set.yaml) stops
#      selfHeal from reverting the runtime flip back to the git "all off" state.
#
# `demo.flagd.json` is one blob in one ConfigMap key, so flag_set is a
# read-modify-write (get -> jq one defaultVariant -> put the whole blob back),
# not a partial strategic merge. This is the same mechanism thump's actuator
# (thump repo, CLAUDE.md §8) uses; §8's "merge-patch the ConfigMap" holds now
# that both pieces above are in place.
#
# Propagation is not instant: the kubelet syncs the mounted ConfigMap on its
# own period (~30-60s) before flagd sees the change. That's fine -- the chaos
# timing discipline wants fault duration > pipeline latency anyway -- but don't
# expect the demo to degrade the instant this returns.

set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-thump-test}"
FLAGD_NAMESPACE="${FLAGD_NAMESPACE:-otel-demo}"
FLAGD_CONFIGMAP="flagd-config"
FLAGD_CONFIG_KEY="demo.flagd.json"

kc() { kubectl --context "$KUBE_CONTEXT" -n "$FLAGD_NAMESPACE" "$@"; }

# flag_set <flagName> <variant>
# Flip one flag's defaultVariant. flagd hot-reloads it (no restart, ~30-60s).
flag_set() {
  local flag="$1" variant="$2" current updated patch

  command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

  current="$(kc get configmap "$FLAGD_CONFIGMAP" -o json \
    | jq -r --arg k "$FLAGD_CONFIG_KEY" '.data[$k]')" \
    || { echo "ERROR: cannot read $FLAGD_CONFIGMAP/$FLAGD_CONFIG_KEY (is the demo up?)" >&2; exit 1; }

  # Use `has` for existence, not the value itself: `jq -e` exits non-zero when
  # the output is false/null, and the "off" variant's value is literally false,
  # so `jq -e '.flags[$f].variants[$v]'` would wrongly reject a valid "off".
  echo "$current" | jq -e --arg f "$flag" '.flags | has($f)' >/dev/null \
    || { echo "ERROR: flag '$flag' not defined in $FLAGD_CONFIG_KEY" >&2; exit 1; }
  echo "$current" | jq -e --arg f "$flag" --arg v "$variant" '.flags[$f].variants | has($v)' >/dev/null \
    || { echo "ERROR: variant '$variant' not defined for flag '$flag'" >&2; exit 1; }

  updated="$(echo "$current" | jq -c --arg f "$flag" --arg v "$variant" '.flags[$f].defaultVariant=$v')"
  patch="$(jq -n --arg k "$FLAGD_CONFIG_KEY" --arg val "$updated" '{data: {($k): $val}}')"

  echo ">> patching $FLAGD_CONFIGMAP: flags.$flag.defaultVariant = \"$variant\""
  kc patch configmap "$FLAGD_CONFIGMAP" --type merge -p "$patch"
  echo ">> done. flagd will hot-reload in place (no restart) once the kubelet"
  echo "   propagates the ConfigMap update -- allow ~30-60s before the demo"
  echo "   reflects flag '$flag' = '$variant'."
}
