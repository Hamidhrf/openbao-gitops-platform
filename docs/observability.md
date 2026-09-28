# Observability

## 1. Scope

No monitoring backend is deployed. There is no Prometheus, no Grafana, no alert manager and no log
store. That is a demo simplification, not a statement that these signals do not matter.

This document has four parts. An inventory of what the platform exposes today, measured rather than
assumed. The signals production would collect. The conditions worth alerting on, each with the reason
the obvious version of that alert is wrong. And the troubleshooting routes that were actually used to
run and debug this platform, including during its failure tests.

Measurements are from 26 September 2026 on the running cluster unless another date is given.

## 2. What is exposed today

| Component | Endpoint | State |
|---|---|---|
| PostgreSQL instances | `:9187/metrics` on each instance pod | Live. HTTP 200 from inside the cluster, 117 metric families. Also `:8000` for instance status. |
| CloudNativePG operator | `:8080`, named `metrics` | Live |
| OpenBao | `sys/metrics` on the API listener | Live. No `telemetry` stanza is configured, so the built-in defaults apply. There is no separate metrics port. |
| External Secrets | `:8080` on the controller, the webhook and the cert-controller | Live |
| Flux controllers | `:8080`, named `http-prom`, on all four | Live |
| cert-manager | `:9402` on the controller, cainjector and webhook | Live |
| Backup store | `/health` over HTTPS on `172.18.0.1:9000` | No metrics. A blackbox probe is the only signal. |
| Kubernetes | kubelet and CoreDNS as usual | No metrics-server in kind, so `kubectl top` does not work here |

Nothing scrapes any of these. Every number in this repository was read from an object's status, from a
log, or from a one-off query.

OpenBao is the harder one to scrape. Its metrics are served by the API listener, so a scrape needs the platform
CA, a token with a policy that allows the path, and a route to the active node. Production would give
the collector its own identity for that rather than reusing an administrative token.

Production would add a Prometheus that scrapes the PostgreSQL instances through a `PodMonitor` and
the four controller endpoints above directly. It would also probe the backup store and the external
OpenBao endpoint from outside, and collect the container logs listed in section 6.

## 3. Signals by component

### PostgreSQL and backups

The Cluster's five conditions are the primary signal: `Initialized`, `ConsistentSystemID`, `Ready`,
`ContinuousArchiving` and `LastBackupSucceeded`.

    kubectl --context kind-openbao-local -n database get cluster openbao-db \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'

Beyond those: the number of ready instances and which pod is primary, the count of synchronous
standbys, the current timeline, and whether `last_archived_wal` is advancing. Read the archiver
statistics on the primary, which is `openbao-db-1` here:

    kubectl --context kind-openbao-local -n database exec openbao-db-1 -c postgres -- \
        psql -U postgres -d openbao -c "select last_archived_wal, archived_count, last_failed_wal, failed_count from pg_stat_archiver;"

The `ObjectStore` status carries the oldest and newest recoverability points, which is the real answer
to how far back a restore can reach.

### OpenBao

Seal state, initialization and whether a node is active come from `sys/health`, which needs no token.

The same facts are also on the pods. The Kubernetes service registration keeps `openbao-active`,
`openbao-sealed`, `openbao-initialized`, `openbao-perf-standby` and `openbao-version` current on every
pod, so the state of all three servers reads in one command and needs no authentication at all.

    kubectl --context kind-openbao-local -n openbao get pods \
        -L openbao-active,openbao-sealed,openbao-initialized,openbao-version

`openbao-active: "true"` is the label the external Service selects. `openbao-version` is how to tell
whether a rolling upgrade has finished, because the StatefulSet uses the `OnDelete` update strategy
and does not restart pods on its own.

Beyond those: leadership transitions in the server logs, request failures seen by clients, and the
count of connections OpenBao holds to PostgreSQL, which is capped by `max_parallel`.

### External Secrets

Conditions on each `ExternalSecret` and `PushSecret`, and on the two `ClusterSecretStore` objects.

    kubectl --context kind-openbao-local get externalsecret,pushsecret -A

A store validates itself on its own schedule, five minutes by default, so its readiness lags the
provider it describes.

### Flux

Readiness and applied revision of every Kustomization, the GitRepository and each HelmRelease.

    flux --context kind-openbao-local get kustomizations

### cert-manager

Certificate readiness and expiry, and separately the certificate actually being served.

    kubectl --context kind-openbao-local get certificate -A

### Platform

Node conditions, pod restarts and disk. Both clusters and the backup store share one 246 GB disk, and
kubelet starts deleting unused images at 85 per cent usage, so free space is an operational signal
here rather than a background detail.

## 4. Alerts, and the trap in each one

