# Production readiness

## Scope

This deployment is not production-ready as a whole. It runs on one VM, and several production concerns
are simplified on purpose so that the platform can be shown end to end on a laptop-sized machine.

The challenge asks which parts are production-ready and which are simplified for the demo. This
document is that answer in one place. The reasoning behind each line is in the ADR named beside it.

## Parts that would carry over to production

These are design decisions, not demo shortcuts. They would look the same in a real deployment.

Git is the only source of truth. Once Flux is running, everything in the cluster comes from a commit.
The only steps done by hand are the two the challenge allows: bootstrapping Flux, and installing the
age key that Flux needs before it can decrypt anything (ADR-002, ADR-003).

The layers reconcile in order. Each Flux Kustomization waits for the one before it, so a controller and
its CRDs are ready before the resources that use them (ADR-006).

The PostgreSQL high availability design. Three instances, one per worker, synchronous replication with
`dataDurability: required`, and quorum failover. If the primary is lost, the operator promotes a
replica only when it can show that replica holds every acknowledged commit. If it cannot, writes stop
rather than risking their loss. That was tested by stopping two workers (ADR-004).

Backups and restores are tested, not described. A daily base backup, continuous WAL archiving to a
store outside the cluster, a full restore, a point-in-time restore, and a complete rebuild after
deleting the cluster. Each one was run and its result written down (ADR-005, docs/backup-restore.md,
docs/disaster-recovery.md).

TLS is verified, not just enabled. OpenBao connects to PostgreSQL with `sslmode=verify-full`, so it
checks the server's name and not only that a certificate exists. A connection by IP address is refused
(ADR-007).

OpenBao initializes itself and leaves nothing behind. No root token is returned and no recovery keys
are created. Administration is a short-lived login through Kubernetes auth, and every request is
written to the audit log (ADR-008).

Secret isolation is enforced in OpenBao rather than in External Secrets. Policies are written per
calling namespace, and roles bind the service account name, its namespace and the token audience. A
namespace cannot read another namespace's path even though no policy mentions that other namespace.
Pull and push use separate path prefixes, so a sync loop cannot form (ADR-010).

Certificates are issued and renewed by cert-manager, and the database picks up a renewed certificate
without a restart (ADR-007).

Versions are pinned. Charts by exact version, and every image chosen by this project by digest
(ADR-004, ADR-009).

## What is simplified for the demo

| Area | In this demo | In production | What the simplification costs |
|---|---|---|---|
| Failure domains | Four kind nodes as containers on one VM, one control-plane node | Separate machines or zones, a highly available control plane | A node failure here is a container failure. Losing the VM loses the whole cluster, and the control plane has no redundancy (ADR-001) |
| Database storage | local-path volumes on each node | Network or replicated storage with snapshots | No storage-level redundancy. If a node is lost for good its instance stays Pending until a worker is free, and it has to be rebuilt from the primary (ADR-004) |
| Backup store | A Versity container on the same VM and disk, no versioning or object lock, reached with the store's root credential | Object storage in another site or region, object lock and lifecycle rules, an identity limited to the backup bucket | One disk failure can take the cluster and the only copy of the backups together. Anyone with the credential can delete backups. The credential exists in two encrypted files that must be rotated together (ADR-005) |
| Bootstrap credentials | A static age key on the VM and a long-lived deploy key in the cluster, both installed by hand | A KMS or HSM with workload identity, and a GitHub App or machine user issuing short-lived tokens | Neither credential expires or has versioning. Rotating the age key does not protect ciphertext already in Git history, and Secrets are not encrypted at rest in this cluster (ADR-002, ADR-003) |
| Seal and human access | The static seal key, held in Git encrypted with age, plus a local break-glass account | Auto-unseal from a KMS or HSM, and an identity provider for the human path | Someone holding an age identity and a database backup has everything needed to read the data. With Shamir they would not. This is the price paid for unsealing without a human (ADR-008) |
| Trust and certificates | One private CA for the database and OpenBao, with the CA read out of a leaf certificate's Secret, and no rollover ever tested | Separate intermediates, a trust bundle distributed on purpose, and a rehearsed root rollover | A root change would need a planned rollover this setup has never practised. Clients must be given the CA by hand, because it is not publicly trusted (ADR-007) |
| Exposure | One NodePort mapped to `127.0.0.1` on the control-plane node | A load balancer or gateway in front of every node, a real DNS name, a certificate from a public issuer, and a network policy | If the control-plane container stops, the endpoint is gone even though OpenBao is healthy. After a node is killed the Service keeps selecting the dead server for about 50 seconds (ADR-011) |
| Day-2 configuration and ESO | A Job that runs when its script changes; the ESO controller can read Secrets across the cluster | Continuous reconciliation, or a configuration controller with its own resources | Configuration changed by hand inside OpenBao stays changed until the next run. The controller's cluster-wide read of Secrets is how ESO works and is not narrowed here (ADR-010) |
| Observability | Metrics are exposed by every component, but nothing collects, stores or alerts on them | Prometheus, alert rules, central logs, and probes from outside the cluster | Every problem in this project was found by someone looking. There is no history, so trends and rates are not available (docs/observability.md) |

## What I would change before production

Some of these would happen at the same time in a real project. This is the order if only one could be
done first.

1. Remove the single-host failure domain, and start with the backups. Today one disk failure takes
   Kubernetes, every database volume and the only copy of the backups in one event. Everything else on
   this list assumes the backups survive, so this comes first. Off-host or off-site storage with
   object lock, then separate machines for the nodes and a highly available control plane.

2. Move the seal and the bootstrap credentials to managed key systems. Auto-unseal from a KMS or an
   HSM, workload identity instead of static keys where the platform allows it, an identity provider
   for the human break-glass path, and an identity for the backup store that can only write to the
   backup bucket.

3. Give the platform real PKI and real exposure. Separate intermediates for the database and OpenBao,
   a trust bundle distributed deliberately with a rehearsed rollover, a load balancer or gateway, a
   name in DNS, a certificate from a public issuer, and a network policy limiting who can reach the
   endpoint.

4. Deploy the observability plan before real traffic arrives. Metrics collection, the alerts in
   docs/observability.md, central log storage, and health probes from outside the cluster.

5. Automate the lifecycle. Seal key and credential rotation, the certificate reload step that 2.6.x
   still needs, restore tests on a schedule rather than by hand, and a periodic run of the day-2
   configuration so that drift is corrected instead of waiting for someone to change the script.
