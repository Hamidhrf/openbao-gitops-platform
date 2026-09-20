# ADR-001: Local runtime environment

Status: accepted (2026-09-20)

## Context

I need a multi-node Kubernetes cluster to show HA and failover. A local cluster is fine for this project.

The machine I have for it is one Ubuntu 24.04 VM (16 vCPU, 61 GiB RAM). It already runs a single-node kubeadm cluster with other workloads, and that cluster must not be touched. It uses 10.244.0.0/16 for pods and 10.96.0.0/12 for services.

## Options

- kind: Kubernetes nodes as Docker containers, node images pinned by digest, the whole cluster in one config file. Doesn't touch the existing cluster.
- k3d: similar, but k3s ships extras (Traefik, ServiceLB) that I would have to turn off.
- minikube: also supports multiple nodes. kind was built for testing Kubernetes itself and keeps the whole cluster in one file, so I went with kind.
- k3s or kubeadm directly on the VM: would clash with the existing cluster (ports 6443 and 10250, CNI, container runtime).

## Decision

- kind v0.33.0, cluster name `openbao-local`
- Kubernetes v1.36.4, node image pinned by digest:
  `kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`
- 1 control-plane node and 3 workers. Workloads run only on the workers.
- One replica per worker for each HA component (3 PostgreSQL instances, 3 OpenBao replicas). How this is enforced is decided per component.
- Pod CIDR 10.200.0.0/16 and service CIDR 10.210.0.0/16, so there is no overlap with the existing cluster.
- Separate kubeconfig (`~/.kube/openbao-local`) and project-local CLIs in `.bin/`, including kubectl v1.36.4. The host kubectl is 1.34, and kubectl only supports one minor version difference to the API server.

Why 1.36 and not 1.37: Flux 2.9 supports Kubernetes up to 1.36.

## Limitations

- All nodes run on one VM. This shows pod and node failures inside Kubernetes, not real host or zone failures.
- One control-plane node, so the control plane itself is not HA.
- kind uses node-local volumes (local-path). Data redundancy comes from PostgreSQL replication, not from the storage.
- Both clusters share one 246 GB disk. Kubelet starts deleting unused images at 85% disk usage, which is about 37 GB free here. I stop and check when free space drops below 40 GB.

## References

- https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0
- https://github.com/fluxcd/flux2/releases/tag/v2.9.0
- https://kubernetes.io/releases/version-skew-policy/
