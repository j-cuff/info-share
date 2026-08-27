terraform {
  required_providers {
    spectrocloud = {
      source  = "spectrocloud/spectrocloud"
      version = ">= 0.1"
    }
  }
}

provider "spectrocloud" {
  host         = var.sc_host # your self-hosted Palette API host, e.g. palette.example.com
  api_key      = var.sc_api_key
  project_name = var.sc_project_name
  # self-hosted Palette often uses a self-signed cert ("not standards compliant");
  # without this the provider retries TLS 10x/call and the plan hangs for hours.
  ignore_insecure_tls_error = true
}

variable "sc_host" {
  type = string
}
variable "sc_api_key" {
  type      = string
  sensitive = true
}
variable "sc_project_name" {
  default = "Default"
}

variable "k8s_version" {
  default = "1.30"
}
variable "region" {
  # Set for your environment — e.g. "us-east-1", "us-gov-west-1", "us-west-2".
  type = string
}
variable "azs" {
  type = list(string)
  # e.g. ["us-east-1a", "us-east-1b"]
}
variable "vpc_id" {
  type = string
}
# Static placement into an EXISTING VPC. Map AZ -> private subnet id.
# EKS control plane needs >=2 AZs. Private subnets host the worker nodes.
# Example (fill in for your environment):
#   private_az_subnets = {
#     "us-east-1a" = "subnet-0xxxxxxxxxxxxxxxx"
#     "us-east-1b" = "subnet-0yyyyyyyyyyyyyyyy"
#   }
variable "private_az_subnets" {
  type = map(string)
}
variable "ssh_key_name" {
  type = string
}

# Static-placement reachability (see host-cluster.tf). Sandbox default = public + 0.0.0.0/0 so the mgmt
# plane can reach a standalone/unpeered VPC's EKS API. Set "private" (with a peered/shared mgmt VPC) or
# narrow public_access_cidrs for enterprise/IL.
variable "endpoint_access" {
  type    = string
  default = "public" # "public" | "private" | "private_and_public"
}
variable "public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"] # SANDBOX ONLY — restrict to a NAT egress allowlist in real environments
}
variable "aws_cloud_account_name" {
  type        = string
  description = "Name of the AWS cloud account as registered in Palette (Tenant Console -> Settings -> Cloud Accounts). For VerteX / GovCloud, this account uses partition aws-us-gov."
}

variable "enable_gpu" {
  default = false
}
variable "efs_file_system_id" {
  type    = string
  default = "" # EFS for dominoshared (RWX)
}

# IRSA role for Palette's EBS CSI controller. Palette reconciles AWAY managed-policy attachments on
# the nodegroup role in Palette-managed clusters, so node-role creds for ec2:CreateVolume don't stick
# reliably — bind the perms to the ebs-csi-controller-sa via IRSA instead (referenced in the
# csi-aws-ebs pack values). Create the role with a trust policy for
# system:serviceaccount:kube-system:ebs-csi-controller-sa on this cluster's OIDC provider, and attach
# the AmazonEBSCSIDriverPolicy managed policy. Empty string leaves the SA unannotated.
variable "ebs_csi_irsa_role_arn" {
  type    = string
  default = ""
  # e.g. arn:<partition>:iam::<account_id>:role/domino-ebs-csi
}
# IRSA role for the EFS CSI controller (phase3 EFS_CSI_IRSA_ROLE_ARN). Optional: Domino's STATIC
# dominoshared PVs don't need it; only DYNAMIC efs-ap provisioning does. Empty = no annotation.
variable "efs_csi_irsa_role_arn" {
  type    = string
  default = ""
}

# AWS account & partition — the primary per-ENVIRONMENT drivers. Supplied by the env file as
# TF_VAR_aws_account_id / TF_VAR_partition (see environments/env.template.sh). ECR derives from them.
variable "aws_account_id" {
  type    = string
  default = ""
}
variable "partition" {
  type = string
  # Set for your environment: commercial = "aws"; GovCloud = "aws-us-gov";
  # C2S / SC2S = "aws-iso" / "aws-iso-b".
  default = "aws"
}

# ECR mirror. The env file computes this from the account+region and passes TF_VAR_ecr_registry,
# so a new account just needs a new AWS_ACCOUNT_ID. locals.ecr keeps a sane fallback if used standalone.
variable "ecr_registry" {
  type    = string
  default = "" # env file sets TF_VAR_ecr_registry = <account>.dkr.ecr.<region>.amazonaws.com
}
variable "ecr_domino_prefix" {
  default = "domino"
}

# ─── CoreDNS phone-home layer (see coredns-phonehome-manifest.yaml) ────────────
# Adds a `hosts { }` block to the tenant cluster's kube-system/coredns so CMA can
# reach the Palette mgmt-plane rootDomain even when public DNS doesn't resolve it
# (fake .local) OR when a CASB (Netskope/Zscaler/etc.) is intercepting HTTPS to
# the public ELB IP. Uses the sc_host as the hostname and this variable for the IP.
# Empty string ⇒ the CoreDNS phone-home layer is SKIPPED (no manifest emitted).
# See DOMINO-ADDON-LAYERS.md "CoreDNS phone-home layer" for when to set this.
variable "mgmt_elb_ip" {
  type    = string
  default = ""
  # e.g. "1.2.3.4" — the mgmt-plane's ingress ELB IP OR a private/peered IP if
  # the tenant VPC has a routable path to the mgmt-plane.
  # NOTE: AWS Classic ELB IPs rotate — see the manifest's "ELB IP ROTATION CAVEAT"
  # section. Set this only when you have a stable target (peered private IP, NAT
  # EIP on the mgmt-plane, or a Route53 alias whose backing IP you accept managing).
  # Prefer an AWS-native DNS solution (Route53 private hosted zone associated with
  # the tenant VPC, PrivateLink, VPC peering) over this CoreDNS workaround where
  # possible — see ../dns-split-horizon/README.md.
}
# Optional override for the hostname the CoreDNS block resolves. Default falls
# back to sc_host (the Palette API host), which is almost always what you want.
# Set this if the mgmt-plane serves the API on one hostname and the workload API
# under a different subdomain that also needs override.
variable "mgmt_rootdomain" {
  type    = string
  default = ""
}

locals {
  ecr = var.ecr_registry != "" ? var.ecr_registry : "${var.aws_account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
