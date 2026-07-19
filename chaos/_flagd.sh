# Shared helpers for the flagd chaos scripts. Sourced, not executed.
#
# Mechanism (verified against chart opentelemetry-demo 0.40.10 / flagd v0.12.9):
# the demo's flag definitions live in the `flagd-config` ConfigMap (namespace
# otel-demo, data key `demo.flagd.json`). flagd is started with
# `--uri file:./etc/flagd/demo.flagd.json`, but that file is NOT the ConfigMap
# mount -- an init container copies the ConfigMap into a `config-rw` emptyDir at
# pod start, and flagd reads the emptyDir copy (the flagd-ui sidecar writes to
# the same emptyDir). So a bare `kubectl patch configmap flagd-config` does NOT
# reach the running flagd: the emptyDir copy is only refreshed when the init
# container re-runs, i.e. on a flagd pod restart. We therefore patch the
# ConfigMap AND `rollout restart deployment/flagd`.
#
# NOTE for the thump actuator track (thump repo, CLAUDE.md §8): §8 assumes
# "flip flagd flag = merge-patch the flagd ConfigMap" with no-restart hot-reload.
# That is NOT true of this deployment as-shipped (the emptyDir-copy indirection
# above). Either the actuator restarts flagd like these scripts do, or the flagd
# component is restructured to mount `flagd-config` directly (the chart supports
# it via components.flagd.mountedConfigMaps{existingConfigMap: flagd-config}) so
# a ConfigMap patch hot-reloads with no restart. See chaos/README.md.
#
# Also note: `demo.flagd.json` is a single embedded JSON blob inside one
# ConfigMap key, so this is a read-modify-write (get -> jq one field -> put the
# whole blob back), not a partial strategic merge of individual flags.

set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-thump-test}"
FLAGD_NAMESPACE="${FLAGD_NAMESPACE:-otel-demo}"
FLAGD_CONFIGMAP="flagd-config"
FLAGD_CONFIG_KEY="demo.flagd.json"

kc() { kubectl --context "$KUBE_CONTEXT" -n "$FLAGD_NAMESPACE" "$@"; }

# flag_set <flagName> <variant>
# Flip one flag's defaultVariant and make the running flagd pick it up.
flag_set() {
  local flag="$1" variant="$2" current updated patch

  command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

  current="$(kc get configmap "$FLAGD_CONFIGMAP" -o json \
    | jq -r --arg k "$FLAGD_CONFIG_KEY" '.data[$k]')" \
    || { echo "ERROR: cannot read $FLAGD_CONFIGMAP/$FLAGD_CONFIG_KEY (is the demo up?)" >&2; exit 1; }

  echo "$current" | jq -e --arg f "$flag" '.flags[$f]' >/dev/null \
    || { echo "ERROR: flag '$flag' not defined in $FLAGD_CONFIG_KEY" >&2; exit 1; }
  echo "$current" | jq -e --arg f "$flag" --arg v "$variant" '.flags[$f].variants[$v]' >/dev/null \
    || { echo "ERROR: variant '$variant' not defined for flag '$flag'" >&2; exit 1; }

  updated="$(echo "$current" | jq -c --arg f "$flag" --arg v "$variant" '.flags[$f].defaultVariant=$v')"
  patch="$(jq -n --arg k "$FLAGD_CONFIG_KEY" --arg val "$updated" '{data: {($k): $val}}')"

  echo ">> patching $FLAGD_CONFIGMAP: flags.$flag.defaultVariant = \"$variant\""
  kc patch configmap "$FLAGD_CONFIGMAP" --type merge -p "$patch"

  echo ">> restarting flagd so its init container re-copies the patched config"
  kc rollout restart deployment/flagd
  kc rollout status deployment/flagd --timeout=120s

  echo ">> done: flagd flag '$flag' is now '$variant'"
}
