#!/bin/bash
# thump-test — common.sh
# Runs on every node (control plane + workers) during provisioning.
# Sets up kernel modules, sysctl, and shell ergonomics. Ported from ceph-lab's
# Lima-based common.sh — no LIMA_CIDATA sourcing (no such thing on GCE), no
# swapoff-then-fstab-strip dance (GCE Ubuntu images ship no swap by default),
# no apt-cacher-ng / Tilt-dev-registry cache options (Mac-host-gateway-specific,
# not meaningful on GCE), no /dev/vdb data-disk mount (the boot disk already
# holds /var/lib/rancher — see variables.tf's boot_disk_size_gb).
set -e

if [ -f /etc/thump-test-common.done ]; then
    echo "[common.sh] Already provisioned, skipping."
    exit 0
fi

echo "══════════════════════════════════════════"
echo "  thump-test provisioning — common baseline"
echo "══════════════════════════════════════════"

echo "[1] Kernel modules for Kubernetes + Rook Ceph"
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
cat > /etc/modules-load.d/rook-ceph.conf <<EOF
rbd
EOF
modprobe overlay
modprobe br_netfilter
# Plain `modprobe rbd` — unlike GKE's UBUNTU_CONTAINERD node image (which
# ships rbd.ko zstd-compressed in a way cephcsi's bundled modprobe can't
# decompress, see rook-gke's rbd-module-loader.tf), stock Ubuntu 24.04 cloud
# images load it fine. No workaround DaemonSet needed here.
modprobe rbd

echo "[2] Sysctl: IP forwarding + bridge netfilter"
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "[3] k3s containerd registry mirrors (cross-mirror docker.io/quay.io so a TLS timeout on one falls through to the other)"
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
      - "https://quay.io"
  registry-1.docker.io:
    endpoint:
      - "https://registry-1.docker.io"
  registry.k8s.io:
    endpoint:
      - "https://registry.k8s.io"
  ghcr.io:
    endpoint:
      - "https://ghcr.io"
  quay.io:
    endpoint:
      - "https://quay.io"
      - "https://registry-1.docker.io"
EOF

echo "[4] Robust APT settings"
apt-get update
cat > /etc/apt/apt.conf.d/99robust <<EOF
Acquire::Retries "10";
Acquire::ForceIPv4 "true";
Acquire::https::Timeout "60";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
EOF

echo "[5] Install base packages"
apt-get install -y \
    apt-transport-https ca-certificates curl gpg \
    lvm2 gdisk sg3-utils udev open-iscsi nfs-common \
    git vim bash-completion wget jq \
    ripgrep bat fd-find tmux fish
systemctl enable --now iscsid

echo "[6] Shell ergonomics — fish, bash, vim, tmux"
# Installed into /etc/skel (and /root/, for sudo sessions) rather than a
# single named user's home: GCE's OS Login provisions a POSIX username
# derived from your Google identity at first login, not a fixed "ubuntu"
# account the way Lima's cidata does — /etc/skel is what any freshly-created
# OS Login home directory inherits.
for TARGET_HOME in /etc/skel /root; do
    mkdir -p "${TARGET_HOME}/.config/fish/conf.d"
    cat > "${TARGET_HOME}/.config/fish/conf.d/thump-test.fish" <<'FISH'
# ── Ceph / Rook diagnostics ──────────────────────────────────────────────────
abbr -a ceph-status    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status'
abbr -a ceph-df        'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph df detail'
abbr -a ceph-osd-tree  'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree'
abbr -a ceph-health    'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail'
abbr -a ceph-auth      'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph auth list'
abbr -a ceph-osd-perf  'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd perf'
abbr -a ceph-log       'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph log last 50'
abbr -a ceph-crush     'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd crush tree'
abbr -a ceph-pools     'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd pool ls detail'
abbr -a ceph-pg-stat   'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat'
abbr -a ceph-s3-test   'kubectl exec -n rook-ceph deploy/rook-ceph-tools -- radosgw-admin bucket list'

