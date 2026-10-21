# Shared Kubernetes base (samples 07, 08 and 09)

The same high-availability layout as [sample 05](../../05-high-availability), on Kubernetes. Samples
[07 (AKS)](../../07-azure-aks), [08 (EKS)](../../08-aws-eks) and [09 (GKE)](../../09-gcp-gke) all use it
and add only what differs per cloud:
- the cluster;
- the registry;
- the internal load balancer's annotations;
- the disk type.

```
                 internal load balancer (private IP), port 7890
                                  │
               ┌──────────────────┴──────────────────┐
               ▼                                     ▼
     hl7-edge-gateway pod (zone A)        hl7-edge-gateway pod (zone B)       Deployment, 2 replicas
               │                                     │                         stateless; active/active
               └──────────────┬──────────────────────┘
                              ▼  nats://nats:4222 (token)
        nats-0 (zone A)    nats-1 (zone B)    nats-2 (zone C)                  StatefulSet, JetStream
        disk               disk               disk                             every message on all three
```

| File | What it is |
|---|---|
| `hl7-edge-gateway.toml` | The gateway configuration, as a ConfigMap. Every pod uses it; its node ID is its pod name |
| `gateway.yaml` | Deployment (2 pods, spread across zones and nodes, non-root, read-only root filesystem); MLLP Service (`LoadBalancer`); admin Service (cluster only); PodDisruptionBudget |
| `kustomization.yaml` | The base the cloud folders build on (`kubectl apply -k`) |
| `nats-values.yaml` | Values for the official [NATS Helm chart](https://github.com/nats-io/k8s) 2.15.1: 3 pods, JetStream on persistent disks, one pod per node and spread across zones, token authentication |
| `test/run.sh` | Installs all of this on a throwaway k3s cluster in Docker and runs a failover test |
| `check.sh` | The same failover test on a real cluster, after a cloud folder's `setup.sh` (run it from that folder) |

Secrets are not in these files. Each cloud's `setup.sh` creates the Secret `hl7edge-secrets` (license, admin
token, NATS token, lab API URL and token) from its `.env`. Both NATS and the gateway read it.

**How failures are handled:**
- **A gateway pod fails** (or its node, or its zone): its readiness probe fails within about 4 s, and the
  load balancer and the Service stop sending it connections. MEDITECH reconnects to the same address and
  reaches the other pod. A message that was in flight on the failed pod is delivered by the other pod after
  `ack_wait` (30 s). Kubernetes then replaces the pod.
- **A NATS pod fails:** JetStream keeps working on the other two, and the pod comes back with its disk.

**Tested:** `test/run.sh` ran this base on k3s. It sent results through the Service, then deleted a gateway
pod and a NATS pod while sending more. All of them were delivered once each, in order. `check.sh` passed the
same test on AKS and GKE on 2026-10-21 (see [07](../../07-azure-aks) and [09](../../09-gcp-gke)).
