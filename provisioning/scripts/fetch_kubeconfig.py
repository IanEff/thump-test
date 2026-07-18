#!/usr/bin/env python3
"""Fetch and merge kubeconfig for the thump-test cluster.

Ported from ceph-lab's manage_k8s_config.py: the transport becomes
`gcloud compute ssh ... --command` (OS Login, tunneled through IAP — port 22
is IAP-only, see network.tf) instead of `limactl shell`, and the fetched
kubeconfig's server URL is rewritten from the control-plane's INTERNAL
static IP (what control-plane.sh's own kubeconfig already uses internally)
to 127.0.0.1, since the k3s API (port 6443) is also IAP-only now — reaching
it requires `just tunnel` running locally (gcloud compute start-iap-tunnel
... 6443 --local-host-port=localhost:6443). No TLS-verify skip is needed for
this rewrite — k3s's tls-san list (control-plane.sh) includes 127.0.0.1
specifically so the existing CA validates through the tunnel.

Usage:
    python3 fetch_kubeconfig.py add    (requires: tofu output values below)
    python3 fetch_kubeconfig.py remove
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KUBE_CONFIG_PATH = Path.home() / ".kube" / "config"

NEW_CONTEXT_NAME = "thump-test"
NEW_USER_NAME = "thump-test-admin"
NEW_CLUSTER_NAME = "thump-test-cluster"

# control-plane.sh runs k3s + Cilium install after boot; SSH (and even OS
# Login key propagation) can be reachable well before /root/.kube/config
# exists. `just up` chains `apply` straight into `credentials` with no wait
# of its own, so this script retries instead of failing on the first race.
KUBECONFIG_WAIT_TIMEOUT_S = 600
KUBECONFIG_WAIT_INTERVAL_S = 10


def tofu_output(name: str) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", name],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"tofu output -raw {name} failed: {result.stderr.strip()}", file=sys.stderr)
        print("Run this from the repo root after `tofu apply`.", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def backup_file(path: Path) -> None:
    if path.exists():
        backup_path = path.with_suffix(f".bak.{int(time.time())}")
        shutil.copy2(path, backup_path)
        print(f"Backed up {path.name} to {backup_path.name}")


def add() -> None:
    project_id = os.environ.get("PROJECT_ID") or tofu_output_or_default()
    # No hardcoded fallback here on purpose: a stale default silently targets
    # the wrong zone once terraform.tfvars moves (as happened 2026-07-17 --
    # the rig moved to us-east1-b but a hand-typed `ZONE=us-central1-a` from
    # an old session/note kept "working" by retrying for 600s against a
    # nonexistent instance before finally failing). Tofu's own output is the
    # only source of truth that can't drift out from under a manual invocation.
    zone = os.environ.get("ZONE") or tofu_output("zone")
    cluster_name = os.environ.get("CLUSTER_NAME", "thump-test")
    internal_ip = tofu_output("control_plane_internal_ip")

    instance = f"{cluster_name}-control-plane"
    cmd = [
        "gcloud", "compute", "ssh", instance,
        f"--zone={zone}", f"--project={project_id}", "--tunnel-through-iap",
        "--command=sudo cat /root/.kube/config",
    ]

    print(f"Fetching kubeconfig from {instance} via gcloud compute ssh (IAP)...")
    print(f"  (retrying up to {KUBECONFIG_WAIT_TIMEOUT_S}s — control-plane.sh installs k3s/Helm/Cilium after boot, "
          "so the file may not exist yet even once SSH is reachable)")
    deadline = time.time() + KUBECONFIG_WAIT_TIMEOUT_S
    attempt = 0
    while True:
        attempt += 1
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            break
        if time.time() >= deadline:
            print(f"Failed to fetch kubeconfig after {KUBECONFIG_WAIT_TIMEOUT_S}s "
                  f"({attempt} attempts): {result.stderr.strip()}", file=sys.stderr)
            sys.exit(1)
        print(f"  attempt {attempt}: not ready yet, retrying in {KUBECONFIG_WAIT_INTERVAL_S}s...")
        time.sleep(KUBECONFIG_WAIT_INTERVAL_S)

    tmpdir = Path(tempfile.mkdtemp(prefix="rook_gce_k3s_"))
    temp_conf = tmpdir / "k3s.yaml"
    merged_conf = tmpdir / "kubeconfig.merged"
    try:
        content = result.stdout
        # Rewrite server URL: internal IP (what control-plane.sh set) ->
        # 127.0.0.1 (what `just tunnel`'s IAP tunnel exposes locally).
        # tls-san includes 127.0.0.1, so no insecure-skip-tls-verify is needed.
        content = content.replace(internal_ip, "127.0.0.1")
        content = content.replace("current-context: default", f"current-context: {NEW_CONTEXT_NAME}")
        import re
        content = re.sub(r"\bcluster: default\b", f"cluster: {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"\buser: default\b", f"user: {NEW_USER_NAME}", content)
        content = re.sub(r"(- context:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CONTEXT_NAME}", content)
        content = re.sub(r"(- cluster:(?:.|\n)*?name:)\s+default", rf"\1 {NEW_CLUSTER_NAME}", content)
        content = re.sub(r"(?m)^- name:\s+default$", f"- name: {NEW_USER_NAME}", content)
        temp_conf.write_text(content, encoding="utf-8")

        print("Merging kubeconfig...")
        env = os.environ.copy()
        env["KUBECONFIG"] = f"{temp_conf}:{KUBE_CONFIG_PATH}" if KUBE_CONFIG_PATH.exists() else str(temp_conf)
        with open(merged_conf, "w") as f:
            merge = subprocess.run(["kubectl", "config", "view", "--flatten"], env=env, stdout=f)
        if merge.returncode != 0:
            print("Failed to merge kubeconfig.", file=sys.stderr)
            sys.exit(1)

        backup_file(KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(merged_conf), KUBE_CONFIG_PATH)
        KUBE_CONFIG_PATH.chmod(0o600)
        print(f"Kubeconfig updated. Context '{NEW_CONTEXT_NAME}' is now current.")
        print("  Server: https://127.0.0.1:6443 (requires `just tunnel` running)")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def tofu_output_or_default() -> str:
    # project_id isn't a Tofu output today; fall back to gcloud's configured
    # default project rather than adding an output just for this.
    result = subprocess.run(["gcloud", "config", "get-value", "project"], capture_output=True, text=True)
    return result.stdout.strip()


def remove() -> None:
    print("Removing thump-test Kubernetes configuration...")
    cmds = [
        ["kubectl", "config", "delete-context", NEW_CONTEXT_NAME],
        ["kubectl", "config", "delete-cluster", NEW_CLUSTER_NAME],
        ["kubectl", "config", "delete-user", NEW_USER_NAME],
    ]
    for cmd in cmds:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("Kubeconfig cleaned up (best effort).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["add", "remove"])
    args = parser.parse_args()
    add() if args.action == "add" else remove()


if __name__ == "__main__":
    main()
