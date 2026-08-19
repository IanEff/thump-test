#!/usr/bin/env python3
"""Quiet, multiplexed Google Cloud IAP Tunnel manager for thump-test."""

import argparse
import atexit
import os
import signal
import subprocess
import sys
import time
from typing import Dict, List


def get_tofu_output(name: str) -> str:
    res = subprocess.run(["tofu", "output", "-raw", name], capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else ""


class TunnelManager:
    def __init__(self, cluster: str, zone: str, project: str) -> None:
        self.cluster = cluster
        self.zone = zone
        self.project = project
        self.instance = f"{cluster}-control-plane"
        self.active_tunnels: Dict[str, subprocess.Popen] = {}
        self.cleaned_up = False

        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
        if hasattr(signal, "SIGHUP"):
            signal.signal(signal.SIGHUP, self._signal_handler)
        atexit.register(self.cleanup)

    def _signal_handler(self, signum, frame):
        self.cleanup()
        sys.exit(0)

    def cleanup(self) -> None:
        if self.cleaned_up:
            return
        self.cleaned_up = True
        if not self.active_tunnels:
            return

        for port, proc in list(self.active_tunnels.items()):
            if proc.poll() is None:
                proc.terminate()
        for port, proc in list(self.active_tunnels.items()):
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        self.active_tunnels.clear()
        print("\n✓ All IAP tunnels stopped.")

    def start(self, ports: List[str]) -> None:
        print(f"⚡ thump-test IAP Tunnels -> {self.instance} ({self.zone})")

        has_root = os.geteuid() == 0
        active_ports = []

        for port in ports:
            if int(port) < 1024 and not has_root:
                print(f"  [!] Port {port} skipped (requires root): run 'sudo task tunnel' for full HTTPS web UI & thump integration access.")
                continue

            cmd = [
                "gcloud", "compute", "start-iap-tunnel",
                self.instance, port,
                f"--local-host-port=localhost:{port}",
                f"--zone={self.zone}",
                f"--project={self.project}",
            ]
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.active_tunnels[port] = proc
            active_ports.append(port)

        if not active_ports:
            print("No tunnels to run.", file=sys.stderr)
            sys.exit(1)

        print("  Active endpoints:")
        if "6443" in active_ports:
            print("    • k3s API:        https://127.0.0.1:6443 (kubectl context thump-test)")
        if "443" in active_ports:
            print("    • Web UIs:        https://*.thump-test.lab (ArgoCD, Grafana, Hubble, OTel Demo)")
        if "4222" in active_ports:
            print("    • NATS JetStream: nats://127.0.0.1:4222 (calipers, operator CLI)")

        self.monitor()

    def monitor(self) -> None:
        while self.active_tunnels:
            for port in list(self.active_tunnels.keys()):
                proc = self.active_tunnels[port]
                ret = proc.poll()
                if ret is not None:
                    _, err = proc.communicate()
                    del self.active_tunnels[port]
                    filtered_err = "\n".join(
                        l for l in (err or "").splitlines()
                        if "Testing if tunnel connection works" not in l
                    ).strip()
                    if ret != 0 and filtered_err:
                        print(f"  [!] Port {port} tunnel closed: {filtered_err}", file=sys.stderr)

            if not self.active_tunnels:
                break
            time.sleep(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ports", default="6443,443,4222", help="Comma-separated remote ports to tunnel")
    parser.add_argument("--cluster", default=os.environ.get("CLUSTER_NAME", "thump-test"))
    parser.add_argument("--zone", default=os.environ.get("ZONE") or get_tofu_output("zone") or "us-east1-b")
    parser.add_argument("--project", default=os.environ.get("PROJECT_ID") or "terraform-sandbox-430820")
    args = parser.parse_args()

    port_list = [p.strip() for p in args.ports.split(",") if p.strip()]
    mgr = TunnelManager(cluster=args.cluster, zone=args.zone, project=args.project)
    mgr.start(port_list)


if __name__ == "__main__":
    main()
