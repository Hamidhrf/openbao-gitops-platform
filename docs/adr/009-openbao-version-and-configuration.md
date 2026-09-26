# ADR-009: OpenBao version and server configuration

Status: accepted (2026-09-24). Amends ADR-008: the audit device moves from the
`initialize` stanza to the declarative `audit` stanza.

## Context

ADR-008 settled how OpenBao seals itself, initializes itself and grants
administrative access. This decision covers the rest of the server: which
version to run, how it reaches PostgreSQL, and which addresses it binds and
advertises.

The challenge requires the PostgreSQL backend and asks for the reasoning
against OpenBao's Integrated Storage, so that answer is recorded here as well.

I ran a version gate on 24 September 2026, before pinning anything. OpenBao
v2.7.0 went GA on 23 September, v2.6.3 was released the same day, and chart
openbao-0.29.6 the same day. The static seal stayed built into the binary in
2.7.0; only the `pkcs11`, `alicloudkms`, `awskms`, `azurekeyvault`, `gcpckms`
and `ocikms` seals became plugin-only, so ADR-008 needs no change.

## Why PostgreSQL and not Integrated Storage

The challenge requires it. That is the first reason and I do not want to
present it as a free choice.

OpenBao recommends Integrated Storage for most new deployments: no external
storage system, no network hop in the write path, and fewer components to
operate and monitor. It is production ready, supports high availability, and
has its own snapshot mechanism. For a greenfield deployment of my own I would
consider it seriously.

Given the requirement, the choice pays off in two ways. The database layer
already has a tested recovery model: three CloudNativePG instances with
synchronous replication and quorum failover, daily base backups, continuous WAL
archiving to a store outside the cluster, full restore and point-in-time
restore, all exercised during the PostgreSQL phase. OpenBao inherits that
instead of adding a second persistence system with its own procedure. And the
OpenBao pods hold no durable state: they need no volumes, and a pod can be
deleted and recreated without touching the data. With Integrated Storage each
server keeps an encrypted copy of the data on its own filesystem and replicates
it over Raft.

The cost is real. PostgreSQL adds a network hop to every storage operation, a
second highly available system to operate, TLS and a credential between OpenBao
and the database, connection pool sizing, and more places to look when
something is slow. Both backends support high availability, so this is not a
choice between a weaker and a stronger one. In 2.6.x, Integrated Storage
supports standby reads and the PostgreSQL backend does not; that arrives for
PostgreSQL in 2.7.0.

Two of those costs are sharper than they look. OpenBao's availability now
includes the database's: during the disaster recovery rehearsal the OpenBao
pods crashlooped while PostgreSQL was being restored, then unsealed themselves
once it returned, with no human step. And with this backend the servers decide
which one is active through a row in `openbao_ha_locks`, not through Raft. The
active node renews that row every five seconds and it expires after fifteen
(ADR-004), so leadership is only as good as the connection to the database, and
that is why one connection is kept free for the renewal query. I did not
measure the latency the extra hop adds, so the performance side of this
trade-off is reasoned rather than measured.

## Options for the version

- Chart 0.29.6 with OpenBao 2.6.3, the pairing the chart ships and tests.
- Chart 0.29.6 with the image overridden to 2.7.0. This brings GH-3913, which
  sets the PostgreSQL transaction limit below `max_parallel` so that HA lock
  renewal can always proceed, and `tls_auto_reload`, which reloads listener
  certificates without SIGHUP. It also brings PostgreSQL standby reads, a
  behaviour change in exactly the configuration I am running, on a release one
  day old in a chart whose CI has not tested it.
- Staying on 2.6.2, which 2.6.3 supersedes as a security release.

## Decision

Chart `openbao` 0.29.6 from `https://openbao.github.io/openbao-helm`, pinned by
chart version, with the image `quay.io/openbao/openbao:2.6.3` pinned by digest.
2.7.x is the planned upgrade for GH-3913 and `tls_auto_reload` once the chart
pairs with it.

High availability with three replicas, Raft disabled, no data volume and no
audit volume, injector and CSI disabled, and the UI disabled both in the chart
and in the server configuration, because the chart's flag only governs the UI
Service. `global.tlsDisable` is false, since the listener terminates TLS.

The chart's defaults are kept where they already match the design: a required
pod anti-affinity on `kubernetes.io/hostname`, so one replica lands per worker;
`podManagementPolicy: OrderedReady`, so the first start is serialised and only
one instance runs the initialization; and `updateStrategyType: OnDelete`, so an
upgrade replaces standbys before the active node rather than failing over to an
older version.

Storage:

    storage "postgresql" {
      table                    = "openbao_kv_store"
      ha_table                 = "openbao_ha_locks"
      ha_enabled               = "true"
      max_parallel             = "16"
      transaction_max_parallel = "15"
      max_connect_retries      = 50
    }

