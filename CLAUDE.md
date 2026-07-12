# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A k3s + Rook-Ceph + Cilium + Prometheus/Grafana/Sloth + Chaos Mesh test rig for
`thump` (an agentic SRE, not part of this repo), running on plain GCE VMs
rather than GKE. It's a **fork of `~/projects/ceph/ceph-lab`** (a Lima-VM-based
version of the same stack, driven by ArgoCD GitOps) — everything under
`applications/`/`cluster-bootstrap/` is that repo's GitOps tree, vendored
almost verbatim. Only the provisioning layer (Lima → OpenTofu + GCE) changed.

The design constraints driving this repo's existence (vs. this project's
sibling `rook-gke`, which stands up a real regional GKE cluster): **zero cost
when down, cheap when up, stable** (no laptop, no spot/preemptible — chaos
experiments should be the only source of disruption thump reacts to), and
GKE fidelity isn't required (loop-device-equivalent OSDs are fine). A regional
GKE control plane alone costs ~5-8 min of standup/teardown wall time and
real ongoing billing; plain k3s on GCE VMs installs in under a minute and
costs nothing once `tofu destroy` runs.

## Commands

```bash
just up              # tofu apply + fetch kubeconfig + write /etc/hosts entries
just plan             # tofu plan
just destroy          # tofu destroy — true zero-cost teardown, confirms first
just ssh              # gcloud compute ssh --tunnel-through-iap to the control-plane (add `node-2` etc. for workers)
just tunnel            # open an IAP tunnel to the k3s API (127.0.0.1:6443) — needed for kubectl
just credentials      # re-fetch kubeconfig + /etc/hosts after a restart
just gen-slos          # regenerate Sloth-derived Prometheus rules (requires sloth-cli, yq)
just wipe-ceph-disks    # reinstall Rook without rebuilding VMs
just pull-ripcord        # gcloud-CLI emergency teardown if `just destroy` can't run
```

