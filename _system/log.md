# Workspace Log

## 2026-08-05 - Go GCP SDK Consultation
- Evaluated Go Cloud Client Libraries (`cloud.google.com/go/compute/apiv1`) vs `provisioning/scripts/ripcord.sh` for infrastructure standup and teardown.
- Created detailed architectural writeup and Go reference implementation in `~/Documents/vault/Projects/thump-test.md`.

## 2026-08-14 - Accelerate Prometheus and GitOps Convergence
- Root-cause analyzed cold-boot GitOps convergence latency for Prometheus and core infrastructure.
- Identified primary delay vectors:
  1. Missing Prometheus Operator CRD pre-bootstrap in `provisioning/scripts/install_argocd.sh`, causing initial sync failures for `prometheus`, `sloth`, and `ceph-latency-bridge`.
  2. Aggressive exponential retry backoff (`duration: 10s`, `factor: 2`, `maxDuration: 3m`) causing multi-minute idle stalls when transient CRD registration races occurred.
  3. Unvendored Helm charts requiring runtime network fetches by `argocd-repo-server`.
- Remediated by:
  - Vendoring all missing chart caches (`prometheus-operator-crds`, `grafana`, `loki`, `promtail`, `chaos-mesh`, `kyverno`).
  - Adding Prometheus Operator CRD pre-bootstrap step (`[4b]`) to `install_argocd.sh`.
  - Tuning Application retry backoff to `duration: 5s`, `factor: 2`, `maxDuration: 1m` across `infra-set.yaml`, `rook-set.yaml`, `apps-set.yaml`, `rook-cluster.yaml`, and `s3-traffic-generator.yaml`.
  - Adding `reposerver.parallelism.limit: "20"` to `argocd-cmd-params-cm` in `cluster-bootstrap/argocd/kustomization.yaml`.