| Alert on | Trap |
|---|---|
| No unsealed active OpenBao answering for several minutes | A pod that is Running and Ready is not necessarily usable. The chart Services set `publishNotReadyAddresses: true`, so a sealed server stays addressable. |
| Any pod reporting `openbao-sealed=true`, or no pod reporting `openbao-active=true` | These labels are written by the pod itself, so they report only what a living pod can report. A killed pod keeps its last labels, and that is exactly how a dead server kept `openbao-active=true` for about 50 seconds during the node kill test. |
| Repeated OpenBao leadership transitions | One failover is normal behaviour, not an incident. Alert on the rate, not on a single change. |
| External `/v1/sys/health` failing from outside the cluster | A healthy new leader can coexist with a stale endpoint. After a node kill this was measured at about 52 seconds, because the active label is set by the pod on itself and a dead pod cannot clear it. |
| Cluster `Ready=False`, or fewer than three healthy instances, sustained | A primary failover takes about a second and is expected. Alert on persistence, not on the event. |
| Synchronous standby count below the required number | Three running pods do not prove durability. The commit guarantee comes from the synchronous configuration, not from the replica count. |
| `ContinuousArchiving=False`, or `last_archived_wal` not advancing beyond `archive_timeout` plus a margin | Never alert on `pg_stat_archiver.failed_count`. It is cumulative and never clears on success: after the successful recovery on 25 September it read 15 with `last_failed_wal 00000004.history`, while the sidecar log showed that same file archived successfully at 13:41:27. |
| No completed base backup within about 26 hours | WAL without a base backup cannot be replayed onto anything. A newly opened catalogue generation is in exactly that state until a backup is taken. `ScheduledBackup.status.lastScheduleTime` is also unreliable after a recovery, because it can still refer to a cluster that no longer exists. |
| Backup store `/health` failing | Nothing else alerts. The database stays writable and serves normally while the recovery point silently moves backwards. |
| `ExternalSecret` or `PushSecret` not Ready, or repeated reconcile errors | The target Secret keeps its last good value and the mounted file with it, so workloads look healthy for as long as the outage lasts. |
| Certificate expiry within a chosen window | Also probe the certificate actually served. OpenBao 2.6.3 has no listener reload, so cert-manager can renew the Secret while the process still serves the old certificate. |
| Any Flux Kustomization not Ready, or its revision not advancing | An applied revision says what was last reconciled, not what an existing object was created from. That distinction caused a failed recovery attempt and is covered in the disaster recovery document. |
| Node NotReady, disk pressure, persistent CrashLoopBackOff or Pending | Node readiness, endpoint removal and pod eviction run on three different clocks. Measured here: about 50 seconds to the node condition, 300 seconds to eviction under the default unreachable toleration. |

## 5. Troubleshooting by symptom

Symptoms cross component boundaries, so these are ordered by what an operator sees first.

### A workload's secret is stale

Check the `ExternalSecret` conditions and its last sync time, then the `ClusterSecretStore`, then the
External Secrets controller log, then OpenBao's health and seal state, then the Kubernetes auth path.
A permission error names the role and the namespace; a connection error does not.

Two timings explain most confusion here. The Secret is rewritten on the `ExternalSecret` refresh
interval, and the kubelet updates the mounted files on its own period, which together came to about
40 seconds in this deployment. A Secret consumed as environment variables does not update at all until
the pod restarts.

### OpenBao is unreachable from outside

Work inward: the host port mapping, then the node port and its endpoints, then the `openbao-active`
label, then pod health, then the seal state, then PostgreSQL.

    docker port openbao-local-control-plane
    kubectl --context kind-openbao-local -n openbao get endpointslice -l kubernetes.io/service-name=openbao-external

When sampling endpoints during a failure, filter on `.conditions.ready`. Without that filter the
output shows a dead endpoint for as long as it is listed and gives no sign of when traffic actually
stopped reaching it.

### OpenBao is sealed or restarting

Read the pod labels first: they show which servers are sealed and which is active, without a token and
without reaching the API. Then check whether the seal key Secret exists and whether the pod can read
it, then the server log for the unseal line, then the storage backend. OpenBao unseals from the stored key with no human step, so a
server that stays sealed usually means the seal key or the database is unavailable rather than that a
key is missing.

### PostgreSQL is degraded

Check the Cluster conditions, then which instances are ready and which is primary, then the operator
log. If the operator has refused to promote, the log says so explicitly. That is a durability
decision, not a failure: it means it cannot prove the surviving replica holds every acknowledged
commit.

### WAL archiving has stopped

Check `ContinuousArchiving`, then `last_archived_wal` against the current WAL position, then the
backup store's health endpoint, then the plugin sidecar log in the primary pod. Judge by movement, not
by the failure counters.

### Backups are stale

Check the Backup objects, then the `ObjectStore` recoverability window, then the `ScheduledBackup`
status. After any recovery, confirm which catalogue generation the cluster is writing to, because a
new generation starts with no base backup.

### Flux reports Ready but the object is wrong

Compare the object's `creationTimestamp` with the time the intended commit was pushed. Fields that
only apply at creation, such as a Cluster's `bootstrap` section, have no effect on an object that
already exists, so a Kustomization can be Ready and correct while the object it created is not.

## 6. Logs

OpenBao writes its server log and its audit device to stdout. Every value in the audit log is HMACed,
so it records which paths were touched and by which identity without exposing any secret.

CloudNativePG instance pods carry two containers worth of logs: PostgreSQL itself in JSON, and the
Barman plugin sidecar, which is where WAL archiving and backup failures appear. The operator's own log
carries failover and promotion decisions.

The External Secrets controller log carries authentication and provider errors, which is where a
misconfigured role or audience shows up.

The Flux controllers log reconciliation errors, and cert-manager logs issuance and renewal.

All of these go to stdout, so production would ship them to a central store. Nothing in this platform
writes logs to a file inside a container.

## 7. Limitations

No metrics are collected or retained, so every observation in this repository is a point-in-time read.
Trends, rates and historical comparison are not available.

There is no alerting. Every failure documented in this project was noticed by someone looking.

External Secrets runs one replica with leader election disabled, so a reconcile that fails has no
second instance to retry it.

The backup store exposes only a health endpoint, so its internal state, free space and object counts
are visible only from the host.

kind has no metrics-server, so pod and node resource usage is not available through Kubernetes and has
to be read from the host with `docker stats`.
