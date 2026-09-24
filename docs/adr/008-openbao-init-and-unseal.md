# ADR-008: OpenBao initialization, unseal and administrative access

Status: accepted (2026-09-23)

## Context

OpenBao encrypts everything it stores with a root key, and that root key is itself encrypted by a seal. Without the seal material the contents of the PostgreSQL backend, and of every backup taken from it, cannot be read. So the seal decides three things at once: how the platform starts, how it recovers, and what a backup is worth to someone who steals it.

The default seal is Shamir, which splits an unseal key into shares and requires an operator to present enough of them to every node after every start. Three replicas run here, and pods restart for ordinary reasons: a node failure, a rolling update, a database password rotation, a rebuild from Git.

The ESO spike on 21 September 2026 showed what a sealed OpenBao does to the rest of the platform. Logins return 503, existing Secrets keep their last value, ExternalSecrets fail on their next refresh, and syncing resumed about five minutes after unsealing without a manual nudge.

The challenge requires that bootstrap secrets are not stored in OpenBao, to avoid a circular dependency, and are managed with GitOps or SOPS instead. ADR-002 already established SOPS with age for exactly that.

## Options

Shamir with manual unsealing. The seal material never enters Git or the cluster, so a stolen backup is worthless without the shares. Every restart of every pod needs a human, initialization produces a root token that has to be stored or destroyed, and a restore is only useful to whoever holds the shares.

Static seal with the key managed by SOPS. OpenBao 2.6 has a built-in static seal that takes a 32-byte AES-256 key directly, from an environment variable, or from a file. The key is generated once and committed encrypted with age, Flux decrypts it into a Secret, and each pod unseals itself at start. Its documentation recommends this when a trusted secret source already exists and OpenBao is being chained to it, which is the position ADR-002 puts us in.

Auto-unseal from a cloud KMS. The key never leaves the KMS. There is no cloud account behind this deployment.

PKCS#11 with a software HSM on the same VM. The PIN becomes a bootstrap secret in Git anyway, so it moves the secret rather than removing it, and it adds a plugin to install and explain.

Transit auto-unseal from a second OpenBao. The second instance needs its own seal, so the problem moves rather than disappears. ADR-002 rejected Vault Transit for SOPS on the same grounds.

## Decision

The static seal, with a 32-byte key generated once, committed only in SOPS-encrypted form, mounted into the pods as a file and referenced with `file://`. The key carries an identifier, so a later rotation can name the old and the new key through `previous_key` and `current_key`.

Because auto-unseal is in place, OpenBao self-initializes. The `initialize` stanza in the configuration file runs its requests once on first start. No recovery keys are generated, and the root token is not returned to the caller and is revoked after use, so neither exists to be stored or leaked.

The stanza carries only what has to exist before anything else can work: an audit device, the Kubernetes auth method, an explicit `admin` policy, an admin role bound to one ServiceAccount, and a break-glass `userpass` account with the same policy and a SOPS-managed password. Everything else, including the KV mount, the ESO roles and the workload policies, is configuration that has to converge more than once and is decided separately.

Administration is a login, not a stored token. The normal path is a short-lived token for a dedicated ServiceAccount in the `openbao` namespace that no application runs as, with the auth role bound to its name, namespace and audience. The break-glass account exists for the case where a bad policy change breaks the Kubernetes path, is never used for routine work, and keeps a short token lifetime. Neither identity uses the built-in `root` policy.

The chart's default pod management policy is kept rather than starting the three pods together, so the first start is serialised.

## Limitations

An attacker who obtains an age identity that can decrypt the seal Secret, together with a PostgreSQL backup, has the material needed to recover and unseal that data. With Shamir they would not. This is the price of automatic unsealing, and it is why production would use a cloud KMS with workload identity or a PKCS#11 HSM, where the key cannot be reconstructed from the repository.

The seal key is mounted into every OpenBao pod, so anyone who can read that Secret, or schedule a pod in the `openbao` namespace, can obtain it. This is part of why ADR-006 keeps the database's private material in a different namespace: no single namespace holds both.

Disaster recovery therefore has two inputs, not one. A PostgreSQL backup on its own cannot be read. The matching seal key has to survive with it, and a point-in-time restore needs the key that was current at that point.

The break-glass password is a second bootstrap secret under the same age key, so compromising that key exposes both it and the seal key. In production this human path would be an identity provider rather than a local account.

The `initialize` stanza runs once and never again, so it cannot be used for day-2 configuration.

Seal key rotation is supported through `previous_key` and `current_key` but is not exercised here.

## References

- https://openbao.org/docs/configuration/seal/
- https://openbao.org/docs/configuration/seal/static/
- https://openbao.org/docs/configuration/self-init/
- https://openbao.org/docs/concepts/seal/
- https://openbao.org/docs/concepts/policies/
- https://openbao.org/docs/auth/kubernetes/
