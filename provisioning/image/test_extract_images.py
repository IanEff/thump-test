"""Tests for ManifestScanner in build_golden_image.py."""

import os
import pytest
from build_golden_image import ManifestScanner


def test_extract_images_from_repo():
    """Verify that scanning the repository extracts the core required images."""
    scanner = ManifestScanner(repo_root=os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    tiers = scanner.scan_repo()

    assert "Tier 1: Core Bootstrap" in tiers
    assert "Tier 2: Infrastructure & Observability" in tiers
    assert "Tier 3: Apps & Workloads" in tiers

    all_images = [img for imgs in tiers.values() for img in imgs]
    assert len(all_images) >= 15, f"Expected at least 15 images, found {len(all_images)}: {all_images}"

    # Verify key ecosystem images are present
    assert any("cilium" in img for img in all_images), "Missing Cilium image"
    assert any("argocd" in img or "argo-cd" in img for img in all_images), "Missing ArgoCD image"
    assert any("ceph" in img for img in all_images), "Missing Ceph / Rook image"
    assert any("prometheus" in img for img in all_images), "Missing Prometheus image"
    assert any("grafana" in img for img in all_images), "Missing Grafana image"
    assert any("flagd" in img for img in all_images), "Missing Flagd image"

    # Verify no template garbage leaked in
    for img in all_images:
        assert "{{" not in img and "}}" not in img, f"Unrendered template in image: {img}"
        assert "$" not in img, f"Variable in image: {img}"
        assert "bats/bats" not in img, f"Test framework image leaked: {img}"
        assert not img.endswith(":null"), f"Null tag in image: {img}"


def test_custom_yaml_parsing(tmp_path):
    """Verify that arbitrary k8s and helm YAML patterns are extracted properly."""
    test_yaml = tmp_path / "test-app.yaml"
    test_yaml.write_text(
        """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  template:
    spec:
      containers:
        - name: app
          image: "ghcr.io/my-org/my-app:v1.2.3"
        - name: sidecar
          image: docker.io/bitnami/redis:7.0-debian-11
"""
    )

    scanner = ManifestScanner(repo_root=str(tmp_path))
    tiers = scanner.scan_repo()
    all_images = [img for imgs in tiers.values() for img in imgs]

    assert "ghcr.io/my-org/my-app:v1.2.3" in all_images
    assert "docker.io/bitnami/redis:7.0-debian-11" in all_images
