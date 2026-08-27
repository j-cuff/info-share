# Component inventory — mgmt-plane on EKS Pod Identity

Every mgmt-cluster component that calls AWS, in one table. Each row is one
arrow on the arch diagram (`arch-diagram.md`). Use this when deciding what to
grant and how to verify each piece independently.

## Mgmt-plane chart pods

| Component | Namespace | ServiceAccount | AWS endpoints called | Perms needed | Recommended auth | Why |
|---|---|---|---|---|---|---|
| **spectro-hubble** | `hubble-system` | `spectro-hubble` | EC2 (Describe*), EKS (Describe*), IAM (Get*, List*), KMS (Describe*, List*) | Read-only cloud account validation | **Pod Identity** → `SpectroCloudHubbleRole` | No static creds; auto-refresh |
| **palette-identity** | `palette-identity` | `palette-identity` | EKS (Pod Identity Association CRUD), EC2 (DescribeInstances), IAM (GetRole, PassRole on the CAPA role) | Manage Pod Identity Associations on workload clusters | **Pod Identity** → `SpectroCloudIdentityRole` | Enables Palette to manage Pod Identity on workload clusters it provisions |
| **capa-controller-manager** | `capa-system` | `capa-controller-manager` | EC2 (VPC/subnet/SG/NAT/IGW CRUD), EKS (CreateCluster / Nodegroup), IAM (CreateRole/AttachPolicy/PassRole), ELB (CreateLoadBalancer), autoscaling | Workload cluster provisioning | **Pod Identity** → `SpectroCloudPaletteRole` | Broadest permission surface — Pod Identity avoids the static-key blast radius here most of all |
| **specman** | (chart default) | (chart default) | ECR (BatchGetImage, GetAuthToken, GetDownloadUrlForLayer, Describe*) | Pull packs from OCI registry | **Chart values** (`config.ociImageRegistry.username/password`) | Chart-native; pattern predates Pod Identity for these components |
| **configserver** | (chart default) | (chart default) | ECR — one-shot pack-registry seeding at install | Seed pack registry docs | **Chart values** — same secret as specman | Runs once at install |
| **imageswap** | (chart default) | (chart default) | ECR (validate image-rewrite rules) | Read | **Chart values** | Same secret path as specman |
| **mongo** | (chart default) | (chart default) | — | None directly (EBS PVCs are the CSI's problem) | N/A | — |
| **auth-service** | (chart default) | (chart default) | — | None | N/A | — |

## Mgmt-cluster addons (not part of the chart but required)

| Addon | Namespace | ServiceAccount | AWS endpoints | Perms needed | Recommended auth |
|---|---|---|---|---|---|
| **eks-pod-identity-agent** | `kube-system` | (addon-managed) | STS (AssumeRoleForPodIdentity, on behalf of pods) | System-scope | Managed addon (AWS-provided) |
| **aws-node** (VPC CNI) | `kube-system` | `aws-node` | EC2 (CreateNetworkInterface, AttachNetworkInterface, AssignPrivateIpAddresses, DescribeInstances, DescribeSubnets) | ENI management for pod IPs | **Pod Identity** → VPC CNI role (`AmazonEKS_CNI_Policy`) |
| **ebs-csi-controller** | `kube-system` | `ebs-csi-controller-sa` | EC2 (Create/Attach/Detach/Describe Volume + Snapshot, CreateTags) | Provision + attach block volumes | **Pod Identity** → EBS CSI role (`AmazonEBSCSIDriverPolicy`) |
| **aws-load-balancer-controller** | `kube-system` | `aws-load-balancer-controller` | ELBv2 (CreateLoadBalancer, CreateTargetGroup, RegisterTargets, ModifyListenerAttributes), EC2 (Describe / Create SecurityGroup, DescribeSubnets, DescribeVpcs), IAM (CreateServiceLinkedRole) | NLB / ALB CRUD driven by Service and Ingress annotations | **Pod Identity** → LBC role (`AWSLoadBalancerControllerIAMPolicy`) |
| **efs-csi-controller** (optional) | `kube-system` | `efs-csi-controller-sa` | elasticfilesystem (DescribeMountTargets, DescribeFileSystems, CreateAccessPoint, DeleteAccessPoint) | EFS provisioning | **Pod Identity** → EFS CSI role (`AmazonEFSCSIDriverPolicy`) |

## Cloud Account `credentialType` — the CAPA auth surface

Palette Tenant Console → Settings → Cloud Accounts → `credentialType` decides
how the CAPA controllers (running on the mgmt cluster) get AWS credentials
when they provision workload clusters. Independent of the mgmt-plane Pod
Identity setup above, though they can share the same IAM role.

| credentialType | Mechanism | Requires | When to pick this |
|---|---|---|---|
| `pod-identity` | CAPA pod's SA has a Pod Identity Association; SDK gets temp creds via the local agent | Pod Identity Agent addon on mgmt cluster; IAM role with `pods.eks.amazonaws.com` trust; Association from `capa-controller-manager` SA to that role | **Recommended.** Fresh install, no static keys anywhere. |
| `secret` | Static IAM user access keys stored in a Kubernetes Secret in the mgmt cluster | IAM user with the CAPA perms above; long-lived AK/SK | Simplest fallback. Air-gap or environments without the Pod Identity addon. Rotate keys on your policy schedule. |
| `sts` | Source identity assumes a target role via cross-account trust + external ID | Source identity, target role, external ID | Currently has a known product-side gap on AWS GovCloud that blocks initial install. Ask your Spectro Cloud contact before considering. |

## Workload clusters (what Palette provisions)

Palette-managed workload clusters differ from the self-managed mgmt cluster
because agents on the workload cluster reconcile it back to the cluster
profile's declared state. Two consequences:

1. The Pod Identity Agent addon on a workload cluster is removed within a
   few minutes unless it's explicitly declared in the cluster profile.
2. IAM managed-policy attachments on the node group role are similarly
   reconciled off if not part of the declared state.

**Recommended workload-cluster auth pattern: IRSA on ServiceAccount
annotations.** IRSA lives outside the reconciliation loop (the SA annotation
is chart-owned), so it's stable regardless of the mgmt-plane reconciler's
behavior.

| Component | Namespace | Recommended auth | Why |
|---|---|---|---|
| `cluster-management-agent` (CMA) | `cluster-<uid>` | No AWS creds — phones home to mgmt-plane via HTTPS | — |
| `jet` | `jet-system` | No AWS creds — phones home to mgmt-plane | — |
| Workload apps needing AWS | app-specific | **IRSA** (SA annotated with `eks.amazonaws.com/role-arn`) | Reconcile-proof; SA annotation is chart-owned |
| `ebs-csi-controller` | `kube-system` | **IRSA** on `ebs-csi-controller-sa` | Same reason |
| Source-to-image builders (e.g. `kpack`) | Chart-defined | **IRSA** on the builder SA | Same reason; also avoids the short-lived ECR-token expiry issue that hits static credentials in this path |

## What "changes at each AWS endpoint" based on auth choice

For your engineering / security diagram. Each destination endpoint gets a
different arrow depending on which mechanism the source pod uses.

### To STS (all Pod Identity + IRSA flows start here)

| Auth | API call | Env vars in the pod |
|---|---|---|
| Pod Identity | `sts:AssumeRoleForPodIdentity` | `AWS_CONTAINER_CREDENTIALS_FULL_URI` → local agent, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` → projected SA token |
| IRSA | `sts:AssumeRoleWithWebIdentity` | `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` → projected SA token |
| Static AK/SK | (no STS hop) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

### To ECR

| Auth | Flow |
|---|---|
| Pod Identity | STS temp creds → `ecr:GetAuthorizationToken` → temp docker password → `ecr:BatchGetImage` |
| IRSA | Same shape as Pod Identity; only the initial STS call differs (WebIdentity vs. PodIdentity) |
| `dockerconfigjson` Secret | Pod mounts a K8s Secret with a pre-baked ECR credential; uses directly. If the credential is a short-lived ECR token it expires in ~12 hours; if a long-lived IAM user, rotate on your own schedule. This is the pattern the chart's specman / configserver / imageswap use today. |
| Node instance profile | Kubelet's ECR credential provider handles pod IMAGE PULL only; does not help in-pod SDK code. |

### To EC2 / EKS / IAM / ELB (CAPA + LBC + CSI)

| Auth | Flow |
|---|---|
| Pod Identity | STS temp creds → direct API call |
| `credentialType: secret` (static) | AK/SK loaded from mounted Secret / env → direct API call |
| `credentialType: sts` (cross-account) | Source credential → `sts:AssumeRole` cross-account → temp creds → direct API call |
