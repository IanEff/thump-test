#!/usr/bin/env python3
"""Time how long each ArgoCD Application takes to reach Healthy on a cold boot.

`task up` gets GCE VMs running in ~180s, but the ArgoCD-driven GitOps tree
(Rook-Ceph, Prometheus, Loki, ...) takes much longer to go fully Healthy, and
until now that number was a stopwatch guess. This polls `kubectl get
application -n argocd` on a fixed interval, logs every (sync, health)
transition it observes with elapsed time since this script started, and
writes the full timeline to a CSV for later comparison across boots.

Usage: run in its own terminal, alongside `task tunnel`, ideally started
right when `task up` is kicked off so the timeline covers the full
VM-boot -> API-reachable -> every-app-Healthy window, not just the
ArgoCD-visible portion:

    task tunnel &
    task up &
    task boot-timeline

No GitHub webhook is configured against this cluster's ArgoCD, so polling is
the only external option; Application *status* (sync/health) still updates
promptly from the controller's own in-cluster watch, independent of the
180s git-polling resync interval, so this doesn't inherit that delay.

`cilium` is excluded from the "all healthy" completion condition: per
CLAUDE.md gotcha #15, its Gateway never reports `Programmed=True` in
hostNetwork mode (no floating LB IP to populate `status.addresses`), so
ArgoCD's health check for that Application legitimately never returns
Healthy. Waiting on it would hang the timeline forever on a resource that's
actually fine.
"""

import argparse
import csv
import datetime
import json
import os
import subprocess
import sys
import time

DEFAULT_POLL_INTERVAL_S = 5
DEFAULT_TIMEOUT_S = 30 * 60

# See CLAUDE.md gotcha #15 -- known to sit Progressing forever by design.
KNOWN_PERMANENTLY_PROGRESSING = {"cilium"}


def get_applications(context: str) -> list | None:
    cmd = ["kubectl"]
    if context:
        cmd += ["--context", context]
    cmd += ["-n", "argocd", "get", "application", "-o", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)["items"]
    except (json.JSONDecodeError, KeyError):
        return None


def sync_wave(app: dict) -> str:
    return app["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave", "0")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--context", default=None, help="kubectl context (default: whatever is current)")
    parser.add_argument("--interval", type=float, default=DEFAULT_POLL_INTERVAL_S, help="poll interval, seconds")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="give up after this long, seconds")
    parser.add_argument("--out", default=None, help="CSV output path (default: boot-timelines/<timestamp>.csv)")
    args = parser.parse_args()

    out_path = args.out or f"boot-timelines/{datetime.datetime.now():%Y%m%dT%H%M%S}.csv"
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    start = time.monotonic()
    last_state: dict[str, tuple] = {}
    first_healthy: dict[str, float] = {}
    api_reachable_at = None

    print(f"Polling every {args.interval}s (timeout {args.timeout:.0f}s), writing {out_path}")
    print("Waiting for the ArgoCD API to become reachable...")

    with open(out_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["elapsed_seconds", "wall_clock", "event", "app", "sync_wave", "sync_status", "health_status"])

        def log(event: str, app: str = "", wave: str = "", sync: str = "", health: str = "") -> float:
            elapsed = time.monotonic() - start
            writer.writerow([f"{elapsed:.1f}", datetime.datetime.now().isoformat(timespec="seconds"),
                              event, app, wave, sync, health])
            f.flush()
            return elapsed

        while True:
            elapsed = time.monotonic() - start
            if elapsed > args.timeout:
                pending = [n for n in last_state if n not in first_healthy]
                log("timeout")
                print(f"\nTIMEOUT after {elapsed:.0f}s -- {len(first_healthy)}/{len(last_state)} apps Healthy "
                      f"(still pending: {', '.join(sorted(pending)) or 'none'})")
                break

            apps = get_applications(args.context)
            if apps is None:
                time.sleep(args.interval)
                continue
            if api_reachable_at is None:
                api_reachable_at = log("api_reachable")
                print(f"{api_reachable_at:8.1f}s  ArgoCD API reachable ({len(apps)} applications registered)")

            for app in apps:
                name = app["metadata"]["name"]
                wave = sync_wave(app)
                sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
                health = app.get("status", {}).get("health", {}).get("status", "Unknown")
                state = (sync, health)
                if last_state.get(name) != state:
                    e = log("transition", name, wave, sync, health)
                    print(f"{e:8.1f}s  {name:<28} wave {wave:>4}  {sync} -> {health}")
                    last_state[name] = state
                if health == "Healthy" and name not in first_healthy:
                    first_healthy[name] = elapsed

            pending = [n for n in last_state if n not in first_healthy and n not in KNOWN_PERMANENTLY_PROGRESSING]
            if last_state and not pending:
                log("all_healthy")
                excluded = ", ".join(sorted(KNOWN_PERMANENTLY_PROGRESSING & set(last_state))) or "none"
                print(f"\nAll apps Healthy at {elapsed:.0f}s (excluding known-permanent: {excluded})")
                break

            time.sleep(args.interval)

    print("\n--- summary (first-Healthy time, ascending) ---")
    for name, t in sorted(first_healthy.items(), key=lambda kv: kv[1]):
        print(f"{t:8.1f}s  {name}")
    still_pending = set(last_state) - set(first_healthy) - KNOWN_PERMANENTLY_PROGRESSING
    if still_pending:
        print("\nnever reached Healthy:", ", ".join(sorted(still_pending)))
    print(f"\nfull timeline: {out_path}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(1)
