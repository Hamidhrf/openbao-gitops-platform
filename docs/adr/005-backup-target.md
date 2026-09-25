# ADR-005: Backup target

Status: accepted (2026-09-22)

## Context

ADR-004 uses the Barman Cloud plugin, which sends base backups and WAL files to object storage. The backups must survive the loss of the kind cluster, so the store cannot run inside it. The plugin must reach the store over HTTPS and verify its certificate. The store's credential is a bootstrap secret, so it must not depend on OpenBao.

The plugin lists MinIO as its only tested and verified S3-compatible implementation. The MinIO repository was archived in April 2026 and gets no fixes. Azurite, also on that list, is a simulator for Azure Blob Storage. A maintained alternative therefore had to prove itself with a real backup and restore before I accepted it.

## Options

A cloud bucket, for example Amazon S3. It is the only option that survives the loss of the VM. It needs an account, costs money, depends on the internet and sends data out of this environment. I kept it as the production reference, not the demo target.

Garage v2.4.1. No TLS option in its configuration reference, no versioning or object lock, and extra layout, key and bucket setup steps. I did not shortlist it.

Versity S3 Gateway v1.8.0, RustFS 1.0.0 and SeaweedFS 4.47. All three are maintained and have built-in TLS. These were the candidates for a spike on a throwaway kind cluster.

## Selection spike (22 Sep 2026)

Before the spike I fixed six gates and a first-pass rule: candidates are tested in a set order, and the first one that passes every gate is chosen.

