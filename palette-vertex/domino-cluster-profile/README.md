# Palette / VerteX cluster profile for Domino Data Lab on EKS

A tested, working **Palette cluster profile** that provisions the EKS host
cluster Domino Data Lab installs onto. Authored via Terraform against the
Palette API; portable across commercial AWS and AWS GovCloud partitions.

## What this profile gives you

A single Palette **infra cluster profile** (`spectrocloud_cluster_profile` of
type `cluster`, cloud `eks`) with these layers, in order:

| Layer | Pack | Why it's there |
|---|---|---|
| **OS** | `amazon-linux-eks` | AL2 for EKS worker AMIs |
| **Kubernetes** | `kubernetes-eks` | EKS control plane + kubelet |
| **CNI** | `cni-calico` | Domino requires NetworkPolicy semantics; Calico is the safest bet |
| **Storage (EBS)** | `csi-aws-ebs` + custom values | Creates the `dominodisk` StorageClass Domino needs for RWO/block. Pinned to an IRSA role for the EBS CSI controller (reconcile-proof — see below) |
| **Storage (EFS)** | Add-Manifest layer | Deploys Domino's own AWS EFS CSI driver + the `dominoshared` StorageClass. Uses ECR-mirrored images. Reason for the Add-Manifest hack is documented in `host-cluster-profile.tf` |
| **CoreDNS phone-home** (optional) | Add-Manifest layer | Patches `kube-system/coredns` so the tenant cluster's Palette agent can reach the mgmt-plane when public DNS or a CASB is in the way. See [../dns-split-horizon/README.md](../dns-split-horizon/README.md) for the decision matrix — prefer AWS-native alternatives where possible |

Domino itself is installed **separately** by Domino's `ddlctl` /
`fleetcommand-agent` — this profile only handles the *host* cluster.

## What's in this folder

| File | Purpose |
|---|---|
| `host-cluster-profile.tf` | The cluster profile resource + pack data lookups |
| `variables.tf` | All the variables the profile takes, with descriptions and defaults |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` and fill in for your environment |
| `csi-aws-ebs-values.yaml.tmpl` | Full EBS CSI pack values with the `dominodisk` StorageClass and an IRSA annotation — one placeholder (`${ebs_csi_irsa_role_arn}`) substituted by `templatefile()` at apply time |
| `csi-aws-efs-values.yaml.tmpl` | EFS CSI pack values with the `dominoshared` StorageClass, regional STS, and IRSA — kept for reference; the profile uses the raw manifest below instead because the `csi-aws-efs` pack is often absent from mirrors |
| `storage-layer-efs-csi-manifest.yaml` | The EFS CSI driver deployed as an Add-Manifest layer instead of a pack. Uses `<ECR_REGISTRY>/<DOMINO_PREFIX>/…` placeholder image paths — see "Substituting the ECR registry" below |
| `coredns-phonehome-manifest.yaml` | Optional Palette-templated CoreDNS patcher (only used when `mgmt_elb_ip != ""`) |

## Prerequisites (must be true before `terraform apply`)

1. **Palette mgmt-plane is installed and reachable.** You have an API host and
   a Tenant Console API key. If self-hosted with a self-signed cert, the
   provider uses `ignore_insecure_tls_error = true` (already set).
2. **Palette AWS Cloud Account is registered** (Tenant Console → Settings →
   Cloud Accounts). Note its name; it goes into `aws_cloud_account_name`.
3. **VPC + private subnets exist** in the target AWS account/region. Two AZs
   minimum for EKS control-plane placement. Note the IDs; they go into
   `vpc_id` and `private_az_subnets`.
4. **EC2 key pair exists** in the target AWS region. Verify with
   `aws ec2 describe-key-pairs --region <region>`.
5. **EFS filesystem provisioned** in the same VPC (EFS mount targets are
   single-VPC). Note the id; it goes into `efs_file_system_id`.
6. **IAM role for EBS CSI IRSA** created with a trust policy for
   `system:serviceaccount:kube-system:ebs-csi-controller-sa` on this cluster's
   OIDC provider, and `AmazonEBSCSIDriverPolicy` attached. Note the ARN.
7. **Palette pack registry contains the pack versions referenced in
   `host-cluster-profile.tf`.** `data "spectrocloud_pack"` will fail the plan
   if names or versions don't match your mirror. Adjust the versions to
   what's actually mirrored.
8. **ECR mirror contains the four Domino EFS CSI images** referenced in
   `storage-layer-efs-csi-manifest.yaml` (see next section).
9. **Helm v3** (not v4) on the operator workstation if you'll run any
   Palette helm commands elsewhere in the workflow.

## Substituting the ECR registry in the EFS manifest

`storage-layer-efs-csi-manifest.yaml` references six image paths using the
literal placeholders `<ECR_REGISTRY>/<DOMINO_PREFIX>/...`. Two ways to
substitute them for your environment:

**Option A — sed the file before `terraform apply` (simplest):**

```bash
sed -i.bak \
  -e 's|<ECR_REGISTRY>|<your-account>.dkr.ecr.<your-region>.amazonaws.com|g' \
  -e 's|<DOMINO_PREFIX>|domino|g' \
  storage-layer-efs-csi-manifest.yaml
