# ADR-007: TLS and the certificate authority

Status: accepted (2026-09-23). Amends the TLS line of ADR-004.

## Context

OpenBao runs in the `openbao` namespace and keeps its data in the PostgreSQL cluster in the `database` namespace. It connects with `sslmode=verify-full`, so it needs the certificate authority that signed the PostgreSQL server certificate, and the server certificate has to carry the name it connects to.

ADR-004 left the certificates to CloudNativePG. The operator generates one CA per cluster and signs the server, client and replication certificates with it. Measured on the running cluster on 23 September 2026: the CA and all three leaf certificates are valid from 23 September to 22 December 2026, and the server certificate already carries twelve names, including `openbao-db-rw.database.svc`. Name matching is not the problem.

Getting the CA into the `openbao` namespace is the problem. The operator's CA lives in `database`, and ADR-006 keeps that namespace away from OpenBao on purpose, because it holds `ca.key`, the database password and the backup store root credential.

OpenBao also needs a certificate for its own listener.

## Options

Keep the operator CA and commit its public `ca.crt` as a Secret in `openbao`, the same pattern already used for the backup store's `endpointCA`. Nothing in the database layer changes. The copy is a snapshot of something the operator owns: it stops matching when the CA is renewed, which is due seven days before 22 December 2026, and again whenever the cluster is rebuilt, because a new cluster generates a new CA. Each of those needs a manual extract and a commit before OpenBao can reach its storage.

Install trust-manager and let it distribute the operator CA. A Bundle reads its sources only from trust-manager's own trust namespace, which defaults to `cert-manager`. Pointing that namespace at `database` would work, but it gives a controller that writes into every namespace read access to the namespace ADR-006 isolated. Possible, but it adds a controller and weakens a boundary in order to move one public certificate.

Commit a fixed CA key pair with SOPS and hand it to CloudNativePG. It survives rebuilds, but it puts a signing key into the bootstrap secrets to solve a distribution problem.

Issue the PostgreSQL server certificate from a cert-manager CA. CloudNativePG supports user-provided server certificates through `serverTLSSecret` and `serverCASecret` and keeps managing the client and replication certificates with its own CA. Every certificate cert-manager issues carries `ca.crt` in its Secret, so the `openbao` namespace gets the CA from its own listener certificate. Nothing is copied and nothing is committed.

For the OpenBao listener the alternative to cert-manager is a certificate made by hand and stored with SOPS, which would have to be re-issued by hand when the exposure name is added and at every renewal.

## Decision

One private CA for the platform, managed by cert-manager, which is already installed.

A self-signed ClusterIssuer issues the root certificate `platform-ca` into the `cert-manager` namespace, and a CA ClusterIssuer signs with it. cert-manager runs with `--cluster-resource-namespace=$(POD_NAMESPACE)`, so the ClusterIssuer reads that Secret from `cert-manager` and the signing key never leaves it.

The root is RSA 4096, valid for five years, with automatic renewal turned off (`renewal.policy: Disabled`), because replacing a trust anchor needs a planned rollover and not a surprise. Leaf certificates are RSA 2048, valid for 90 days, renewed when a third of their lifetime is left, with a new private key on every renewal.

The PostgreSQL server certificate is a Certificate in the `database` namespace with `CN=openbao-db-rw` and the same twelve names the operator generated. The Cluster references its Secret as both `serverTLSSecret` and `serverCASecret`; `ca.key` is not needed there because the server certificate is supplied. The Secret carries the label `cnpg.io/reload: ""` through `secretTemplate`, so the instances pick up a renewed certificate without `kubectl cnpg reload`. CloudNativePG keeps its own CA for the client and replication certificates.

The OpenBao listener certificate is a Certificate in the `openbao` namespace from the same CA. OpenBao mounts that one Secret and uses `tls.crt` and `tls.key` for the listener, and `ca.crt` as `sslrootcert` for the storage connection and as `BAO_CACERT`.

The ClusterIssuers and the root certificate live in `infrastructure/configs/`. That gives the directory its first content and its Flux Kustomization, so the chain is `infra-controllers`, `infra-configs`, `database`, `openbao`.

## Limitations

The database has two trust domains now: the server certificate comes from the platform CA, the client and replication certificates from CloudNativePG's own CA.

Using `ca.crt` out of OpenBao's own listener Secret as the trust store for PostgreSQL is a simplification. cert-manager advises against treating a leaf Secret's `ca.crt` as a trust store, because a trust anchor changes on its own schedule and a safe rollover needs the old and the new root trusted at the same time. It holds here because one CA is defined in this repository, no rollover happens during this project, and a rebuild replaces the root and both leaf certificates together. A production platform would distribute a trust bundle deliberately, with trust-manager or an external PKI.

The same CA signs the database server certificate and the OpenBao listener certificate. In production these would be separate intermediates.

Renewal is configured but not exercised here. On the PostgreSQL side the `cnpg.io/reload` label is what makes a renewed certificate take effect. OpenBao reloads `tls_cert_file` and `tls_key_file` on SIGHUP, using the paths set at startup, which matters because a restart would leave its pods sealed.

cert-manager is now a dependency of the database layer. Without it the server certificate is not issued and a rebuilt cluster does not start.

## References

- https://cloudnative-pg.io/docs/1.30/certificates/
- https://cert-manager.io/docs/configuration/ca/
- https://cert-manager.io/docs/usage/certificate/
- https://cert-manager.io/docs/trust/
- https://openbao.org/docs/configuration/listener/tcp/
- https://openbao.org/docs/configuration/storage/postgresql/
