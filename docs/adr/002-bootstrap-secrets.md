# ADR-002: Bootstrap secrets

Status: accepted (2026-09-20)

## Context

A few secrets have to exist before OpenBao can be used. The task requires that they are not stored in OpenBao, to avoid a circular dependency, and that they are managed with GitOps or SOPS.

This ADR decides how the repository stores those secrets. It does not list them. Which credentials exist depends on the PostgreSQL, backup, TLS and OpenBao decisions that follow. The first one is likely a backup-storage credential, if the chosen backup target needs a static one.

## Options

- SOPS with age, decrypted by the Flux kustomize-controller. Flux decrypts SOPS-encrypted Secrets on its own, so no extra controller is needed. age keys are short and need no keyring.
- SOPS with PGP. The same Flux mechanism with a different key type. It needs gpg-agent, a keyring, subkeys and expiry dates. The Flux guide recommends age over OpenPGP.
- Sealed Secrets. The controller generates its own sealing key, so nothing has to be installed by hand at the start. It adds a controller and a custom resource for something Flux already does, and recovery after cluster loss depends on restoring the backed-up sealing key.
- SOPS with OpenBao Transit. Flux 2.9 can authenticate to OpenBao with a Kubernetes service account and decrypt through the Transit engine, without a static token. This is not usable for bootstrap secrets, because the secrets needed to bring up or recover the platform would then depend on OpenBao already running. It stays an option for secrets that are only needed once OpenBao is healthy.

## Decision

SOPS with age, decrypted by the Flux kustomize-controller.

- Only `data` and `stringData` are encrypted, so keys and structure stay readable in a diff.
- Standard age recipients, not post-quantum ones. Flux 2.9 supports the post-quantum cipher, but this project has no such requirement and standard recipients are shorter and easier to read.
- Two recipients. The working identity is installed in the cluster as a Secret in `flux-system`. The break-glass identity is stored in my password manager, outside the VM, and is never installed in the cluster, so the encrypted files can still be opened if the working key is lost.
- Encrypted files are named `*.sops.yaml`. The rules are in `.sops.yaml` at the repository root.
- Secrets used on the VM outside Kubernetes are dotenv files named `*.sops.env`, with all values encrypted for the same two recipients (added 2026-09-22). `sops exec-env` passes them to a command as environment variables, so no plaintext file is written. The first is the backup-store credential (ADR-005).
- The working private key is at `~/.config/sops/age/keys.txt` on the VM, mode 600. No private key is in the repository.
- The Secret holding the working key is created once, during Flux bootstrap:

      kubectl create secret generic sops-age \
        --namespace flux-system \
        --from-file=age.agekey=$HOME/.config/sops/age/keys.txt \
        --dry-run=client -o yaml | kubectl apply -f -

  The key name has to end in `.agekey` for the controller to detect it as an age key. Generating the manifest client-side and piping it into `apply` makes the step repeatable when the cluster is rebuilt.

## Limitations

- Installing the working key is a manual step. It cannot be declarative, because Flux needs the key before it can decrypt anything from Git. In production I would use SOPS backed by a cloud KMS or an HSM with workload identity, which removes the long-lived private key from the cluster.
- Git keeps old ciphertext. Rotating the age key does not protect values that are already in the history, so a rotation means treating the old values as leaked.
- age has no expiry or key versioning. A KMS provides both.
- Both private keys are held by one person. This is a single-person demo, not a key ceremony.

## References

- https://fluxcd.io/flux/guides/mozilla-sops/
- https://fluxcd.io/flux/security/secrets-management/
- https://fluxcd.io/blog/2026/06/flux-v2.9.0/