`max_parallel` defaults to 128, which would be up to 384 connections from three
replicas against a primary whose `max_connections` is 100. Sixteen keeps the
worst case at 48. OpenBao's own design note for this backend calls 128 high for
an external database and suggests a range around 5 to 20.

`transaction_max_parallel` is a separate limit with its own default. Without
it, transactions can hold every connection in the pool and the HA lock renewal
query has none left. Setting it one below `max_parallel` reproduces by hand
what GH-3913 does in 2.7.0.

`max_connect_retries` defaults to 1. The backoff starts at 15 ms and is capped
at 5 s, so a small number of retries is worth only a fraction of a second.
Fifty gives roughly three minutes, enough to ride out a primary failover at
start-up, while a database that is genuinely unreachable still ends in a
visible crash loop.

The connection is not configured with a URL. `connection_url` is left out, and
the standard PostgreSQL environment variables are used instead: `PGHOST` is
`openbao-db-rw.database.svc`, which is the service identity proven with a
`verify-full` connection during the TLS phase, `PGSSLMODE` is `verify-full`,
and `PGSSLROOTCERT` points at the `ca.crt` that cert-manager writes into
OpenBao's own listener Secret. `PGUSER` and `PGPASSWORD` come from a copy of
the SOPS-encrypted basic-auth Secret that the database namespace already holds,
so the credential has the same shape in both namespaces and the password never
appears inside a connection string.

The listener binds `[::]:8200` and `[::]:8201` and uses a certificate issued by
the platform CA of ADR-007, with names for the `openbao` and `openbao-active`
Services in all four forms and the wildcard
`*.openbao-internal.openbao.svc.cluster.local` for the per-pod address.
`127.0.0.1` is deliberately not a name on that certificate.

`api_addr` and `cluster_addr` are set through the chart's `server.ha.apiAddr`
and `server.ha.clusterAddr`, both to the pod's own name under
`openbao-internal` on 8200 and 8201, and are not repeated in the configuration
file, so there is one source for each. They use `$(BAO_K8S_POD_NAME)` rather
than `$(HOSTNAME)`: Kubernetes expands a reference only against variables
defined earlier in the same environment list, and the chart defines `HOSTNAME`
after `BAO_API_ADDR`. Setting `apiAddr` explicitly is required rather than
cosmetic, because the chart otherwise advertises `https://$(POD_IP):8200` and
an IP address is not a name on the certificate.

`service_registration "kubernetes" {}` is enabled, together with the chart's
service discovery role and auth delegator role, which are set explicitly rather
than left to the chart's defaults. The first lets OpenBao label its own pod,
which is what the `openbao-active` Service selects; the second lets it call
TokenReview for Kubernetes auth.

The audit device is declared in the server configuration as a `file` device
writing to stdout. This amends ADR-008, which placed it in the `initialize`
stanza. API-driven creation of audit devices is disabled by default through
`unsafe_allow_api_audit_creation`, and a failed self-initialization is fatal, so
the original plan risked three servers that never start. The declarative
device is also enabled before self-initialization runs, which means the
initialization requests are themselves audited.

The first start runs at `log_level = "debug"` so that the three storage
parameters can be read back from the server's own startup log, and returns to
the default level in a following commit.

## Limitations

- `transaction_max_parallel` is parsed by the 2.6.x PostgreSQL backend but is
  not in its documented parameter list. Unknown keys in a storage stanza are
  ignored without an error, so the value is confirmed from the startup log
  rather than assumed to have taken effect.
- The connection budget of 48 against 100 is arithmetic, not a load test.
- Certificate renewal falls around day 60 of the 90-day leaf. 2.6.x has no
  `tls_auto_reload`, so a reload is an operational step that this deployment
  has not yet exercised.
- The chart hardcodes `BAO_ADDR` to `https://127.0.0.1:8200`, which has no name
  on the certificate. Commands run inside a pod must pass the pod's own address
  and the CA, or they fail hostname verification for reasons unrelated to the
  server.
- Only the active node serves requests. Standby reads are not available on this
  backend in 2.6.x.
- Debug logging is used for one start only and is not the intended steady state.

## References

- https://github.com/openbao/openbao/releases/tag/v2.7.0
- https://github.com/openbao/openbao-helm/releases/tag/openbao-0.29.6
- https://openbao.org/docs/configuration/storage/postgresql/
- https://openbao.org/docs/internals/integrated-storage/
- https://openbao.org/docs/configuration/audit/
- https://openbao.org/docs/configuration/service-registration/kubernetes/
- https://github.com/openbao/openbao/pull/3913
- https://openbao.org/community/rfcs/postgresql/
- https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/
