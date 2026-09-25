# ADR-011: Service exposure

Status: accepted (2026-09-25)

## Context

The challenge asks for TLS-enabled service exposure. So far OpenBao is reachable only from inside the cluster. An administrator on the VM cannot reach the API at all, and there is no external endpoint to show.

OpenBao terminates TLS itself with a certificate from the platform CA (ADR-007). It listens on 8200 for the API and on 8201 for the internal cluster port. The chart creates four Services, all ClusterIP: `openbao`, `openbao-active`, `openbao-standby` and the headless `openbao-internal`. Only the active server answers API requests. A standby redirects to the active server's `api_addr`, which is a name that only resolves inside the cluster.

The cluster is kind, on one VM. Workloads run on the three workers and the control-plane node runs nothing else.

## Options

- A node port reached through a kind `extraPortMappings` host port, with OpenBao terminating its own TLS. Nothing new to install. kind sets port mappings only at cluster creation, so this means recreating the cluster.
- An ingress controller or a Gateway with TLS passthrough. ingress-nginx is retired. A route without an implementation behind it is not a data plane, so this means installing and pinning another controller for a path that shows nothing about OpenBao that a node port does not.
- A LoadBalancer Service through MetalLB or cloud-provider-kind. Closer to production semantics, and it would not force a rebuild, but it adds a controller or a host process whose only job here is exposure, and the address it hands out lives on the Docker network.

I chose the node port. Recreating the cluster is not a cost in this case, because the rebuild was already planned as the disaster recovery rehearsal.

## Decision

A node port, through a Service I own rather than through chart values.

- `openbao-external` in the `openbao` namespace, type NodePort, port and target port 8200, node port 30820. The chart's own Services stay ClusterIP.
- The reason for owning the Service is that chart 0.29.6 renders `type: {{ .Values.server.service.type }}` into `server-service.yaml`, `server-ha-active-service.yaml` and `server-ha-standby-service.yaml`. One value, three Services. Setting NodePort through the chart would expose all three. I want one.
- The selector is the one the chart puts on `openbao-active`, including `openbao-active: "true"`. Standby pods carry that label with the value `false`, so an exact match selects the active server only.
- Port 8200 only. 8201 is the cluster port and stays internal.
- `publishNotReadyAddresses: false`. The chart sets it true on its own Services so that a sealed server stays addressable for debugging. An external client is better served by a refused connection than by a socket to a server that cannot answer.
- `externalTrafficPolicy: Cluster`. This is what lets the control-plane node forward to an endpoint on a worker. `Local` would fail here, because OpenBao never runs on the control-plane node. The client address is translated on the way through, which does not matter, because identity comes from the auth method and not from the address.
- kind maps host `127.0.0.1:8200` to container port 30820 on the control-plane node only. The container port has to equal the node port.
- The mapping is on the control-plane node so that stopping a worker during a failure test does not take the external endpoint with it.
- The listener certificate gains one name, `openbao.local.test`, resolved through `/etc/hosts` on the VM. `.test` is reserved for testing and cannot collide with a real domain.

External access is for a person: an administrator running `bao` from the VM, authenticating with the break-glass account or with a token from `kubectl create token`. Workloads never use it. They reach OpenBao inside the cluster through External Secrets.

## Limitations

- The host port is bound to 127.0.0.1. ufw is inactive on this VM, so binding to every address would put the API on the university network. Access from anywhere else is an SSH forward.
- One mapping node. If the control-plane container stops, the endpoint is gone even though OpenBao is healthy. A production cluster would put a load balancer in front of every node.
- The Service follows the active server by label, and the pod sets that label on itself. A pod that is killed cannot clear it, so the Service selects the dead leader alongside the new one until the node condition changes. Measured on 25 September 2026 with one request per second: stopping the node gracefully cost one failed request, because kubelet shut the pod down, it released the HA lock and cleared its own label before dying. Killing the node cost about 52 seconds and twelve failed requests, made up of roughly 15 seconds with no leader at all while the lock expired, then about 35 seconds where half the requests reached a pod that no longer existed. `publishNotReadyAddresses: false` does not help, because the endpoint is not marked not ready until the node condition changes, about 50 seconds after the kill. That is a shorter and different clock from the 300 second unreachable toleration that governs eviction. A client that retries sees far less than one that does not, and the `bao` CLI does not retry by default.
- The selector is copied from the chart. A chart version that renamed those labels would leave this Service selecting nothing. The chart version is pinned, so that can only happen at an upgrade.
- The certificate comes from a private CA, so every client has to be given the CA explicitly.

In production this would be a LoadBalancer Service or a Gateway with TLS passthrough, a real name in DNS, a certificate from a public issuer, and a network policy limiting who can reach the endpoint.

## References

- https://kind.sigs.k8s.io/docs/user/configuration/
- https://kubernetes.io/docs/concepts/services-networking/service/
- https://openbao.org/docs/configuration/service-registration/kubernetes/
- https://github.com/openbao/openbao-helm/releases/tag/openbao-0.29.6
- https://www.rfc-editor.org/rfc/rfc6761
