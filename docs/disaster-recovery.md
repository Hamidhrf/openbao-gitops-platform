# Disaster recovery

## 1. Scope

This document covers backup and restore of the PostgreSQL cluster, and recovery of the whole
platform after the Kubernetes cluster is lost. OpenBao keeps all of its state in PostgreSQL, in the
tables `openbao_kv_store` and `openbao_ha_locks`, so PostgreSQL's recovery point is also OpenBao's
recovery point.

It does not cover loss of the VM. The backup store runs as a container on the same host as the kind
cluster, so it survives the loss of the cluster but not the loss of the machine. It does not cover
restoring the backup store itself.

Restoring a copy of the database, or recovering to an earlier point in time while the platform is
still running, is a different incident and is covered in
[Backup and restore](backup-restore.md).

Every result stated here was observed on this platform. The full-loss procedure was rehearsed on
25 September 2026 by deleting the kind cluster and rebuilding it from scratch.

## 2. Recovery inputs

Recovery needs three inputs. None of them is optional.

| Input | Where it lives | What is lost without it |
|---|---|---|
| The Git repository, branch `main` | GitHub, and any clone | Everything. It holds every manifest and the SOPS-encrypted bootstrap secrets, including the static seal key and the backup store credential. |
| The backup store | `~/backup-store/` on the VM, served by the `backup-store` container on `172.18.0.1:9000` | All data. A new PostgreSQL cluster initializes empty, OpenBao self-initializes a new barrier, and every stored secret is gone. |
| The age identity | The working identity on the VM, or the second, offline break-glass identity | The ability to unseal. Flux cannot decrypt the static seal key, so OpenBao cannot open the barrier that came back from the database. |

Two of the three are not enough. Git and the age identity without the backup store give a working but
empty platform, which is exactly what rehearsal attempt 1 produced. Git and the backup store without
the age identity give a database that holds the barrier and nothing that can open it.

The backup store must be running and healthy before the database recovers. It was last started on
23 September 2026 at 13:18 UTC and kept running through the full teardown of the Kubernetes cluster
on 25 September.

## 3. Failure scenarios

| Scenario | Recovery | Observed |
|---|---|---|
| PostgreSQL primary pod deleted | Automatic failover | About one second |
| Worker running the PostgreSQL primary stopped | Automatic, paced by Kubernetes | 46 s to `NodeNotReady`, then the 300 s unreachable toleration before eviction |
| Two of three PostgreSQL workers stopped | Writes stop, no promotion, automatic heal when a node returns | Operator logged `Strong consistency check failed. Preventing failover.` |
| Backup store unavailable | Database stays available, WAL queues, archiver catches up | Section 7 |
| Node running the active OpenBao stopped gracefully | Automatic leadership transfer | One failed request |
| Node running the active OpenBao killed | Automatic, with client impact while the endpoint is stale | About 52 seconds, twelve failed requests |
| Total loss of the Kubernetes cluster | Operator-driven | Section 5 |
| Recovery to an earlier point in time | Operator-driven | Section 6 |

The failover numbers and their analysis are in the README. Only the operator-driven cases have
procedures here.

## 4. Recovery point and recovery time

The recovery point is the last WAL segment that reached the backup store, not the moment of failure.
Three different numbers apply, and they should not be confused.

A rehearsed shutdown can lose nothing. Before the teardown a marker row was committed at
12:15:08.239483+00, `pg_switch_wal()` closed segment `00000003000000010000002F`, and the archiver
shipped it by 12:15:31, moving `archived_count` from 305 to 306. The gap was about 23 seconds and no
committed data was lost. This is evidence of the rehearsal, not a worst case.

An unplanned loss is worse. `archive_timeout` is five minutes, so the open segment can hold up to
five minutes of writes that have never reached the store. Those writes are lost with the cluster.

A loss during a backup store outage is worse again. PostgreSQL keeps committing while archiving
fails, so the unarchived window grows for as long as the store is down.

Synchronous replication with `dataDurability: required` means no acknowledged commit is lost inside
the cluster. It does not shorten the archive lag, which is the number that matters once the cluster
is gone.

No clean recovery time has been measured. The rehearsal deliberately contained three failed recovery
attempts, so its wall clock measures troubleshooting rather than the procedure. Two component timings
were observed: four nodes reached Ready about 35 seconds after `kind create cluster`, and OpenBao
unsealed at 13:42:30 with `core: unsealed with stored key`, seconds after the database became
available and with no human step.