# ── Rook / k8s shortcuts ─────────────────────────────────────────────────────
abbr -a rook-status    'kubectl get cephcluster -n rook-ceph'
abbr -a rook-tools     'kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- bash'
abbr -a watch-pods     'watch kubectl get pods -n rook-ceph'
abbr -a kpn            'kubectl get pods -n rook-ceph'
abbr -a kpa            'kubectl get pods -A'

# ── ArgoCD shortcuts ─────────────────────────────────────────────────────────
abbr -a argo-apps      'kubectl get applications -n argocd'
abbr -a argo-sync      'kubectl get applications -n argocd -w'
abbr -a argo-waves     'kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations."argocd.argoproj.io/sync-wave",HEALTH:.status.health.status,SYNC:.status.sync.status'

# ── Hubble flow inspection ────────────────────────────────────────────────────
abbr -a hubble-rook    'hubble observe --namespace rook-ceph'
abbr -a hubble-drops   'hubble observe --verdict DROPPED'
abbr -a hubble-ceph    'hubble observe --namespace rook-ceph --type l7'

# ── Chaos Mesh ────────────────────────────────────────────────────────────────
abbr -a chaos-list     'kubectl get podchaos,networkchaos,iochaos -A'

# ── Lab helpers ───────────────────────────────────────────────────────────────
abbr -a get-pass       'kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'
FISH

    cat >> "${TARGET_HOME}/.bashrc" 2>/dev/null <<'BASH' || true

# ── thump-test convenience aliases ─────────────────────────────────────────
_toolbox() { kubectl exec -n rook-ceph deploy/rook-ceph-tools -- "$@"; }
alias ceph-status='_toolbox ceph status'
alias ceph-df='_toolbox ceph df detail'
alias ceph-osd-tree='_toolbox ceph osd tree'
alias ceph-health='_toolbox ceph health detail'
alias ceph-auth='_toolbox ceph auth list'
alias ceph-osd-perf='_toolbox ceph osd perf'
alias ceph-log='_toolbox ceph log last 50'
alias ceph-crush='_toolbox ceph osd crush tree'
alias ceph-pools='_toolbox ceph osd pool ls detail'
alias ceph-pg-stat='_toolbox ceph pg stat'
alias rook-status='kubectl get cephcluster -n rook-ceph'
alias rook-tools='kubectl exec -it -n rook-ceph deploy/rook-ceph-tools -- bash'
alias watch-pods='watch kubectl get pods -n rook-ceph'
alias kpn='kubectl get pods -n rook-ceph'
alias kpa='kubectl get pods -A'
alias argo-apps='kubectl get applications -n argocd'
alias hubble-rook='hubble observe --namespace rook-ceph'
alias hubble-drops='hubble observe --verdict DROPPED'
alias chaos-list='kubectl get podchaos,networkchaos,iochaos -A'
alias get-pass='kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{.data.password}" | base64 -d; echo'

__ps1_k8s() { kubectl config current-context 2>/dev/null || echo '—'; }
export PROMPT_COMMAND='PS1="\[\e[1;36m\]k8s:\[\e[0m\]$(__ps1_k8s) \w \$ "'
BASH

    cat > "${TARGET_HOME}/.vimrc" <<'VIM'
syntax on
set number relativenumber
set tabstop=2 shiftwidth=2 expandtab
set incsearch hlsearch
set encoding=utf-8
set backspace=indent,eol,start
colorscheme desert
VIM

    cat > "${TARGET_HOME}/.tmux.conf" <<'TMUX'
set -g mouse on
set -g default-terminal "screen-256color"
set -g status-style "bg=colour235,fg=colour136"
set -g status-left  "#[fg=colour166,bold]  thump-test  #[default]"
set -g status-right "#[fg=colour33]%H:%M  %d-%b  #[fg=colour166]#H"
set -g status-right-length 50
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"
TMUX
done

touch /etc/thump-test-common.done
echo "✓ common.sh complete"
