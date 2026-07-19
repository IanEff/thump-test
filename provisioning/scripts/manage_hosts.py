#!/usr/bin/env python3
"""Manage /etc/hosts entries for the thump-test cluster's fixed hostnames.

Replaces ceph-lab's dnsmasq_setup.sh/dnsmasq_teardown.sh: ceph-lab needed real
wildcard (*.ceph.lab) resolution because Cilium's L2Announcement gave it a
genuinely floating LB IP on a Lima host-only network. Here there's one stable
external IP (the control-plane's static address) and a small, fixed list of
hostnames, so a handful of plain /etc/hosts lines is simpler and needs no
dnsmasq/resolver/LaunchAgent setup on the Mac at all.

Usage:
    sudo python3 manage_hosts.py add   <control-plane-external-ip>
    sudo python3 manage_hosts.py remove
"""

import argparse
import sys
from pathlib import Path

HOSTS_FILE = Path("/etc/hosts")
DOMAIN = "thump-test.lab"
HOSTNAMES = [
    f"argocd.{DOMAIN}",
    f"grafana.{DOMAIN}",
    f"dashboard.{DOMAIN}",
    f"hubble.{DOMAIN}",
    f"prometheus.{DOMAIN}",
    f"otel-demo.{DOMAIN}",
]

BEGIN_MARKER = "# BEGIN thump-test"
END_MARKER = "# END thump-test"


def _strip_managed_block(lines: list[str]) -> list[str]:
    out = []
    skipping = False
    for line in lines:
        if line.strip() == BEGIN_MARKER:
            skipping = True
            continue
        if line.strip() == END_MARKER:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    return out


def add(ip: str) -> None:
    if not HOSTS_FILE.exists():
        print(f"{HOSTS_FILE} not found — unexpected on macOS/Linux.", file=sys.stderr)
        sys.exit(1)

    lines = HOSTS_FILE.read_text(encoding="utf-8").splitlines()
    lines = _strip_managed_block(lines)

    block = [BEGIN_MARKER]
    for hostname in HOSTNAMES:
        block.append(f"{ip}\t{hostname}")
    block.append(END_MARKER)

    content = "\n".join(lines).rstrip("\n") + "\n" + "\n".join(block) + "\n"
    HOSTS_FILE.write_text(content, encoding="utf-8")
    print(f"Wrote {len(HOSTNAMES)} hostnames -> {ip} in {HOSTS_FILE}:")
    for hostname in HOSTNAMES:
        print(f"  {hostname}")


def remove() -> None:
    if not HOSTS_FILE.exists():
        print(f"{HOSTS_FILE} not found.", file=sys.stderr)
        return

    lines = HOSTS_FILE.read_text(encoding="utf-8").splitlines()
    new_lines = _strip_managed_block(lines)

    if len(new_lines) == len(lines):
        print("No thump-test block found in /etc/hosts.")
        return

    content = "\n".join(new_lines).rstrip("\n") + "\n"
    HOSTS_FILE.write_text(content, encoding="utf-8")
    print("Removed thump-test block from /etc/hosts.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["add", "remove"])
    parser.add_argument("ip", nargs="?", help="Control-plane external IP (required for 'add')")
    args = parser.parse_args()

    if args.action == "add":
        if not args.ip:
            parser.error("'add' requires the control-plane external IP (see: tofu output control_plane_external_ip)")
        add(args.ip)
    else:
        remove()


if __name__ == "__main__":
    main()