I tested Versity first because it is a single binary with built-in TLS that stores objects as plain files on the host, which keeps the demo store small and easy to inspect. RustFS came second because its first stable release (1.0.0, 16 Sep 2026) was only six days old when I set the order. SeaweedFS came last because an open plugin issue (#679) reports WAL archiving to SeaweedFS failing.

The spike used a single-node kind cluster with CloudNativePG 1.30.0, the Barman Cloud plugin v0.15.0 (Barman 3.20.0), cert-manager v1.21.2 and one PostgreSQL 18.6 instance. Versity ran on the host with the network, TLS and hardening settings described below, but with throwaway credentials outside Git and without the start script. Results:

- G1, HTTPS trust: a pod reached the store and verified its certificate against `endpointCA` (HTTP 200). Without the CA, curl failed certificate verification (exit 60). The store did not answer on the VM's LAN address.
- G2, WAL archiving: `ContinuousArchiving` became true, with no failed archives. The boto3 checksum workaround in the plugin docs was not needed.
- G3, on-demand backup: a `Backup` completed, and the `ObjectStore` status showed a first recoverability point.
- G4, marker data: three rows were written before a recorded target time and three after it, and the WAL segment holding the later rows was archived.
- G5, full restore into a new Cluster: all six rows were present.
- G6, point-in-time restore to the target time into a new Cluster: only the three earlier rows were present.

Versity passed all six gates, so I did not test RustFS or SeaweedFS. This was a compatibility gate, not a benchmark or a ranking of the three.

## Decision

I use Versity S3 Gateway v1.8.0 with its posix backend as the backup store for the demo.

Placement and GitOps boundary:

- Versity runs as a Docker container on the VM, outside kind, so deleting the cluster does not remove the store or its data. A script in `scripts/` starts it with the image pinned by digest.
- Flux does not manage, watch or restart the container. I treat it as external backup infrastructure, like a cloud bucket. Its image and startup configuration are in Git, and the `ObjectStore` and backup resources in the cluster are managed by Flux.

Network and TLS:

- The container is on Docker's default bridge. Its S3 port is published only on the `kind` network gateway, `172.18.0.1:9000` (container port 7070), not on the VM's LAN address. The script reads the gateway from `docker network inspect kind` and stops if it differs from the value in Git.
- HTTPS uses a self-signed certificate that the script creates, with the gateway IP as subject alternative name. Only the public certificate is in Git, as the `endpointCA` Secret. When the certificate is replaced, the new one has to be committed.

Data and keys:

- Objects are stored as plain files in a host directory outside the repository. The TLS key and certificate are in a sibling directory, never inside the object directory, so S3 clients cannot read them.
- The script creates the bucket through the S3 API at startup, so initialisation does not depend on Barman creating it.

Credential:

- One credential for the store, kept in two SOPS-encrypted files (ADR-002): a Kubernetes Secret for the plugin and a dotenv file for the container. Neither copy depends on OpenBao.

Backup settings:

- WAL files are compressed with gzip. `retentionPolicy` is 7 days, a demo value, not a production recommendation.

Container hardening, as used in the spike: a non-root host user, all capabilities dropped, a read-only root filesystem and `no-new-privileges`.

## Limitations

- The store runs on the same VM and disk as the cluster. Backup data is outside the kind cluster, but the demo does not protect against losing the VM or its disk.
- The demo uses the root credential of a dedicated single-purpose Versity instance. This credential can administer the entire backup store. Production should use a separate least-privilege identity scoped to the PostgreSQL backup bucket. I did not test a non-root Versity user.
- Docker keeps the container's environment, including this credential, in its configuration under `/var/lib/docker`, and a plain `docker inspect` prints it. Anyone with Docker access on the VM can read it.
- The two copies of the credential can drift apart. Rotation must update both.
- The demo store does not use versioning or object lock, so anyone with the credential can delete or overwrite backups.
- Because Versity is not covered by the Barman Cloud plugin's upstream compatibility tests, upgrades to Versity, the plugin or Barman should repeat the WAL archiving, backup, full restore and PITR checks.
- Once backups are authoritative, changing the backend needs a new full backup set or a migration.

## Not tested

- RustFS and SeaweedFS.
- A non-root Versity user.
- Versioning and object lock.
- More than one PostgreSQL instance, `ScheduledBackup` and retention enforcement.
- A restored cluster that archives under a new `serverName`.
- WAL archiving catch-up after a store outage.
- A full restore after `kind delete cluster` and a rebuild from Git.

`ScheduledBackup` and three instances are part of the PostgreSQL deployment. A store outage and a restore after rebuilding the cluster are planned failure tests.

## Update, 25 September 2026

Four of the items above have since been tested. `ScheduledBackup`, three instances and retention are part of the PostgreSQL deployment and have run daily since 23 September. WAL archiving caught up on its own after a store outage. A full restore after `kind delete cluster` was run as a rehearsal, and the store stayed up throughout the total loss of the Kubernetes cluster without being restarted.

A restored cluster archiving under a new `serverName` turned out to be required rather than optional. CloudNativePG refuses to archive into a destination that already holds another cluster's backups, so every recovery opens a new catalogue generation and the one it read from is left frozen.

Results are in docs/backup-restore.md and docs/disaster-recovery.md. RustFS, SeaweedFS, a non-root Versity user, versioning and object lock are still untested.

## Demo and production

| | Demo | Production |
|---|---|---|
| Location | Container on the same VM and disk | Object storage in another site or region |
| Designed to survive | Loss of the kind cluster | Loss of the cluster, host or site |
| Identity | Root credential of a dedicated store, static key in SOPS | Least-privilege identity scoped to the backup bucket, workload identity where possible |
| Deletion protection | None | Versioning, object lock and lifecycle rules |
| Monitoring | Checked by hand | Alerts on last-backup age and WAL archiving failures |
| Restore tests | Run by hand | Scheduled |

## References

- https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.0/web/docs/intro.md
- https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.0/web/docs/object_stores.md
- https://github.com/cloudnative-pg/plugin-barman-cloud/issues/679
- https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/recovery.md
- https://github.com/minio/minio
- https://github.com/versity/versitygw/tree/v1.8.0
- https://github.com/rustfs/rustfs/releases
- https://github.com/seaweedfs/seaweedfs/tree/4.47
- https://github.com/deuxfleurs-org/garage/tree/v2.4.1
