# ADR-006: Repository layout and namespaces

Status: accepted (2026-09-22). Extended by ADR-007, which gives `infrastructure/configs/` its content, and by ADR-010, which adds External Secrets Operator to the controllers and the `openbao-config` Kustomization between `openbao` and `apps`.

## Context

Flux is bootstrapped at `clusters/local`, and the repository so far holds only the generated `flux-system` directory, the kind configuration and the host scripts. The next phase adds cert-manager, CloudNativePG, the Barman Cloud Plugin, a PostgreSQL cluster and its backup objects, and after that OpenBao, External Secrets Operator and a demo workload. I need a layout and a namespace plan before any of those manifests exist, because both are awkward to change once Flux owns the objects.

The namespaces are not only a naming question. The Barman Cloud Plugin resolves `barmanObjectName` only in the namespace of the PostgreSQL cluster that references it, so the `ObjectStore`, the backup store credential and the `endpointCA` certificate all have to live in that namespace. CloudNativePG also creates a `<cluster>-ca` Secret there, holding `ca.crt` and `ca.key`.

## Options

Layout:

- Everything under `clusters/local/`. Fewest files, but the cluster's Flux wiring and the manifests it points at sit in the same place.
- The upstream Flux monorepo layout: `infrastructure/controllers`, `infrastructure/configs` and `apps/`. The split between controllers and configs exists so that controllers and their CRDs are ready before the custom resources that need them.
- The same layout plus a `platform/` directory for PostgreSQL and OpenBao.

Helm releases:

- Chart source and `HelmRelease` in `flux-system`, with `targetNamespace` set to the component's namespace.
- Namespace, chart source and `HelmRelease` together in the component's own namespace.

PostgreSQL and OpenBao:

- One namespace for both. OpenBao then reads `ca.crt` straight from the `<cluster>-ca` Secret, and also sits next to `ca.key` and the backup store credential.
- One namespace each.

## Decision

Three top-level directories next to the cluster directory:

    clusters/local/     one Flux Kustomization per file, next to the generated flux-system
    infrastructure/
        controllers/    cert-manager, CloudNativePG, Barman Cloud Plugin
        configs/        cluster-wide configuration that depends on those CRDs
    platform/
        database/       PostgreSQL cluster, object store, backup objects
        openbao/        OpenBao
    apps/               demo workload

I keep `platform/` separate from `infrastructure/` because PostgreSQL and OpenBao are the platform this repository delivers, while cert-manager, CloudNativePG and External Secrets Operator are what it needs to run.

The Flux Kustomizations all live in `flux-system` and reconcile in one chain:

    infra-controllers -> infra-configs -> database -> openbao -> apps

Each one sets `prune: true` and `wait: true` and depends on the one before it, so a step starts only after everything the previous step applied is healthy. That is what registers the CRDs before the resources that use them. A Kustomization is added when its directory gets content, not before. SOPS decryption is configured only on the Kustomizations that apply encrypted files.

Every chart gets its namespace, its chart source and its `HelmRelease` in one directory and one namespace: cert-manager in `cert-manager`, CloudNativePG and the Barman Cloud Plugin in `cnpg-system`, which is where the plugin has to run because it extends the operator. Helm's release storage defaults to the namespace of the `HelmRelease`, so keeping the release next to its workload also keeps `helm list -n <namespace>` truthful.

PostgreSQL runs in `database` and OpenBao will run in `openbao`. The backup store credential and the `endpointCA` Secret go into `database`, because that is where the `ObjectStore` has to be. This keeps the credential that administers the whole backup store, the CloudNativePG CA private key and the replication keys out of the namespace that runs the secrets manager. From the database side, OpenBao gets the database password and the public CA certificate and nothing else.

## Limitations

- OpenBao needs the database password in its own namespace, so that one credential exists as two encrypted files with the same value, and rotating it means changing both.
- Separate namespaces leave open how OpenBao receives the PostgreSQL CA certificate. Kubernetes cannot mount a Secret across namespaces, and Flux cannot copy a Secret that the operator generates at runtime. Either the public `ca.crt` is committed for the OpenBao side and refreshed whenever the operator's CA changes, or the PostgreSQL server certificate comes from a cert-manager CA that both namespaces can use. That is a TLS decision with its own ADR. ADR-007 made it and chose the second option: the PostgreSQL server certificate comes from a cert-manager CA, and OpenBao reads that CA from its own listener Secret.
- A namespace bounds who can create workloads next to which Secrets. It is not isolation. The CloudNativePG chart installs cluster-scoped CRDs and RBAC whatever namespace its release lives in, and the Flux controllers reconcile with cluster-wide permissions.
- One repository and one Git source mean that every commit reconciles every Kustomization. Flux can split a monorepo into separate artifacts, which needs an extra component; that is not worth it for a single cluster.

## References

- https://fluxcd.io/flux/guides/repository-structure/
- https://github.com/fluxcd/flux2-kustomize-helm-example
- https://fluxcd.io/flux/components/helm/helmreleases/
- https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/
- https://cloudnative-pg.io/docs/1.30/certificates/