## 5. Total loss of the Kubernetes cluster

Every state change in this procedure goes through Git. Do not run `kubectl apply` against an object
Flux manages.

### Step 1. Seal the recovery point (planned loss only)

Force a WAL switch on the primary and confirm the closed segment reaches the store. The commands
below use `openbao-db-1`, the primary here. Check that it still is:

    kubectl --context kind-openbao-local -n database get cluster openbao-db \
        -o jsonpath='{.status.currentPrimary}{"\n"}'

    kubectl --context kind-openbao-local -n database exec openbao-db-1 -c postgres -- \
        psql -U postgres -d openbao -c "select pg_switch_wal();"

    kubectl --context kind-openbao-local -n database exec openbao-db-1 -c postgres -- \
        psql -U postgres -d openbao -c "select last_archived_wal, archived_count from pg_stat_archiver;"

`last_archived_wal` must name the segment that was just closed.

### Step 2. Choose the next catalogue generation

A recovered cluster must not archive into the catalogue it reads from, so pick the name of the new
generation now and write it down. The writer in use is `openbao-db-dr-20260925b`. Section 9 explains
why.

### Step 3. Confirm the backup store is healthy

The script is idempotent and re-running it checks the container, the certificate and the bucket
without recreating anything.

    ./scripts/backup-store.sh

### Step 4. Recreate the Kubernetes cluster

    kind create cluster --config bootstrap/kind-cluster.yaml --kubeconfig ~/.kube/openbao-local

### Step 5. Commit the recovery configuration before Flux exists

In `platform/database/cluster.yaml`, make four changes. Replace `bootstrap.initdb` with
`bootstrap.recovery`. Add the `externalClusters` entry whose plugin parameters name the catalogue
being recovered from. Pin `recoveryTarget.backupID` to a known-good base backup. Set the `serverName`
in the Cluster's own `plugins` parameters to the new generation from step 2.

Commit and push before bootstrapping Flux, so that the recovery commit is already the artifact when
the Cluster is created.

### Step 6. Bootstrap Flux

A fresh shell has no SSH agent, and the Flux CLI needs one.

    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519

    flux bootstrap git \
        --context=kind-openbao-local \
        --url=ssh://git@github.com/Hamidhrf/openbao-gitops-platform \
        --branch=main \
        --path=clusters/local

Bootstrap prints the public key it generated for the new cluster and waits. Add that key to the
repository as a read-only deploy key, then confirm. Delete the lost cluster's deploy key once the new
one reconciles (ADR-003).

### Step 7. Confirm the source is authenticated and carries the recovery commit

    flux --context kind-openbao-local get sources git flux-system

Bootstrap can fail after installing the controllers, leaving the GitRepository unauthenticated
because the `flux-system` Secret was never written. If that happens, create the secret, add the
public key it prints as a read-only deploy key on the repository, and re-run the identical bootstrap
command, which finds the secret and skips key generation.

    flux create secret git flux-system \
        --context=kind-openbao-local \
        --url=ssh://git@github.com/Hamidhrf/openbao-gitops-platform

### Step 8. Install the age identity

    kubectl --context kind-openbao-local -n flux-system create secret generic sops-age \
        --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

Encrypted Kustomizations fail until this secret exists. That is a bootstrap dependency, not a race:
decryption fails rather than something wrong being applied.

### Step 9. Confirm what the Cluster was born from

A Kustomization's applied revision says what it last reconciled, not what an object was created from.
Check the object.

    kubectl --context kind-openbao-local -n database get cluster openbao-db \
        -o jsonpath='{.metadata.creationTimestamp}{"\n"}{.spec.bootstrap}{"\n"}'

If the Cluster was created with `initdb`, stop. Applying the recovery manifest cannot fix it, because
`bootstrap` only applies when the object is created, so applying it to an object that already
exists does nothing. The empty cluster will also have
written a base backup into the source catalogue within seconds, so the next attempt must pin
`recoveryTarget.backupID`. Remove the Cluster from Git, let Flux garbage-collect it, and start again
from step 5.

### Step 10. Wait for recovery and confirm archiving resumed

    kubectl --context kind-openbao-local -n database get cluster openbao-db \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'

`ContinuousArchiving` must be True and the timeline must have advanced.

### Step 11. Take a base backup in the new generation

