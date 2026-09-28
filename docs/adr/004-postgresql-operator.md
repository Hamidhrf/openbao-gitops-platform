# ADR-004: PostgreSQL operator

Status: accepted (2026-09-22). The TLS line is amended by ADR-007. Two statements are corrected on 2026-09-29 and marked below.

## Context

OpenBao needs a highly available PostgreSQL backend that is backed up automatically and can be restored after a failure, including the loss of the whole cluster. It must run on Kubernetes 1.36 (ADR-001) and be deployed by Flux. ADR-001 fixes 3 instances, one per worker, and leaves the enforcement mechanism to each component.

What OpenBao needs from the database (OpenBao 2.6 PostgreSQL storage backend):

- two tables, `openbao_kv_store` and `openbao_ha_locks`, which OpenBao creates itself unless `skip_create_table` is set;
- one connection target that always points at the primary;
- the HA lock lives in the database. In v2.6.2 the active node renews a lock row every 5 s with a 15 s TTL and gives up leadership when a renewal fails, so a database failover also causes an OpenBao leadership change.

OpenBao keeps its keyring, secrets, tokens and leases in this database, so a failover must not silently drop acknowledged commits.

## Options

CloudNativePG 1.30.0. The operator and an instance manager in each pod handle failover through the Kubernetes API, without Patroni. Backups, schedules and restores are custom resources with status. Kubernetes 1.36 support was added in 1.30.0. TLS with an operator-managed CA and a Prometheus exporter are built in. Apache 2.0, CNCF Sandbox project. Backups to object storage go through the Barman Cloud plugin, because the in-tree implementation is deprecated and scheduled for removal in 1.31. The plugin requires cert-manager.

Zalando postgres-operator v2.0.2. Patroni in every pod and years of production use at Zalando. Backups are WAL-G inside the Spilo image, configured with environment variables. There are no backup objects in Kubernetes, and a restore is a clone into a new cluster. The README lists Kubernetes "1.27+" without naming 1.36. TLS uses a self-signed certificate per pod unless one is mounted, and there is no built-in exporter. v2.0 changed several defaults a few weeks before this decision.

Crunchy PGO v6.0.3. Strong backup tooling (pgBackRest) and support for Kubernetes 1.32 to 1.36. The default images are published under the Crunchy Data Developer Program terms, which limit organisations with 50 or more employees to development, testing and demonstration use; production use needs a support subscription. Building our own images from PGDG packages is possible but out of scope. I did not shortlist it for that reason.

## Decision

I use CloudNativePG 1.30.0 (Helm chart `cloudnative-pg` 0.29.0) with the Barman Cloud plugin v0.15.0 (chart `plugin-barman-cloud` 0.8.0). cert-manager v1.21.2 is installed as the plugin's prerequisite. Its wider role for TLS is decided in a later ADR.

High availability:

- 3 instances with required pod anti-affinity on `kubernetes.io/hostname`, so at most one instance runs on each worker. The control-plane taint keeps them off the control-plane node.
- Synchronous replication with `method: any`, `number: 1`, `dataDurability: required` and `failoverQuorum: true`. A commit is acknowledged only after one standby has received it. If a standby is lost, writes continue with the other one. If the primary is lost, the operator promotes a replica only when it can establish that the replica has all synchronously acknowledged commits. Otherwise it does not promote, and writes stop until an instance returns or someone promotes a replica manually with `kubectl cnpg promote` and accepts possible data loss. With three instances this tolerates the loss of any one instance without manual action.

Backup and restore (the object store is decided in ADR-005):

- continuous WAL archiving and scheduled base backups through an `ObjectStore` and a `ScheduledBackup` resource;
- a restore, including point-in-time recovery, always creates a new Cluster from `bootstrap.recovery`, committed to Git, with its own `serverName` so it never writes into the archive it restores from.

OpenBao's database credential:

- A SOPS-encrypted `kubernetes.io/basic-auth` Secret in Git (ADR-002). CloudNativePG sets the role's password from it when a cluster is created and when a cluster is restored. OpenBao reads the same values through environment variables. The operator does not back up Secrets, so keeping the credential in Git is what lets it survive the loss of the cluster.
- OpenBao connects as the owner of its database and creates its two tables. This is a simplicity trade-off: it avoids a second privileged role, its Secret and a schema-init Job. The stricter alternative is `skip_create_table = true`, a separate schema owner that runs the DDL once, and a runtime role with only SELECT, INSERT, UPDATE and DELETE, which cannot DROP, ALTER, TRUNCATE or create objects.

TLS:

- CloudNativePG's operator-generated CA. OpenBao connects to the `-rw` service with `sslmode=verify-full`.
- OpenBao receives only `ca.crt`. The `<cluster>-ca` Secret also contains `ca.key`, and by default the same CA signs client certificates, so its holder can issue client certificates that PostgreSQL trusts. What such a certificate can reach still depends on `pg_hba.conf`, the certificate-to-user mapping and role privileges.
- A `hostnossl` reject rule for OpenBao's database, because the default `pg_hba.conf` accepts password logins without TLS. Correction, 2026-09-29: I never added this rule to the Cluster manifest. OpenBao itself always connects with `sslmode=verify-full`, but the server still accepts a password login without TLS from other clients. The rule is on the list of changes before production in docs/production-readiness.md.

Not decided here: whether PostgreSQL and OpenBao share a namespace, which is decided with the OpenBao and TLS designs, and OpenBao's own connection settings.

## Limitations

- All nodes run on one VM (ADR-001). An instance failure is a pod or container failure on a shared disk, not an independent host failure.
- local-path volumes give no storage-level redundancy and no snapshots. If a node is lost for good, its instance has to be recreated and cloned from the primary. With required anti-affinity and exactly three workers, that instance stays Pending until a worker is available again.
- One control-plane node. CloudNativePG's failover depends on the Kubernetes API.
- The Barman Cloud plugin is still 0.x.
- CloudNativePG 1.30.0 had no patch release when I made this decision. Correction, 2026-09-29: 1.30.1 was released on 23 September 2026 with security and failover fixes. I stayed on 1.30.0 because every HA and recovery test in this repository ran on it. The upgrade comes before production.
- Quorum failover prefers consistency over availability: with two of three instances gone, the cluster stops accepting writes instead of promoting.
- Rotating OpenBao's database password means updating the SOPS Secret and restarting OpenBao, because environment variables from a Secret do not change in a running pod.
- Anyone who can create workloads in the database's namespace can mount its Secrets, including `ca.key`, so the namespace boundary matters.
- No monitoring stack. Each instance serves the exporter on port 9187 and the operator serves its own on 8080, but nothing scrapes or retains them, and there is no PodMonitor. See docs/observability.md.

## References

- https://github.com/cloudnative-pg/cloudnative-pg/releases/tag/v1.30.0
- https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/failover.md
- https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/replication.md
- https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/recovery.md
- https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/certificates.md
- https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/
- https://cert-manager.io/docs/releases/
- https://openbao.org/docs/configuration/storage/postgresql/
- https://github.com/openbao/openbao/blob/v2.6.2/physical/postgresql/postgresql.go
- https://github.com/zalando/postgres-operator/blob/v2.0.2/README.md
- https://access.crunchydata.com/documentation/postgres-operator/latest/overview/supported-platforms
- https://www.crunchydata.com/developers/terms-of-use
- https://kubernetes.io/docs/concepts/security/rbac-good-practices/
- https://www.cncf.io/blog/2026/09/16/running-openbao-on-kubernetes-with-a-cloudnativepg-postgresql-backend/
