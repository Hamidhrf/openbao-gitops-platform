# Backup and restore

PostgreSQL runs as the CloudNativePG cluster `openbao-db` in the `database` namespace. Base backups and WAL archives go to the host backup store described in ADR-005, through the Barman Cloud Plugin and the `ObjectStore` named `backup-store`.

## What is stored

Base backups are taken daily at 02:00 UTC by the `ScheduledBackup` `openbao-db-daily`. Between them, the plugin sidecar in each instance pod ships WAL segments continuously. Both are compressed with gzip and stored under `s3://pg-backups/openbao-db/`. Retention is 7 days, set on the `ObjectStore`, which is a demo value.

Kubernetes Secrets are not part of a backup. The database credential lives in Git, encrypted with SOPS, and is restored from there.

Current state:

    kubectl --context kind-openbao-local get cluster openbao-db -n database
    kubectl --context kind-openbao-local get objectstore backup-store -n database -o jsonpath='{.status}{"\n"}'

`ContinuousArchiving=True` in the cluster conditions means WAL archiving is working. The `ObjectStore` status reports the oldest and newest recoverability points.

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

A restore never changes the running cluster. It creates a new `Cluster` that bootstraps from the object store, reading the path named by `serverName`. Templates are in `docs/restore/`.

Full restore to the latest available point:

    cp docs/restore/restore-full.yaml platform/database/
    printf '  - restore-full.yaml\n' >> platform/database/kustomization.yaml
    git add platform/database
    git commit -m "feat: restore openbao-db into a new cluster"
    git push

Flux creates `openbao-db-restore`. Recovery reads the most recent base backup and replays the WAL archive on top of it, so the restored cluster also contains transactions committed after that backup was taken.

    kubectl --context kind-openbao-local get cluster -n database
    kubectl --context kind-openbao-local get pods -n database

Point-in-time restore uses the same steps with `docs/restore/restore-pitr.yaml`, after setting `targetTime` in it. A suitable timestamp comes from PostgreSQL itself:

    kubectl --context kind-openbao-local exec -n database openbao-db-1 -c postgres -- psql -U postgres -At -c "select now()"

The restored cluster replays WAL up to the target and stops. Where it stopped is recorded in the timeline history file:

    kubectl --context kind-openbao-local exec -n database openbao-db-pitr-1 -c postgres -- bash -c 'cat $PGDATA/pg_wal/*.history'

The last line names the first transaction that was not applied, so the timestamp shown there is later than the target.

To remove a restored cluster, move the file back to `docs/restore/`, delete its line from `platform/database/kustomization.yaml`, then commit and push. Flux deletes the cluster and its volume.

Serving traffic from a restored cluster is not part of this demo. It would mean pointing OpenBao at the new service name and giving the restored cluster its own `plugins` section with a new `serverName`, because the plugin refuses to archive into a path that already holds another cluster's backups.

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

Restore has been tested into a new cluster alongside the running one. A restore after losing and rebuilding the Kubernetes cluster has not been run yet.

Retention of 7 days is a demo value, and no alert exists on the age of the last backup or on archiving failures.
