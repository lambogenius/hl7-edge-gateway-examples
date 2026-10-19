# 08 · AWS: high availability on EKS

HL7 Edge Gateway and NATS JetStream on Amazon EKS, across three availability zones. MEDITECH reaches the
gateway through an internal Network Load Balancer, over Direct Connect or a site-to-site VPN.

```
Hospital ──Direct Connect / VPN──▶ VPC ──▶ internal NLB (3 AZs, health check GET /ready):7890
                                                │
                          EKS (3 AZs)           ▼
                          hl7-edge-gateway × 2  (pods as NLB IP targets)  ──HTTPS──▶ lab API
                          NATS JetStream × 3    (one per AZ, encrypted gp3)
                          images from Amazon ECR
```

It uses the [shared Kubernetes base](../shared/kubernetes) and adds:

| File | What it adds |
|---|---|
| `cluster.yaml` | The eksctl cluster: 3 managed nodes in private subnets in 3 AZs, OIDC, the EBS CSI driver add-on, and the IAM service account for the AWS Load Balancer Controller |
| `kustomization.yaml` | An internal NLB with pod IP targets, cross-zone load balancing, and health checks on `/ready` at port 8080; the image from your ECR repository |
| `storageclass-gp3.yaml`, `nats-aws.yaml` | Encrypted gp3 disks for JetStream; `Retain`, so a deleted release does not delete queued messages |
| `setup.sh`, `teardown.sh` | Everything, in one go |

Step-by-step guide with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/example-aws>

## Before you start

- **Tools.** AWS CLI (signed in), `eksctl`, `kubectl`, `helm` 3, Docker.
- **The image.** The gateway image archive from <https://lambogenius.com/downloads>, in this folder.
- **Region.** Set it, and three of its availability zones, in `cluster.yaml` and `.env`.
- **Cost.** The EKS control plane, three `m6i.large` nodes, NAT gateways, three 20 GiB gp3 volumes and an
  NLB. Run `./teardown.sh` when you are done.

## Deploy

```sh
cp .env.example .env      # region, license, tokens, your lab API URL
./setup.sh
```

`setup.sh` does the following, and prints the NLB's DNS name for MEDITECH at the end:
1. `eksctl create cluster -f cluster.yaml` (about 20 minutes).
2. Installs the AWS Load Balancer Controller with Helm.
3. Creates the ECR repository `hl7-edge-gateway` and pushes the image.
4. Creates the gp3 StorageClass, the namespace `hl7edge`, and the Secret `hl7edge-secrets` from `.env`.
5. Installs NATS with `helm … -f ../shared/kubernetes/nats-values.yaml -f nats-aws.yaml`.
6. `kubectl apply -k .`

## Check it

```sh
kubectl -n hl7edge get pods -o wide             # 2 gateway pods and 3 NATS pods across the AZs
kubectl -n hl7edge get svc hl7edge-mllp         # EXTERNAL-IP: internal-k8s-hl7edge-...elb.<region>.amazonaws.com
kubectl -n hl7edge port-forward svc/hl7edge-admin 8080      # console at http://localhost:8080
```

In the EC2 console, open **Target groups**: the two gateway pod IPs are healthy, checked on `/ready`.

**Failover test:** delete a gateway pod, then a NATS pod (`nats-1`). Messages keep flowing, and nothing is
lost.

## Production notes

- **Address.** Give MEDITECH a DNS name: a Route 53 private hosted zone record (alias) to the NLB. NLB
  addresses can change.
- **Who may connect.** Keep the NLB internal. Restrict sources with the NLB's security group
  (`service.beta.kubernetes.io/aws-load-balancer-security-groups`), and in the gateway with `allow_from`.
- **Secrets.** Rather than `.env`, keep them in AWS Secrets Manager and sync them with the External Secrets
  Operator or the Secrets Store CSI driver.
- **Monitoring.** Use Container Insights or Amazon Managed Prometheus, and alert on `hl7edge_queue_depth` and
  `hl7edge_dead_letters`.
- **Without Kubernetes.** The gateway repository also has an ECS Fargate and NLB Terraform module. It needs
  NATS running somewhere else (EC2, or Synadia Cloud) for a durable, highly available queue.

## What was tested

The Kubernetes manifests and NATS values are the [shared base](../shared/kubernetes), tested on k3s with
pod failures. This folder's kustomization renders with `kubectl kustomize`. **`setup.sh` and `cluster.yaml`
have not been run against a real AWS account yet**, so do a trial deployment in a test account first.

**Clean up:** `./teardown.sh` deletes the namespace (and with it the NLB), the cluster and the ECR repository.
The gp3 volumes are kept (`Retain`); the script says how to find them.