```

**Option B — extend the `replace()` in `host-cluster-profile.tf`:**

Replace the `content = replace(...)` block in the `efs-storage` dynamic pack
so the two ECR placeholders also get filled from Terraform variables. This
keeps the manifest file source-of-truth clean but adds complexity to the TF.

Either way, do it before you apply the profile — a manifest with the literal
`<ECR_REGISTRY>` string will fail image pull.

## How to use

```bash
# 1. Copy the tfvars template and fill in your values
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. If needed, sed-substitute ECR paths in the EFS manifest (see above)

# 3. Initialize and plan
terraform init
terraform plan -out=domino.plan

# 4. Apply — creates the profile in Palette; does NOT provision a cluster
terraform apply domino.plan
```

The profile appears in the Palette UI under **Profiles → Infrastructure**.
Attach it to an EKS cluster via UI or via a separate Terraform resource
(`spectrocloud_cluster_eks`) — this file only creates the profile.

## Why the two "unusual" choices in this profile

### IRSA annotations on the EBS CSI controller

Palette-managed clusters reconcile the nodegroup role's managed-policy
attachments back to a declared state. If you attach ECR / EC2 permissions to
the nodegroup role out-of-band, they get stripped within minutes and CSI
starts failing on `CreateVolume` calls. Binding the perms to
`ebs-csi-controller-sa` via IRSA is reconcile-proof — the SA annotation is a
pack value Palette re-applies rather than removes. The customer-facing
consequence: you must create the IRSA role (`ebs_csi_irsa_role_arn`) yourself
before applying.

### EFS as an Add-Manifest layer, not a second CSI pack

Palette allows only one pack per core layer, and both `csi-aws-ebs` and
`csi-aws-efs` self-declare `layer=csi`. The second one sticks in
`WaitingForOtherLayers` forever. The workaround is to deploy EFS via a
type=manifest addon layer. This profile embeds Domino's own EFS CSI driver
(images pulled from your ECR mirror) so the mgmt-plane doesn't need the
non-FIPS `us-docker.pkg.dev` egress path.

## Related

- **DNS to mgmt-plane broken?** See [../dns-split-horizon/README.md](../dns-split-horizon/README.md) — preflight questions covering Route53 private hosted zones, VPC peering, PrivateLink, and Route53 Resolver endpoints. The `coredns-phonehome-manifest.yaml` in this folder is the fallback when none of those AWS-native options is available.
- **Provider docs**: https://registry.terraform.io/providers/spectrocloud/spectrocloud/latest/docs
- **Palette pack registry**: browse your Palette UI under Registries, or use `curl -n https://<sc_host>/v1/packs` to list what's available.
