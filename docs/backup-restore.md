# Backup and restore

PostgreSQL runs as the CloudNativePG cluster `openbao-db` in the `database` namespace. Base backups and WAL archives go to the host backup store described in ADR-005, through the Barman Cloud Plugin and the `ObjectStore` named `backup-store`.

## What is stored

Base backups are taken daily at 02:00 UTC by the `ScheduledBackup` `openbao-db-daily`. Between them, the plugin sidecar in each instance pod ships WAL segments continuously. Both are compressed with gzip and stored in the bucket `pg-backups`, under the catalogue generation named by `serverName` in the cluster's plugin parameters. Retention is 7 days, set on the `ObjectStore`, which is a demo value.

Kubernetes Secrets are not part of a backup. The database credential lives in Git, encrypted with SOPS, and is restored from there.

Current state:

    kubectl --context kind-openbao-local get cluster openbao-db -n database
    kubectl --context kind-openbao-local get objectstore backup-store -n database -o jsonpath='{.status}{"\n"}'

`ContinuousArchiving=True` in the cluster conditions means WAL archiving is working. The `ObjectStore` status reports the oldest and newest recoverability points.

## Recovery source and catalogue generations

`serverName` names the directory a cluster's backups are written to and read from. It is part of choosing a recovery point rather than plumbing, and it is not the cluster's name.

A recovered cluster must not archive into the generation it read from, because CloudNativePG refuses to archive into a destination that already holds another cluster's backups. Every recovery therefore opens a new generation. The store holds three:

| Generation | State |
|---|---|
| `openbao-db` | Frozen. Base backups and WAL up to 25 September 2026 12:15, plus one invalid base backup, `20260925T125107`, written by an empty cluster during a failed recovery attempt. |
| `openbao-db-dr-20260925` | Abandoned. WAL only, no base backup, so nothing can be recovered from it. |
| `openbao-db-dr-20260925b` | Active. The generation the running cluster writes to. |

A frozen generation keeps its contents indefinitely, because retention is applied by the cluster that writes to it and no cluster writes to these.

Before restoring, decide which generation covers the point you want and list the base backups it holds:

    ls -1 ~/backup-store/objects/pg-backups/openbao-db-dr-20260925b/base

With no `recoveryTarget`, recovery selects the newest base backup in that generation. That is why `openbao-db` cannot be restored from without pinning `recoveryTarget.backupID`: its newest base backup is the invalid one.

The restore manifests were corrected on 25 September 2026 after a documentation audit. They had been written two days earlier against the only generation that existed then, and the rehearsal moved the active writer afterwards, so the full restore example would have selected the invalid base backup.

The rule that produces these generations, and the rehearsal that produced these three, are in [Disaster recovery](disaster-recovery.md).

## On-demand backup

A one-off backup is an operation rather than desired state, so it is created directly instead of through Git:

    kubectl --context kind-openbao-local create -f - <<'EOF'
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      generateName: openbao-db-manual-
      namespace: database
    spec:
      method: plugin
      pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
      cluster:
        name: openbao-db
    EOF

    kubectl --context kind-openbao-local get backup -n database

## Restore

A restore never changes the running cluster. It creates a new `Cluster` that bootstraps from the object store, reading the generation named by `serverName`. Templates are in `docs/restore/`, and both carry comments on how to choose the source.

Confirm which generation and which base backup the template will use before committing it. `restore-full.yaml` reads the active generation and relies on newest-backup selection, which is only safe once you have listed what is there.

Full restore to the latest available point in the active generation:

    cp docs/restore/restore-full.yaml platform/database/
    printf '  - restore-full.yaml\n' >> platform/database/kustomization.yaml
    git add platform/database
    git commit -m "feat: restore openbao-db into a new cluster"
    git push

Flux creates `openbao-db-restore`. Recovery reads the most recent base backup in that generation and replays the WAL archive on top of it, so the restored cluster also contains transactions committed after that backup was taken.

    kubectl --context kind-openbao-local get cluster -n database
    kubectl --context kind-openbao-local get pods -n database

Point-in-time restore uses the same steps with `docs/restore/restore-pitr.yaml`, after setting `targetTime` and the generation that covers it. As committed, that file reproduces the restore tested on 23 September 2026 against the frozen `openbao-db` generation. A suitable timestamp comes from PostgreSQL itself:

    kubectl --context kind-openbao-local exec -n database openbao-db-1 -c postgres -- psql -U postgres -At -c "select now()"

The restored cluster replays WAL up to the target and stops. Where it stopped is recorded in the timeline history file:

    kubectl --context kind-openbao-local exec -n database openbao-db-pitr-1 -c postgres -- bash -c 'cat $PGDATA/pg_wal/*.history'

The last line names the first transaction that was not applied, so the timestamp shown there is later than the target.

To remove a restored cluster, move the file back to `docs/restore/`, delete its line from `platform/database/kustomization.yaml`, then commit and push. Flux deletes the cluster and its volume.

Serving traffic from a restored cluster is not part of this demo. It would mean pointing OpenBao at the new service name and giving the restored cluster its own `plugins` section with a new `serverName`, because the plugin refuses to archive into a path that already holds another cluster's backups. That was confirmed during the cluster-loss rehearsal, and the consequences are in [Disaster recovery](disaster-recovery.md).

## If the backup store is unavailable

PostgreSQL keeps unshipped WAL segments on the primary's volume and retries. Writes continue. The cluster condition `ContinuousArchiving` turns False and `failed_count` in `pg_stat_archiver` rises:

    kubectl --context kind-openbao-local exec -n database openbao-db-1 -c postgres -- psql -U postgres -At -c "select archived_count, failed_count, last_archived_wal, last_failed_wal from pg_stat_archiver"

When the store returns, archiving resumes from the segment that was failing, without intervention. The volume must have room for the WAL accumulated during the outage, so a long outage needs either more space or attention.

The store itself is started and checked with `scripts/backup-store.sh`. An existing stopped container is restarted with `docker start backup-store`.

## Observed results

Tested on 23 September 2026 against the running cluster, with a table holding rows written before and after a recorded target time.

| Check | Result |
|---|---|
| WAL archiving to the host store | `ContinuousArchiving=True`, first backup completed |
| Store stopped, WAL switch forced | archiving failed, writes continued, condition turned False |
| Store started again | the failing segment was archived, condition returned to True |
| Full restore into a new cluster | all rows present, including those committed after the base backup |
| Point-in-time restore | only the rows committed before the target, history file recorded the stopping point |

## Limitations

The backup store runs on the same VM and the same disk as the cluster. Backups survive losing the Kubernetes cluster, not losing the VM.

Restore has been tested into a new cluster alongside the running one, and after losing and rebuilding the Kubernetes cluster. The second case, its three failed attempts and the procedure that came out of them are in [Disaster recovery](disaster-recovery.md).

Retention of 7 days is a demo value, and no alert exists on the age of the last backup or on archiving failures.
