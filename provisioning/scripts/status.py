#!/usr/bin/env python3
"""Inspect thump-test cluster status from GCP and shared GCS backend."""

import os
import subprocess
import sys


def main() -> None:
    project_id = os.environ.get("PROJECT_ID", "terraform-sandbox-430820")
    cluster_name = os.environ.get("CLUSTER_NAME", "thump-test")

    print("════════════════════════════════════════════════════════════════")
    print(f"  thump-test — Shared Cluster Status")
    print(f"  Project: {project_id} | Cluster: {cluster_name}")
    print("════════════════════════════════════════════════════════════════\n")

    cmd = [
        "gcloud", "compute", "instances", "list",
        f"--project={project_id}",
        f"--filter=name~'^{cluster_name}-'",
        "--format=table(name,zone,status,networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    out = res.stdout.strip()
    if out and len(out.splitlines()) > 1:
        print(out)
        print("\nCluster is RUNNING in GCP. If you want to use it:")
        print("  1. task credentials")
        print("  2. task tunnel &")
        print(f"  3. kubectl --context={cluster_name} get nodes")
    else:
        print(f"No running instances found for '{cluster_name}' in project {project_id}.")
        print("To bring up the rig: task up")


if __name__ == "__main__":
    main()
