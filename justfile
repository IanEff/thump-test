# rook-gce-k3s lifecycle wrapper. `just` alone lists recipes.
#
# Unlike rook-gke's justfile, there's no gke-gcloud-auth-plugin PATH dance
# here — Tofu only touches GCP (no kubernetes/helm providers), and kubectl
# auth is just a fetched kubeconfig, not an exec-plugin.

set shell := ["bash", "-euo", "pipefail", "-c"]

cluster_name := "rook-gce-k3s"
zone := "us-central1-a"
region := "us-central1"
project_id := `gcloud config get-value project 2>/dev/null`

default:
    @just --list

fmt:
    tofu fmt -recursive

init:
    tofu init

validate: init
    tofu validate

plan: init
    tofu plan

# Creates real, billed GCP resources.
apply: init
    tofu apply -auto-approve

# One-shot bootstrap: apply, fetch kubeconfig, write /etc/hosts entries,
# sync thump's S3 credentials into its .env (thump-env below).
up: apply credentials thump-env
    @echo
    @echo "Cluster is up. The k3s API is IAP-tunnel-only — open one first:"
    @echo "  just tunnel &"
    @echo "then sanity check: kubectl --context ceph-gce get nodes"
    @echo
    @echo "Watch ArgoCD sync: kubectl --context ceph-gce get applications -n argocd -w"

# Push storage.tf's S3 outputs (bucket/endpoint/HMAC key) into thump's .env
# — its Tiltfile's thump-s3-secret local_resource reads from there. Re-run
# any time you `destroy`/`apply` this rig, not just once: the bucket and its
# key are ordinary Tofu state, recreated with a new name/secret each cycle.
# THUMP_ENV_PATH overrides the default sibling-repo path.
thump-env:
    python3 provisioning/scripts/sync_thump_env.py

# Tears down every Tofu-managed resource (instances, OSD disks, static IPs,
# firewall rules, subnet, VPC) — true zero cost from here, nothing left to
# orphan since OSD disks are ordinary Tofu resources, not CSI-provisioned PVCs.
destroy: init
    tofu destroy -auto-approve
    just hosts-remove
    python3 provisioning/scripts/fetch_kubeconfig.py remove

# Fetch kubeconfig (gcloud compute ssh transport, OS Login) and merge it in,
# then write the fixed *.ceph-gce.lab hostnames into /etc/hosts.
credentials: kubeconfig hosts

kubeconfig:
    PROJECT_ID={{project_id}} ZONE={{zone}} CLUSTER_NAME={{cluster_name}} \
        python3 provisioning/scripts/fetch_kubeconfig.py add

hosts:
    sudo python3 {{justfile_directory()}}/provisioning/scripts/manage_hosts.py add "$(tofu output -raw control_plane_external_ip)"

hosts-remove:
    sudo python3 {{justfile_directory()}}/provisioning/scripts/manage_hosts.py remove

# SSH to a node. target is "control-plane" (default) or "node-<n>", e.g. `just ssh node-2`.
# Port 22 is IAP-only (network.tf) — requires roles/iap.tunnelResourceAccessor.
ssh target="control-plane":
    gcloud compute ssh {{cluster_name}}-{{target}} --zone={{zone}} --project={{project_id}} --tunnel-through-iap

# Open an IAP tunnel to the k3s API (port 6443 is IAP-only, see network.tf).
# Foreground/blocking on purpose — leave it running in its own terminal (or
# background it yourself with `just tunnel &`) for as long as you need
# kubectl access; fetch_kubeconfig.py points the kubeconfig server at
# 127.0.0.1:6443 to match.
tunnel:
    gcloud compute start-iap-tunnel {{cluster_name}}-control-plane 6443 \
        --local-host-port=localhost:6443 --zone={{zone}} --project={{project_id}}

# Regenerate Prometheus rule groups from the Sloth SLO specs (requires sloth-cli, yq).
# Splices directly into applications/infrastructure/prometheus/values.yaml —
# commit + push the diff and let ArgoCD reconcile; no kubectl apply needed.
gen-slos:
    provisioning/scripts/gen_slos.sh

# Scale s3-traffic-generator to n replicas and start the loop on every pod.
# `rollout status` returns as soon as containers are running, ahead of the
# CRI catching up — an exec right after can 500 with "container not found";
# `kubectl wait --for=condition=ready` closes that race. /start-traffic.sh
# never returns, so it's launched nohup'd and backgrounded inside the exec
# session — the session can then close without SIGHUPing it. Its stdout/stderr
# are redirected to /proc/1/fd/{1,2} (the container's own PID 1 streams, not
# the exec session's) so the traffic loop's output actually shows up in
# `kubectl logs` — /dev/null previously made this unverifiable from outside
# the pod. /start-traffic.sh itself is idempotent (pidfile-guarded) so
# re-running this on already-running pods won't stack duplicate loops.
generate-traffic n:
    kubectl scale deployment/s3-traffic-generator -n default --replicas={{n}}
    kubectl rollout status deployment/s3-traffic-generator -n default --timeout=120s
    kubectl wait pod -n default -l app=s3-traffic-generator --for=condition=ready --timeout=120s
    for pod in $(kubectl get pods -n default -l app=s3-traffic-generator -o jsonpath='{.items[*].metadata.name}'); do echo "starting traffic on $pod"; kubectl exec -n default "$pod" -- sh -c 'nohup /start-traffic.sh > /proc/1/fd/1 2> /proc/1/fd/2 &'; done
    sleep 8
    echo "--- proof of life (last 3 lines per pod) ---"
    kubectl logs -n default -l app=s3-traffic-generator --tail=3 --prefix

# DESTRUCTIVE: wipes all Rook Ceph resources + zeroes OSD disks, without
# rebuilding VMs. Use to reinstall Rook without a full tofu destroy/apply cycle.
wipe-ceph-disks:
    PROJECT_ID={{project_id}} ZONE={{zone}} CLUSTER_NAME={{cluster_name}} \
        provisioning/scripts/wipe_ceph_disks.sh

# Emergency teardown via gcloud CLI directly, bypassing OpenTofu — for when
# `just destroy` can't run (broken .terraform/, unresponsive API, etc).
pull-ripcord:
    PROJECT_ID={{project_id}} ZONE={{zone}} REGION={{region}} CLUSTER_NAME={{cluster_name}} \
        provisioning/scripts/ripcord.sh
