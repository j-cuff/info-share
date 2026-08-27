##############################################################################
# example-palette-cluster-profile.tf
#
# A minimal, sanitized Terraform example showing how to:
#   1. Authenticate to a self-hosted Palette (VerteX or Palette) API.
#   2. Author a Cluster Profile made of Palette-managed packs (OS, K8s, CNI,
#      CSI) plus an ADD-MANIFEST layer that patches CoreDNS on every tenant
#      cluster — the split-horizon DNS pattern documented in this folder's
#      README.
#
# What this is NOT:
#   - Not a working plan out of the box. `terraform apply` will fail until
#     every placeholder ("<...>") is filled in AND the pack names/versions
#     match what your Palette pack registry actually has.
#   - Not an infra provisioner. No cluster resource is defined here; this
#     file only creates a *profile*. Attaching the profile to a cluster is
#     a separate Terraform resource (`spectrocloud_cluster_eks`, ...) or a
#     UI/API step.
#
# Provider docs: https://registry.terraform.io/providers/spectrocloud/spectrocloud/latest/docs
##############################################################################

terraform {
  required_providers {
    spectrocloud = {
      source  = "spectrocloud/spectrocloud"
      version = ">= 0.1"
    }
  }
}

# ─── Authenticate to Palette ─────────────────────────────────────────────────
# host is the API hostname of your self-hosted Palette / VerteX mgmt-plane.
# api_key is a Tenant Console → user menu → My API Keys value.
# Self-hosted installs commonly use a self-signed cert — without the
# `ignore_insecure_tls_error` flag the provider retries TLS ~10× per call
# and a plan can hang for hours before failing.
provider "spectrocloud" {
  host                      = var.sc_host        # e.g. "palette.example.com"
  api_key                   = var.sc_api_key
  project_name              = var.sc_project_name # "Default" for the default project
  ignore_insecure_tls_error = true
}

# ─── Look up the packs to include in the profile ─────────────────────────────
# The pack `name` and `version` MUST match what's in your Palette pack
# registry. Run `curl -n https://<host>/v1/packs?filters=type=spectro` or
# browse the Palette UI to confirm what's available.

data "spectrocloud_pack" "os" {
  name    = "amazon-linux-eks"
  version = "1.0.0"
}

data "spectrocloud_pack" "k8s" {
  name    = "kubernetes-eks"
  version = var.k8s_version # e.g. "1.30" — check registry for what's mirrored
}

# Calico is used when you need NetworkPolicy semantics. Switch to
# `cni-aws-vpc-eks-helm` if you need pods to get VPC-native IPs (required
# when the EKS control plane must reach pod IPs — e.g. for admission
# webhooks that don't run hostNetwork).
data "spectrocloud_pack" "cni" {
  name    = "cni-calico"
  version = "3.27.2"
}

# CSI is REQUIRED for EKS infra profiles — Palette blocks the profile
# otherwise. csi-aws-ebs provisions the default block SC.
data "spectrocloud_pack" "csi" {
  name    = "csi-aws-ebs"
  version = "1.30.0"
}

# ─── The profile itself ──────────────────────────────────────────────────────
resource "spectrocloud_cluster_profile" "example" {
  name        = var.profile_name         # e.g. "acme-tenant-baseline"
  description = "Baseline tenant profile: OS + K8s + Calico + EBS + CoreDNS phone-home."
  cloud       = "eks"
  type        = "cluster"

  pack {
    name   = data.spectrocloud_pack.os.name
    tag    = "1.0.0"
    uid    = data.spectrocloud_pack.os.id
    values = data.spectrocloud_pack.os.values
  }

  pack {
    name   = data.spectrocloud_pack.k8s.name
    tag    = "${var.k8s_version}.x"
    uid    = data.spectrocloud_pack.k8s.id
    values = data.spectrocloud_pack.k8s.values
  }

  pack {
    name   = data.spectrocloud_pack.cni.name
    tag    = "3.27.x"
    uid    = data.spectrocloud_pack.cni.id
    values = data.spectrocloud_pack.cni.values
  }

  pack {
    name   = data.spectrocloud_pack.csi.name
    tag    = "1.30.x"
    uid    = data.spectrocloud_pack.csi.id
    values = data.spectrocloud_pack.csi.values
  }

  # CoreDNS phone-home layer — patches kube-system/coredns on the tenant
  # cluster so its cluster-management-agent can reach the Palette mgmt-plane
  # rootDomain even when public DNS won't resolve it (fake .local domains)
  # OR when a CASB/SASE (Netskope, Zscaler, Prisma Access, iBoss, ...) is
  # intercepting HTTPS to the mgmt-plane's public IP. See this folder's
  # README.md for the AWS-native alternatives (Route53 private hosted zone,
  # VPC peering, etc.) that eliminate the need for this layer.
  #
  # ONLY emitted when var.mgmt_target_ip is set — leave the variable empty
  # for real-DNS installs and this layer disappears from the profile.
  dynamic "pack" {
    for_each = var.mgmt_target_ip != "" ? [1] : []
    content {
      name = "coredns-phonehome"
      type = "manifest"
      manifest {
        name = "coredns-phonehome-patcher"
        # Substitute the two placeholders in coredns-phonehome.yaml with
        # this profile's values. Keep the file adjacent to this .tf file
        # (same directory) so the path resolves cleanly.
        content = replace(
          replace(
            file("${path.module}/coredns-phonehome.yaml"),
            "<TARGET_IP>", var.mgmt_target_ip
          ),
          "<ROOT_DOMAIN>",
          var.mgmt_root_domain != "" ? var.mgmt_root_domain : var.sc_host
        )
      }
    }
  }
}

# ─── Variables ───────────────────────────────────────────────────────────────
# Fill these in a terraform.tfvars file. NEVER commit terraform.tfvars —
# add it to .gitignore. Use TF_VAR_ env vars or a secrets manager for
# sc_api_key.

variable "sc_host" {
  type        = string
  description = "Palette / VerteX API hostname (e.g. palette.example.com)."
}

variable "sc_api_key" {
  type        = string
  sensitive   = true
  description = "Palette API key from Tenant Console."
}

variable "sc_project_name" {
  type        = string
  default     = "Default"
  description = "Palette project to author the profile in."
}

variable "profile_name" {
  type        = string
  description = "Name for the cluster profile (visible in the Palette UI)."
}

variable "k8s_version" {
  type        = string
  default     = "1.30"
  description = "Kubernetes version to pin the k8s pack to."
}

# ─── CoreDNS phone-home layer variables ──────────────────────────────────────
# Leave BOTH empty in production installs that have working DNS. Set them
# ONLY when the tenant cluster's DNS path to the mgmt-plane rootDomain is
# broken or intercepted (see README.md — the "Do we actually need this
# layer?" section walks through the AWS-native alternatives).
variable "mgmt_target_ip" {
  type        = string
  default     = ""
  description = <<-EOT
    IP the tenant cluster's CoreDNS should resolve the Palette mgmt-plane
    rootDomain to. Either the mgmt-plane's public ingress ELB IP OR a
    private/peered IP. LEAVE EMPTY to skip the CoreDNS phone-home layer.
    AWS Classic ELB IPs rotate — prefer a stable NAT EIP, Route53 alias,
    or peered private IP.
  EOT
}

variable "mgmt_root_domain" {
  type        = string
  default     = ""
  description = <<-EOT
    Hostname the CoreDNS hosts{} block resolves. Defaults to var.sc_host,
    which is almost always what you want. Only override if the mgmt-plane
    serves its API on a hostname other than the one packaged in sc_host.
  EOT
}
