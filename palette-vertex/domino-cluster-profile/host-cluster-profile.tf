#############################################################################
# Palette INFRA cluster profile for a Domino host cluster (EKS / GovCloud).
# Satisfies Domino's cluster requirements: Calico (NetworkPolicy), EBS + EFS
# CSI, and the two required StorageClasses (dominodisk, dominoshared).
#
# Confirm pack versions against your Palette pack registry before apply
# (data.spectrocloud_pack lookups will fail if name/version don't match).
# The `version` strings below are examples — swap them for whatever your
# registry actually has mirrored.
#############################################################################

data "spectrocloud_pack" "os" {
  name    = "amazon-linux-eks"
  version = "1.0.0" # only 1.0.0 in mirror
}
data "spectrocloud_pack" "k8s" {
  name    = "kubernetes-eks"
  version = var.k8s_version # mirror has 1.24,1.25,1.28,1.29,1.30,1.31,1.32
}
# Calico for Kubernetes NetworkPolicy (Domino requirement)
data "spectrocloud_pack" "cni" {
  name    = "cni-calico"
  version = "3.27.2" # 3.27.0 NOT in mirror; available 3.27.2, 3.28.x, 3.29.x, 3.30.x
}
# Storage/CSI layer is REQUIRED by Palette for EKS infra profiles (cannot be omitted).
# csi-aws-ebs → EBS + gp3 default SC (serves dominodisk / block / RWO).
data "spectrocloud_pack" "csi_ebs" {
  name    = "csi-aws-ebs"
  version = "1.30.0" # mirror has 1.17,1.26.1,1.28,1.30,1.41,1.43,1.46
}
# EFS (dominoshared/RWX): deployed as a MANIFEST ADDON layer, NOT a 2nd csi-layer pack.
# LEARNING (2026-07-10, domino-efs): Palette allows ONE pack per core layer — csi-aws-ebs and
# csi-aws-efs both self-declare layer="csi", so the 2nd one sticks in "WaitingForOtherLayers"
# forever (EBS installs, EFS never does). The provider pack block has no layer override. Fix =
# add EFS as a type="manifest" pack (addon layer) using storage-layer-efs-csi-manifest.yaml (which
# uses the already-ECR-mirrored Domino EFS images → also avoids the non-FIPS us-docker pull).
# dominoshared (RWX/EFS): the csi-aws-efs PACK is absent from the mirror, so deploy Domino's
# OWN EFS CSI driver (mirrored images) as an Add-Manifest layer instead — see
# storage-layer-efs-csi-manifest.yaml (add via UI, or a manifest pack block below).

resource "spectrocloud_cluster_profile" "domino_host" {
  name        = "domino-efs-infra"
  description = "Infra profile for the domino-efs cluster (Calico + EBS/dominodisk + EFS/dominoshared); Domino added separately"
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
  # Required Storage layer (EBS). v2: define the `dominodisk` SC HERE (in the pack values) so the
  # profile creates it on Palette's own ebs.csi.aws.com — Domino then consumes it with
  # storage_classes.block.create=false (NO duplicate Domino EBS-CSI driver, NO hand-created SC).
  # Also pin the CSI controller to an IRSA role: Palette RECONCILES AWAY managed-policy attachments on
  # the nodegroup role (spectro__ownerUid-tagged), so node-role creds for CreateVolume don't stick.
  # IRSA on ebs-csi-controller-sa is reconcile-proof (it's a pack value Palette re-applies).
  pack {
    name = data.spectrocloud_pack.csi_ebs.name
    tag  = "1.30.x"
    uid  = data.spectrocloud_pack.csi_ebs.id
    # Palette REPLACES pack values (no merge) — so we supply the FULL pack values with two edits
    # (dominodisk SC + IRSA SA annotation) from the real deployed values. See csi-aws-ebs-values.yaml.tmpl.
    # NOTE: this file is FIPS (gcr.io/spectro-images-fips) → no non-FIPS toggle needed for this layer.
    values = templatefile("${path.module}/csi-aws-ebs-values.yaml.tmpl", {
      ebs_csi_irsa_role_arn = var.ebs_csi_irsa_role_arn
    })
  }
  # EFS storage layer (v3, 2026-07-10): the profile now OWNS the EFS driver + `dominoshared` SC via the
  # csi-aws-efs pack (symmetric with EBS/dominodisk). Domino sets storage_classes.shared.create=false.
  # Values from the .tmpl (dominoshared non-default SC + regional STS + IRSA) — templatefile fills the
  # EFS id + IRSA role. NOTE: non-FIPS lineage (us-docker.pkg.dev) → the mgmt plane needs the
  # "allow non-FIPS packages" toggle ON, and the 4 EFS images mirrored (imageswap). If that toggle is
  # off, drop this block and fall back to Domino's own EFS driver (storage_classes.shared.create=true).
  pack {
    name = "efs-storage"
    type = "manifest"
    manifest {
      name = "dominoshared-efs"
      # read the manifest + inject the EFS id (replace the Palette macro; file() avoids ${}/$() clashes)
      content = replace(file("${path.module}/storage-layer-efs-csi-manifest.yaml"), "{{.spectro.var.STORAGE_EFS_ID}}", var.efs_file_system_id)
    }
  }

  # CoreDNS phone-home layer — patches kube-system/coredns so CMA on this tenant cluster can reach the
  # Palette mgmt-plane rootDomain even when public DNS doesn't resolve it (fake .local) or when a CASB
  # (Netskope/Zscaler/etc.) is intercepting HTTPS to the public ELB IP. See coredns-phonehome-manifest.yaml
  # for the mechanism (idempotent Job that inserts a `hosts { }` block into the Corefile).
  # SKIPPED WHEN var.mgmt_elb_ip == "" — profile is unchanged, matches non-CASB / real-DNS installs.
  # See DOMINO-ADDON-LAYERS.md "CoreDNS phone-home layer" for when to enable and rotation caveats.
  # Related: SUS-1958 (chart-side gap the tenant-side workaround is closing).
  dynamic "pack" {
    for_each = var.mgmt_elb_ip != "" ? [1] : []
    content {
      name = "coredns-phonehome"
      type = "manifest"
      manifest {
        name = "coredns-phonehome-patcher"
        # replace both Palette-style profile variable placeholders at TF-apply time.
        # mgmt_rootdomain defaults to sc_host (the Palette API host) — the usual case.
        content = replace(
          replace(
            file("${path.module}/coredns-phonehome-manifest.yaml"),
            "{{.spectro.var.MGMT_ELB_IP}}", var.mgmt_elb_ip
          ),
          "{{.spectro.var.MGMT_ROOTDOMAIN}}",
          var.mgmt_rootdomain != "" ? var.mgmt_rootdomain : var.sc_host
        )
      }
    }
  }
}
