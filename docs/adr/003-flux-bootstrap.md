# ADR-003: Flux bootstrap

Status: accepted (2026-09-21)

## Context

Flux is the deployment engine. The task allows imperative commands only for bootstrapping Flux. Bootstrap needs a credential to push the Flux manifests to the repository once, and the cluster needs a credential to read the repository afterwards. The repository is private on GitHub during development.

## Options

- `flux bootstrap github` with a GitHub personal access token. The CLI creates the deploy key through the GitHub API. The token needs repository administration rights, and a deploy key created with a token stops working when the token expires or is deleted.
- The same with `--token-auth`. The token itself is stored in the cluster and used over HTTPS.
- `flux bootstrap git` over SSH with my SSH agent. The CLI pushes with my own GitHub key through the agent and generates a separate key for the cluster, which I add as a read-only deploy key. No token is needed.
- Flux Operator. Manages the Flux installation through a `FluxInstance` resource and automates upgrades. Useful for fleets, but it adds an operator and the in-cluster Git credential still has to be created by hand.
- `flux install` with hand-written sync resources. Can be made Git-managed by exporting and committing the manifests, but it recreates what bootstrap already does.

## Decision

`flux bootstrap git` over SSH, authenticated through my SSH agent.

- The cluster reads the repository with its own generated SSH key (ECDSA P-384, the default), stored as Secret `flux-system` in the `flux-system` namespace. Its public key is a read-only deploy key on this repository only.
- My personal GitHub key is used by the CLI during bootstrap only and never leaves the VM. I do not use `--private-key-file`, because that stores the given key in the cluster.
- Default components (source, kustomize, helm and notification controllers) and default NetworkPolicies. No image automation, so Flux never needs write access to Git.
- No `--version` flag. The pinned Flux CLI 2.9.5 installs the controllers of the 2.9.5 release. Upgrading means pinning a newer CLI and running bootstrap again.
- Bootstrap commits keep the default author `Flux`, so generated commits are distinguishable from hand-written ones.
- The generated files under `clusters/local/flux-system/` are not edited. SOPS decryption is configured on the child Kustomizations, which live in `flux-system` next to the `sops-age` Secret.

## Limitations

- Adding the deploy key is a manual step in the GitHub UI. A rebuilt cluster gets a new key; the old deploy key is deleted once the new cluster reconciles.
- The deploy key's private key is a long-lived credential stored in the cluster, and Secrets are not encrypted at rest in this kind cluster.
- In an organisation I would use a GitHub App (Flux's `github` provider for `GitRepository`) or a dedicated machine user, so access is managed centrally and Git access uses short-lived tokens.

## References

- https://fluxcd.io/flux/installation/bootstrap/github/
- https://fluxcd.io/flux/installation/bootstrap/generic-git-server/
- https://fluxcd.io/flux/cmd/flux_bootstrap_git/