A fresh generation holds WAL and no base backup, so nothing can be replayed onto it. Commit a one-off
`Backup` object, wait for it to complete, then remove it in a later commit. After the rehearsal this
produced base backup `20260925T140024`, completed at 14:00:31.

### Step 12. Return the Cluster to `initdb`

Commit `bootstrap.initdb` again, keeping the new writer `serverName`, so the repository does not
describe a permanent recovery. This changes nothing on the running cluster: after the rehearsal the Cluster
UID, all three pod UIDs and the restart counts were unchanged and all five conditions stayed True.

### Step 13. Verify

Work through section 8.

## 6. Restore with the cluster intact

Restoring a copy of the database, or recovering to an earlier point in time, while the Kubernetes
cluster is still running is covered in [Backup and restore](backup-restore.md), together with the
manifests in `docs/restore/`.

Two things from there matter here. A restore is never applied to the running cluster: it is a new
Cluster committed to Git that bootstraps from the object store. And a restore cluster has no `plugins`
section, so it never archives, which is why the catalogue generation rule in section 9 does not apply
to it.

## 7. Backup store outage

An outage of the backup store is not a loss of the platform. The database stays available, WAL queues
on the primary's volume, and the archiver catches up on its own when the store returns. This was
tested on 23 September 2026 and is described in [Backup and restore](backup-restore.md).

It matters here because the recovery point moves backwards for as long as the store is down. Writes
keep committing while nothing is being archived, so an outage that goes unnoticed silently widens the
window a later disaster would lose.

## 8. Verification

These nine checks were run after the rehearsal on 25 September 2026.

| # | Check | Observed |
|---|---|---|
| 1 | The marker row survived | `restore_test` holds 7 rows, id 7 `pre-teardown marker`, committed 12:15:08.239483 |
| 2 | Archiving resumed into the new generation | Timeline 4, `ContinuousArchiving=True`, writer `openbao-db-dr-20260925b` |
| 3 | The OpenBao barrier is the same one | Cluster ID `bb0c48ef-a111-564f-2ec0-7e93a6221254`, KV mount uuid and Kubernetes auth accessor all identical to the pre-teardown values |
| 4 | OpenBao did not self-initialize | No `security barrier initialized` and no `initialize[0]` in the logs of any of the three pods |
| 5 | Kubernetes auth works against a new API server CA | `auth/kubernetes/config` has `kubernetes_ca_cert n/a` and `token_reviewer_jwt_set false`, so OpenBao reads the CA and the reviewer token from its own pod at request time |
| 6 | A pulled secret came back from the database | `secret/apps/demo/config` v2, created 24 Sep 23:43:42, updated 25 Sep 07:42:29 |
| 7 | Kubernetes Secrets were recreated, not restored | `demo-client-tls`, issued again by cert-manager, and `demo-config`, written again by External Secrets, have new timestamps and new UIDs |
| 8 | TLS through the exposed port | `https://openbao.local.test:8200/v1/sys/health` returned 200 with the platform CA; the same request without the CA and by IP were both refused |
| 9 | The new generation is independently recoverable | One-off `Backup` `openbao-db-after-recovery` completed 14:00:31, base backup `20260925T140024` |

Checkpoints 6 and 7 side by side show what recovery returns. Data comes back from the database with
its original timestamps. Kubernetes objects are made again by the controller that owns them.

The pushed certificate shows both at once. OpenBao first came back with the old certificate, restored
from the database with the rest of its data. cert-manager had already issued a new one in the new
cluster, and External Secrets wrote it into OpenBao at 14:05:16 as versions 3 and 4 of
`secret/pushed/demo/client`, 23 minutes after OpenBao returned. The `PushSecret` reported Ready the
whole time, so its status did not show that OpenBao held the older value in between.

Two things that look like checks and are not. The row count of `openbao_kv_store` moves constantly,
because tokens, leases and internal state share the table, so compare specific paths and their
metadata instead. `pg_stat_archiver.failed_count` is cumulative and never clears on success, so it is
not a statement about the present: after this recovery it read 15 with
`last_failed_wal 00000004.history`, while the sidecar log showed that same history file archived
successfully at 13:41:27. Judge archiving by `ContinuousArchiving` and `last_archived_wal` instead.

## 9. Why the procedure is ordered this way

### An object's birth revision is not the Kustomization's revision

