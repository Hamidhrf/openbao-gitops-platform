# openbao-gitops-platform

Work in progress. Nothing is deployed yet.

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

## Docs

- [ADR-001: Local runtime environment](docs/adr/001-runtime-environment.md)
- [ADR-002: Bootstrap secrets](docs/adr/002-bootstrap-secrets.md)
- [Time log](TIMELOG.md)
