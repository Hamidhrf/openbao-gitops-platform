# openbao-gitops-platform

Work in progress. The local cluster runs; nothing is deployed on it yet.

Goal: OpenBao in HA mode with an HA PostgreSQL backend, deployed with Flux, and External Secrets Operator syncing secrets between OpenBao and Kubernetes in both directions.

It will run on a local kind cluster with one control-plane node and three workers.

## Versions

| Tool | Version |
|---|---|
| kind | v0.33.0 |
| Kubernetes | v1.36.4 |
| kubectl | v1.36.4 |
| Flux CLI | v2.9.5 |
| sops | v3.13.3 |
| age | v1.3.2 |

## Local tools

    scripts/install-tools.sh
    source scripts/env.sh

`install-tools.sh` downloads the pinned CLIs into `.bin/` and checks their SHA-256 checksums. `env.sh` puts `.bin/` first on `PATH` and sets `KUBECONFIG` to `~/.kube/openbao-local`.

## Local cluster

    kind create cluster --config bootstrap/kind-cluster.yaml --kubeconfig ~/.kube/openbao-local

One control-plane node and three workers, Kubernetes v1.36.4. Only the control-plane node has the `node-role.kubernetes.io/control-plane:NoSchedule` taint, so workloads run on the workers. CoreDNS and the local-path provisioner tolerate the taint and run on the control-plane node. Pod network 10.200.0.0/16, service network 10.210.0.0/16, kind Docker network 172.18.0.0/16.

To remove the cluster:

    kind delete cluster --name openbao-local --kubeconfig ~/.kube/openbao-local

## Docs

- [ADR-001: Local runtime environment](docs/adr/001-runtime-environment.md)
- [ADR-002: Bootstrap secrets](docs/adr/002-bootstrap-secrets.md)
- [ADR-003: Flux bootstrap](docs/adr/003-flux-bootstrap.md)
- [Time log](TIMELOG.md)