This repo uses **OpenTofu**, not Terraform (`tofu`, not `terraform`). Unlike
`rook-gke`, Tofu only touches GCP resources (VPC, instances, disks, static
IPs) — there is no `kubernetes`/`helm` Tofu provider and therefore no
`gke-gcloud-auth-plugin` PATH dependency anywhere in this repo. Kubernetes-side
state (Rook, Cilium, Prometheus, Chaos Mesh, ArgoCD's own Applications) is
owned entirely by ArgoCD reading from this repo's git history.

There is no test suite or linter; `tofu validate`/`tofu plan` is the
correctness check on the provisioning layer, and `kubectl get applications -n
argocd -w` / `ceph status` (via the toolbox pod) is the correctness check on
the GitOps layer.

## Architecture

1. **Networking (`network.tf`)** — one custom VPC + subnet, no secondary
   ranges (Cilium brings its own pod/service IPAM — see
   `applications/config/gitops.env`'s `POD_CIDR`/`SERVICE_CIDR` — unlike GKE
   VPC-native, which is why `rook-gke`'s `vpc.tf` needs secondary ranges and
   this repo's doesn't). SSH (22) and the k3s API (6443) are IAP-tunnel-only,
   gated by GCP's fixed IAP source range rather than `var.allowed_source_ranges`
   — those are admin channels used from a roaming laptop, and IAP authenticates
   by IAM identity instead of source IP, so there's no client IP to allowlist.
   Only the Cilium Gateway (80/443/4245 — actual app/browser traffic) is
   scoped to `var.allowed_source_ranges` (no default — every user must supply
   their own IP allowlist for that).
2. **Compute (`compute.tf`)** — one control-plane + `var.num_ceph_nodes`
   worker instances, stock `ubuntu-2404-lts-amd64` (not GKE's node image —
   this is why `rbd-module-loader.tf`'s whole workaround has no equivalent
   here; see gotcha below). Non-preemptible on purpose. OS Login
   (`enable-oslogin=TRUE`), not a fixed injected keypair/username — SSH via
   `gcloud compute ssh --tunnel-through-iap` or `just ssh` (requires
   `roles/iap.tunnelResourceAccessor` in addition to `roles/compute.osLoginUser`).
   kubectl access requires `just tunnel` running locally (IAP tunnel to 6443).
3. **Storage** — `google_compute_disk.osd` resources (small, `pd-standard`),
   attached to each worker with an explicit `device_name` so
   `applications/rook/cluster/cephcluster.yaml`'s `devicePathFilter` can match
   the stable `/dev/disk/by-id/google-osd-<node>-<disk>` symlink. These are
   ordinary Tofu-managed resources, not Kubernetes-CSI-provisioned PVCs —
   `tofu destroy` removes them like any other declared resource, which is why
   this repo has no equivalent of `rook-gke`'s orphaned-PVC-disk bug class
   (see `scripts/ripcord.sh` there for what that class of bug looks like).
4. **GitOps (`applications/`, `cluster-bootstrap/`)** — vendored from
   ceph-lab. ArgoCD, bootstrapped by `provisioning/scripts/install_argocd.sh`
   during the control-plane's startup script, reconciles everything else from
   this repo's own git history going forward.

## Repository layout

```
applications/            # ArgoCD GitOps tree, vendored from ceph-lab (see below for what changed)
cluster-bootstrap/         # ArgoCD install patches + root Application, vendored from ceph-lab
provisioning/
  scripts/
    control-plane-bootstrap.sh.tpl  # THIN Tofu-templated wrapper (see gotcha below) — control-plane's startup script
    node-bootstrap.sh.tpl            # same, for worker nodes
    common.sh, control-plane.sh, node.sh   # real provisioning logic, plain bash, ported from ceph-lab
    install_cilium.sh, install_argocd.sh    # ported, mostly unchanged (already path-based)
    gen_slos.sh                              # unchanged from ceph-lab (fully path-based)
    wipe_ceph_disks.sh, ripcord.sh             # ported to gcloud-CLI transport
    manage_hosts.py, fetch_kubeconfig.py        # new — replace ceph-lab's dnsmasq scripts + manage_k8s_config.py
network.tf, compute.tf, providers.tf, variables.tf, outputs.tf
justfile
```

## What changed vs. ceph-lab (read before touching provisioning/ or the Cilium/network config)

1. **No L2Announcement / CiliumLoadBalancerIPPool.** ceph-lab's Lima
   host-only network is a real L2 broadcast domain, so Cilium can ARP-announce
   a floating LB IP for the Gateway. GCP's VPC is routed, not L2 — there's no
   broadcast domain to answer ARP on. This repo uses `gatewayAPI.hostNetwork`
   mode instead (`applications/infrastructure/cilium/values.yaml`), pinned to
   the control-plane node via `nodeLabelSelector` (Envoy binds directly to
   that node's own ports 80/443/4245 — no floating IP exists at all).
   `applications/infrastructure/cilium/lb-pool.yaml` and `gateway.yaml`'s
   `spec.addresses` pin have no equivalent here — don't recreate them.
   **This mode needs `envoy.securityContext.capabilities` to explicitly grant
   `NET_BIND_SERVICE` plus `keepCapNetBindService: true`** (also in
   `cilium/values.yaml`) — the chart's default capability set
   (`NET_ADMIN`/`SYS_ADMIN` only) doesn't include it, and a non-root process
   can't bind a privileged port on the host netns without it. Without both,
   every `cilium-envoy` pod on every node (not just the one the
   `nodeLabelSelector` pins the Gateway to — the gap applies to the shared
   per-node Envoy DaemonSet regardless of node) fails identically: `listener
   ... failed to bind or apply socket options: cannot bind '0.0.0.0:80':
   Permission denied`, retried in a tight ~15s loop forever. This was broken
   for an entire session before being caught — it doesn't crash anything
   loudly, it just means the Gateway never actually serves traffic. If
   `0.0.0.0:80`/`:443` binds are failing in `cilium-envoy`'s own logs, check
   this first.
2. **`devicePathFilter`, not `deviceFilter`, in `cephcluster.yaml`.** GCE's
   attached-disk device naming (`/dev/sdb`, `/dev/sdc`, ...) isn't a hard
   ordering guarantee the way Lima's fixed `vdX` virtio-blk naming is. Match
   the stable `/dev/disk/by-id/google-osd-<node>-<disk>` symlink instead —
   `compute.tf` sets `device_name` explicitly on every OSD disk's
   `attached_disk` block specifically so this has something durable to match.
3. **Pre-shared k3s token, not a file-polling handshake.** ceph-lab's workers
   poll a virtiofs-shared `node-token` file the control-plane publishes after
   boot. GCE VMs have no shared host filesystem, so `compute.tf` generates the
   token up front (`random_password.k3s_token`) and bakes it into every node's
   startup script — no boot-order race, nothing to wait on.
4. **Startup scripts are THIN wrappers, not full templatefile()s.**
   `control-plane-bootstrap.sh.tpl`/`node-bootstrap.sh.tpl` only write a small
   `/etc/rook-gce-k3s.env`, clone this repo to `/ceph-lab`, and exec the real
   (untemplated, plain-bash) `provisioning/scripts/{control-plane,node}.sh`.
   **Do not port more logic into the `.tpl` files** — Terraform's
   `templatefile()` treats every `${VAR}` as its own interpolation syntax,
   colliding with legitimate bash variable expansions; keeping the templated
   surface tiny (and heavily using `$${VAR}`-escaping where unavoidable) is
   what keeps that manageable. The actual provisioning logic belongs in the
   plain scripts, delivered via git clone, not through Tofu's templating.
5. **Vendored Helm chart caches (Cilium, Prometheus, otel-collector, Sloth,
   Tempo under `applications/*/charts/`) are committed here, unlike
   ceph-lab.** ceph-lab gitignores them — they only work there because Lima's
   virtiofs mounts the whole Mac project directory into the VM, so a
   locally-`helm pull`ed cache is visible inside the VM despite never being
   committed. GCE has no such mount; the control-plane node gets this repo via
   `git clone`, so those charts have to actually be in git or
   `install_cilium.sh`'s local-chart install (which deliberately avoids a live
   `helm repo add` at boot) has nothing to install from.
6. **`GITOPS_REPO_URL` placeholder substitution now gets committed + pushed
   back, not left uncommitted.** ceph-lab's own convention is "never commit a
   substituted URL" — but that only works because the Cilium pre-bootstrap
   step (`install_argocd.sh` step [0], run *before* the pre-bootstrap Cilium
   apply specifically so that apply doesn't clobber the substitution with a
   still-templated `kustomization.yaml` — this ordering bit us once, see git
   history) applies directly from the local clone; ArgoCD's *ongoing*
   reconciliation of the `cilium` Application still reads
   `gitops.env`/`cilium/kustomization.yaml`'s `CONTROL_PLANE_IP` from the real
   git remote. `install_argocd.sh` step [0c] here commits and pushes the
   substituted values back for exactly this reason (fatally, not a
   warn-and-continue — a failed push here leaves ArgoCD reconciling from a
   permanently-placeholdered remote). **This means the credential used for
   the clone/push needs WRITE access, not just read** — different from
   ceph-lab's read-only assumption.

   **Two separate credential paths — don't mix them up:**
   - **Bootstrap push-back** (`control-plane-bootstrap.sh.tpl`'s clone +
     `install_argocd.sh`'s push): uses `gitops_ssh_key_path` (SSH) if set,
     else `gitops_repo_token` (HTTPS). Either needs WRITE. **If using the SSH
     key, the clone URL must be rewritten from `https://host/owner/repo.git`
     to `git@host:owner/repo.git`** — `GIT_SSH_COMMAND` is a no-op against an
     `https://` URL (git never invokes `ssh` for that transport), so without
     the rewrite the deploy key is silently unused: clone still succeeds
     (anonymously, fine for a public repo's read) but the later push fails
     with "could not read Username for 'https://github.com'". Both
     `control-plane-bootstrap.sh.tpl` and `node-bootstrap.sh.tpl` do this
     rewrite before using `GIT_SSH_COMMAND`.
   - **ArgoCD's own ongoing clone** (every Application's `repoURL`, always
     `https://` — see `gitops_repo_url`'s description in `variables.tf`):
     needs `gitops_repo_token` (HTTPS username/password Secret) or nothing at
     all if the repo is public. **Never hand it the SSH deploy key** — a
     Repository Secret with `url: https://...` plus `sshPrivateKey` set is
     self-contradictory (ArgoCD infers auth method from the URL scheme), and
     every clone fails with `"invalid auth method"` instead of falling back
     to anonymous HTTPS. `install_argocd.sh` step [4] deliberately has no SSH
     branch for exactly this reason.
7. **OS Login, not a fixed injected user/keypair.** `common.sh`'s shell
   ergonomics (fish/bash/vim/tmux dotfiles) install into `/etc/skel` and
   `/root`, not a single named user's home — GCE's OS Login provisions a
   POSIX username derived from your Google identity at first login, not a
   fixed `ubuntu` account the way Lima's cidata convention gives ceph-lab.
8. **No `rbd-module-loader.tf` equivalent.** That workaround exists in
   `rook-gke` because GKE's `UBUNTU_CONTAINERD` node image ships `rbd.ko`
   zstd-compressed in a way cephcsi's bundled `modprobe` can't decompress.
   Stock Ubuntu 24.04 cloud images (used here) don't have that problem —
   `common.sh` does a plain `modprobe rbd` and it works.
9. **No GKE-warden priorityClass rejection.** `rook-gke`'s `rook.tf` overrides
   `priorityClassNames` to `""` in three places because GKE's warden admission
   webhook rejects `system-node-critical`/`system-cluster-critical` outside
   GKE-managed namespaces. k3s has no such webhook — the vendored
   `applications/rook/storage/{filesystem,object-store}.yaml` use the real
   `system-cluster-critical` priority class unmodified, same as ceph-lab. If
   you ever see priority-class admission errors here, something else is
   wrong — don't reach for the GKE-specific fix.
10. **New: Chaos Mesh (`applications/infrastructure/chaos-mesh/`, wave 40).**
    Not present in ceph-lab. Runs after `rook-cluster`/`rook-storage` settle so
    PodChaos/NetworkChaos/IOChaos experiments have real `rook-ceph-osd`/
    `mon`/`mgr` pods to target — this is the concrete mechanism for "let thump
    react to injected chaos." `chaosDaemon.socketPath` is set to
    `/run/k3s/containerd/containerd.sock` (k3s's non-standard containerd
    socket path) — don't let this drift back to the upstream chart's default.
11. **`gateway-tls` is a plain static self-signed Secret, not a cert-manager
    `Certificate` CR**, same as ceph-lab (there's no live cert-manager
    component in either repo despite what ceph-lab's README's feature table
    implies) — regenerate it by hand per the comment in
    `applications/infrastructure/cilium/gateway-tls-secret.yaml` if
    `DOMAIN`/`WILDCARD_DOMAIN` ever change. No IP SAN (unlike ceph-lab's
    original) since the external IP isn't known until `tofu apply` and every
    client here already connects `--insecure` anyway.
12. **SSH and the k3s API are IAP-tunnel-only, not IP-allowlisted.** No
    equivalent gotcha in ceph-lab or `rook-gke` (both are reached over a
    stable local/VPN-adjacent network). Here the operator is a laptop that
    roams between networks with unstable/CDN-relayed egress IPs (e.g. iCloud
    Private Relay egressing through Fastly), so pinning `allowed_source_ranges`
    to a client IP doesn't hold up. `network.tf`'s `allow_ssh`/`allow_k3s_api`
    firewall rules are scoped to GCP's fixed IAP range instead — IAP
    authenticates by IAM identity, not source IP. `just ssh` and
    `fetch_kubeconfig.py` pass `--tunnel-through-iap`; kubectl access needs
    `just tunnel` running locally (forwards 6443 to `127.0.0.1`, which is why
    `control-plane.sh`'s `tls-san` includes `127.0.0.1`). The Cilium Gateway
    (80/443/4245) is unaffected — that's app/browser traffic, not an admin
    channel, and still uses `var.allowed_source_ranges`. Callers need
    `roles/iap.tunnelResourceAccessor` in addition to the existing
    `roles/compute.osLoginUser` requirement.
13. **Cilium runs in `routingMode: tunnel` (VXLAN), not `native`.** ceph-lab
    uses native routing + `autoDirectNodeRoutes` because Lima's host-only
    network is a real L2 segment — a kernel route plus ARP is enough for
    cross-node pod delivery. GCP's VPC is routed at Google's SDN layer, not
    L2: a packet only reaches a node if there's a matching VPC route
    (`google_compute_route`) for its destination CIDR, and this repo's Tofu
    creates none (Cilium's cluster-pool IPAM decides each node's pod-CIDR
    slice at runtime, not something Tofu can pre-declare a route for).
    Native routing was tried first and failed exactly as you'd expect:
    `cilium-dbg status --verbose` showed host-to-host traffic (`10.10.0.x`)
    fine, but 100% of cross-node pod-to-pod probes (`10.244.x.x`) timing out.
    Tunnel mode sidesteps this — pod traffic rides inside VXLAN between real
    node IPs, which GCP already knows how to route, no `can_ip_forward` or
    custom routes needed. Hubble is unaffected: it instruments flows via eBPF
    at the pod veth/socket layer, before encapsulation, so flow/L7 visibility
    is identical either way. See `applications/infrastructure/cilium/values.yaml`.
14. **The control-plane node carries a `node-role.kubernetes.io/control-plane=
    true:NoSchedule` taint** (`control-plane.sh`'s k3s `config.yaml`), unlike
    a default k3s install — k3s doesn't taint its server node the way
    kubeadm-based clusters do, so without this, regular workloads (Prometheus,
    Tempo, chaos-mesh, promtail, otel-collector, kube-state-metrics, ArgoCD's
    own server/repo-server/redis, ...) are free to land right alongside k3s
    server + containerd + cilium-agent + cilium-envoy. On the control-plane's
    e2-medium (2 vCPU/4GB) that's not hypothetical: observed directly as load
    average 10+ on 2 cores and ~130MB free memory, with the API server itself
    going unresponsive to kubectl. `cilium-agent`/`cilium-envoy` need no
    toleration changes — both already default to a wildcard
    `tolerations: [{operator: Exists}]` in the vendored chart. Nothing else
    needs control-plane residency specifically, so everything else simply
    schedules onto a worker instead. If you ever see kube-system addons
    (coredns, metrics-server, local-path-provisioner) or any workload stuck
    Pending with a `node(s) had untolerated taint` event, that's this taint
    doing its job — the fix is scheduling it onto a worker, not removing the
    taint. Any workload that legitimately needs to run there (none currently
    do; the Gateway binds hostNetwork ports but that's cilium-agent/
    cilium-envoy, already tolerating) needs an explicit toleration added, not
    a hostname/label-based nodeSelector requiring this node — Prometheus was
    briefly pinned here that way (for the same "stable known identity"
    reason as the Gateway) and, with no matching toleration, became
    permanently unschedulable all over again, just via a taint conflict
    instead of a bad hostname. See `applications/infrastructure/prometheus/
    values.yaml`'s comment.
15. **The `cilium` Application never reaches ArgoCD "Healthy" — it sits at
    "Progressing" forever, and that's expected, not broken.** ArgoCD's
    default health check for a `Gateway` resource waits for
    `status.conditions[type=Programmed]=True`, which in turn waits for
    `status.addresses` to populate — but `gatewayAPI.hostNetwork` mode (see
    gotcha #1) has no floating LB IP to report there by design, so that
    condition legitimately never flips true. Confirmed directly: `Accepted`
    and `ResolvedRefs` are both `True` on every listener, only `Programmed`
    sits `False`/`Pending`/`"Address not ready yet"` — the Gateway is fully
    functional, ArgoCD's health computation just doesn't know how to
    recognize that in this mode. Don't chase this as a bug.
16. **`variables.tf`'s `node_machine_type_overrides` is a sparse, per-node
    escape hatch for GCP's `CPUS_ALL_REGIONS` quota — expect it to be empty
    on most projects, but don't be surprised if `terraform.tfvars` gives one
    node a different machine type than the rest.** `node_machine_type`
    defaults to `e2-standard-4` (workers need real CPU headroom once gotcha
    #14's taint pushes Prometheus/Tempo/chaos-mesh/etc. onto them — confirmed
    via `kubectl describe node`: every worker at 100% CPU *requests* on
    `e2-standard-2`, 32 pods stuck Pending). But `e2-medium`(1 quota-vCPU,
    shared-core) `+ 3× e2-standard-4`(4 each) `= 13`, one over a fresh
    project's default 12 vCPU `CPUS_ALL_REGIONS` quota — and a self-service
    increase request (`gcloud alpha quotas preferences create`, both a
    minimal +1 and a larger +4 tried) was denied outright for this project's
    billing tier; a real increase needs a manual support request, not
    something a same-session fix can wait on. `node_machine_type_overrides`
    (map, node index as string key → machine type) downsizes one node in the
    gitignored `terraform.tfvars` to fit under quota without changing the
    shared default every user of this repo gets. If `tofu apply` ever fails
    with `Quota 'CPUS_ALL_REGIONS' exceeded`, check `gcloud alpha quotas info
    list --service=compute.googleapis.com --project=<id>` for current
    usage/limit before assuming the machine-type default itself needs to
    change.
17. **Kyverno (admission-controller-only, Enforce mode as of 2026-07-12).**
    `applications/infrastructure/kyverno/` (sync-wave 40, same tier as
    chaos-mesh) installs the upstream `kyverno/kyverno` chart v3.8.2 via
    `helmCharts:` in `kustomization.yaml` — not vendored, fetched live by
    argocd-repo-server, same as chaos-mesh (gotcha #10). Unlike chaos-mesh's
    kustomization, this one has **no top-level `namespace:` field** — the
    chart's `namespace: kyverno` is set only inside the `helmCharts:` entry,
    because a top-level namespace transformer would risk stamping
    `metadata.namespace` onto the cluster-scoped `ClusterPolicy` sibling
    resource (kustomize doesn't know custom CRD kinds are cluster-scoped;
    confirmed empirically — `kubectl kustomize --enable-helm` renders the
    policy with no `namespace:` line under `metadata:` only because of this
    omission). `values.yaml` sets `backgroundController.enabled`,
    `cleanupController.enabled`, and `reportsController.enabled` all to
    `false` — only the always-on `admissionController` runs (confirmed via
    the same render: exactly one `Deployment`,
    `kyverno-admission-controller`). **`reportsController.enabled: false`
    means `kubectl get policyreport,clusterpolicyreport -A` will always be
    empty on this rig** — don't use it to check admission results; read the
    `kyverno-admission-controller` pod's own logs (`missing digest`/
    `verifying image signatures`/`blocking admission request` trace lines,
    or `kubectl get events --field-selector reason=FailedCreate`) instead.
    The sibling `verify-thump-images-policy.yaml` ClusterPolicy (loaded via
    a plain `resources:` entry alongside `helmCharts:`, `includeCRDs: true`
    — same mixed-file pattern as
    `applications/infrastructure/cilium/kustomization.yaml`) shipped as
    `validationFailureAction: Audit` through 2026-07-11 (only `thump-clank`/
    `thump-rattle` signed at that point) but is now **`Enforce`**
    (2026-07-12, D7(b) —
    `~/Documents/vault/Projects/thump/phase-d-live-payoff-guide.md`), once
    all four beats were signed (`make sign-images`, D6) and two live-only
    findings got fixed:
    - **`mutateDigest` must flip to `true` together with `Enforce`, not
      stay `false`.** `false` is required for Audit (mutating the admitted
      object is unsafe when only auditing), but the real beat Deployments
      reference images by tag, and `validate_image.go`'s digest-presence
      check fails any tag-only ref regardless of signature unless
      something mutates the tag into a digest first. Confirmed live via
      `kyverno apply --registry` against the real running pod manifests:
      `fail:1` with `mutateDigest:false` even for a genuinely signed
      image, `pass:2/fail:0` once flipped to `true`.
    - **Kyverno's autogen (the synthetic Deployment/CronJob-level copies
      of a Pod-matched rule, for early admission-time feedback) never
      gets the mutate half — only the kind literally named in `match:`
      does.** With tag-referenced images this means the autogen copies
      fail *permanently*, signed or not: confirmed live, the autogen rule
      ran no cosign/mutate step at all before "missing digest," while the
      base Pod rule mutated+verified correctly every time. A real
      `kubectl rollout restart` got blocked at the Deployment PATCH
      itself before any pod was created, before this was diagnosed. Fixed
      by disabling autogen entirely (`pod-policies.kyverno.io/
      autogen-controllers: "none"` annotation) — enforcement now lives at
      the one place it actually works and actually matters: real Pod
      creation.
    Net effect once both are fixed: `helm upgrade`/`kubectl rollout
    restart` on the real Deployments succeed cleanly for signed images (the
    event log shows the image ref gets mutated to `tag@sha256:...`), and a
    deliberately unsigned tag (`kubectl set image deployment/<beat>
    <beat>=...:<unsigned-tag>`) gets a real `FailedCreate` event citing
    `no signatures found`. If the `thump` repo ever adds CI-based (GitHub
    Actions OIDC) signing, this policy's `subject`/`issuer` will need
    updating or broadening to a regex (`subjectRegExp`/`issuerRegExp`) to
    also trust `https://token.actions.githubusercontent.com` — the current
    exact-string attestor only trusts the interactive human login identity.
    No CiliumNetworkPolicy was added for the `kyverno` namespace, matching
    the chaos-mesh precedent (gotcha #10) — no per-namespace CNP exists
    there either, and no cluster-wide default-deny exists in
    `applications/infrastructure/l7-policies/`.

## Everything else in `applications/` (Rook, Cilium base config, Sloth, l7-policies, dashboards)

Unchanged from ceph-lab — its own CLAUDE.md gotchas about the *application*
layer still apply verbatim here, since they're about Rook/Cilium/Sloth
behavior, not the host layer: `CephFilesystemSubVolumeGroup` requirement,
`preserve*OnDelete` data-safety flags, Sloth's `sloth_id` computation
(`service`-`name`, not the CR's `metadata.name`), histogram `le` label
precision, per-namespace L7 CiliumNetworkPolicy allowlists (any new scrape
target in a CNP'd namespace needs its port added), Sloth SLI singleton-series
aggregation. See `~/projects/ceph/ceph-lab/CLAUDE.md` for the full list if
something in that layer isn't behaving as expected — check there before
assuming it's undocumented.

## Notes

- `.gitignore` excludes `.terraform/`, `*.tfstate*`, `*.tfvars*` (state/secrets)
  — but, unlike `rook-gke`/ceph-lab, does **not** exclude
  `applications/**/charts/` (see gotcha #5 above — those must be committed).
- **If the live cluster breaks, fix the repo and rebuild — don't hand-patch
  the running cluster.** Same philosophy as `rook-gke`: `tofu destroy` +
  `tofu apply` after fixing the root cause in the relevant file. This is a
  disposable test environment with no production data.
- `var.allowed_source_ranges` has no default and now only gates the Cilium
  Gateway (80/443/4245) — set it explicitly (e.g. in a gitignored
  `terraform.tfvars`) before the first `tofu apply`. SSH and the k3s API
  don't need an entry here; they're IAP-tunnel-only (see gotcha #12 above).