A Flux Kustomization's applied revision says what it last reconciled, not what a given object was
created from. On 25 September the `database` Kustomization created the Cluster at 12:50:37 from
artifact `6c0cac4`, which still said `initdb`, and applied the recovery commit `ff8ba18` at 12:52:07.
Because `bootstrap` only applies when the object is created, applying the recovery commit later did
nothing, and the platform came up empty. Pushing the recovery commit before bootstrapping Flux removes the race. Comparing the
object's `creationTimestamp` with the push time is what settles it afterwards.

### Creating a cluster is a backup event

`ScheduledBackup` carries `immediate: true`, so it fires within seconds of a Cluster being created.
The empty cluster from attempt 1 wrote base backup `20260925T125107` into the real `openbao-db`
catalogue, and that is what broke attempt 2. Anything wrong about a cluster at birth reaches the
catalogue immediately.

### The junk base backup is still the newest one in the `openbao-db` catalogue

`20260925T125107` and the polluted generation `openbao-db-dr-20260925` were kept rather than deleted,
as a record of what happened. Any future recovery from the `openbao-db` generation must pin
`recoveryTarget.backupID` to a known-good base backup, or recovery will select the empty one.

### A recovered cluster must not archive into the catalogue it read

CloudNativePG runs `barman-cloud-check-wal-archive` when a cluster starts archiving and refuses a
non-empty destination, leaving the Cluster stuck in `Setting up primary`. Every recovery therefore
opens a new generation: the recovery source stays the old `serverName`, and the writer in the
Cluster's own `plugins` parameters becomes the new one.

Unlike `bootstrap`, `serverName` is live configuration and takes effect immediately, so a commit that
changes it must never reach a running cluster that should keep its own catalogue.

The old generation is left with no writer. Nothing applies its retention policy to it any more, so it
stays frozen and remains usable as a recovery source.

### Pin the base backup, do not invent a time

`recoveryTarget.backupID` on its own replays to the end of the archive and promotes, which is what a
full restore wants. A `recoveryTarget.targetTime` beyond the end of the archive is fatal even when
every available row has already been replayed. Attempt 3 replayed all of timeline 3, reached
`redo done at 1/2F015E90` with the last transaction at 12:15:25.799986, and then failed with
`recovery ended before configured recovery target was reached`, because the target was 12:20. The id
format is barman's, `20260925T020001`, and it appears in the recovery log as `"backup_id"`.

### A fresh generation has nothing to replay onto

After recovery the new generation held WAL and no base backup, and
`ScheduledBackup.status.lastScheduleTime` still pointed at the empty cluster's firing, with the next
scheduled run the following night. Until a base backup exists in the new generation, the recovered
cluster is not itself recoverable.

### The rehearsal, 25 September 2026

| Attempt | Commit | What it did | Why it failed |
|---|---|---|---|
| 1 | `ff8ba18` | Recovery commit pushed after Flux bootstrap | The Cluster was created from the previous artifact with `initdb`, so the platform came up empty, and its immediate backup polluted the source catalogue |
| 2 | `687882b` | Recovered into a fresh generation | Recovery chose the newest base backup, which was the empty cluster's `20260925T125107`, then refused WAL from a different database system |
| 3 | `db6d71e` | Added `recoveryTarget.targetTime: 2026-09-25 12:20:00+00` | Correct base backup and complete replay, then FATAL because the target was past the end of the archive |
| 4 | `5e43034` | `recoveryTarget.backupID: 20260925T020001`, no time target | Succeeded |

Flux bootstrap also needed two attempts. The first failed at `applying source secret` with
`client rate limiter Wait returned an error: context deadline exceeded`: the controllers were
installed and the GitRepository and Kustomization created, but the `flux-system` Secret was never
written, so the source could not authenticate. Step 7 holds the recovery. Each failed attempt leaves
a dead deploy key on the repository.

## 10. Limitations

Everything runs on one VM. The backup store survives the loss of the Kubernetes cluster, which the
rehearsal proved, but not the loss of the host. There is no copy of the backups off this machine.

The backup store has no restore procedure of its own. If `~/backup-store/` is lost, re-running the
script creates a new, empty store.

Losing both age identities makes a recovered database unreadable, because the static seal key in Git
cannot be decrypted. The offline break-glass identity is the only fallback if the working identity on
the VM is lost.

There is one control-plane node, so the control plane is not highly available.

The procedure has been rehearsed once, on one host. No clean recovery time has been measured.
