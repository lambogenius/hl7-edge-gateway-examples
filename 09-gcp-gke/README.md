# 09 · Google Cloud: high availability on GKE

HL7 Edge Gateway and NATS JetStream on a regional GKE cluster, with nodes in three zones. MEDITECH reaches the
gateway through an internal passthrough Network Load Balancer, over Cloud Interconnect or Cloud VPN.

```
Hospital ──Interconnect / Cloud VPN──▶ VPC ──▶ internal passthrough NLB (regional):7890
                                                    │
                          GKE regional cluster      ▼
                          hl7-edge-gateway × 2  (zones spread)  ──HTTPS──▶ lab API
                          NATS JetStream × 3    (one per zone, pd-ssd)
                          images from Artifact Registry
```

It uses the [shared Kubernetes base](../shared/kubernetes) and adds:
- `kustomization.yaml`: the internal load balancer (`networking.gke.io/load-balancer-type: Internal`, with
  global access), `externalTrafficPolicy: Local`, and the image from your Artifact Registry.
- `nats-gcp.yaml`: SSD persistent disks (`premium-rwo`) for JetStream.
- `setup.sh` / `teardown.sh`: everything, in one go.

Step-by-step guide with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/example-gcp>

## Before you start

- **Tools.** Google Cloud CLI (`gcloud auth login`), `kubectl` with `gke-gcloud-auth-plugin`, `helm` 3,
  Docker.
- **Project.** A project with billing enabled.
- **The image.** The gateway image archive from <https://lambogenius.com/downloads>, in this folder.
- **Cost.** Three `e2-standard-2` nodes (one per zone), three 20 GiB SSD persistent disks, an internal load
  balancer, and Artifact Registry storage. Run `./teardown.sh` when you are done.

## Deploy

```sh
cp .env.example .env      # project, region, license, tokens, your lab API URL
./setup.sh
```

`setup.sh` does the following, and prints MEDITECH's address at the end:
1. Enables the GKE and Artifact Registry APIs.
2. Creates the Docker repository `hl7edge`.
3. Creates the regional cluster: one node per zone, VPC-native, Workload Identity, Shielded nodes.
4. Pushes the image.
5. Creates the namespace and the Secret from `.env`.
6. Installs NATS with Helm, then `kubectl apply -k .`

## Check it

```sh
kubectl -n hl7edge get pods -o wide             # 2 gateway pods and 3 NATS pods, in different zones
kubectl -n hl7edge get svc hl7edge-mllp         # EXTERNAL-IP is a private VPC address
kubectl -n hl7edge port-forward svc/hl7edge-admin 8080      # console at http://localhost:8080
```

**Failover test:** delete a gateway pod, then a NATS pod (`nats-1`). Messages keep flowing, and nothing is lost.

## Production notes

- **Address.** Reserve a static internal IP (`gcloud compute addresses create … --subnet … --addresses …`)
  and set it as the Service's `loadBalancerIP`, so MEDITECH's configuration never changes.
- **Who may connect.** Allow TCP 7890 from the hospital's ranges only, with a VPC firewall rule. Also use
  `allow_from` in the gateway.
- **Secrets.** Keep them in Secret Manager, with the Secret Manager add-on for GKE or the External Secrets
  Operator.
- **Monitoring.** Use Google Cloud Managed Service for Prometheus (a `PodMonitoring` on port 8080), and
  alert on `hl7edge_queue_depth` and `hl7edge_dead_letters`.

## What was tested

The Kubernetes manifests and NATS values are the [shared base](../shared/kubernetes), tested on k3s with
pod failures. This folder's kustomization renders with `kubectl kustomize`. **`setup.sh` has not been run
against a real Google Cloud project yet**, so do a trial deployment in a test project first.

**Clean up:** `./teardown.sh` deletes the namespace (and the load balancer), the cluster and the repository.
