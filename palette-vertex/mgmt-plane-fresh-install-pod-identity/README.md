# Palette VerteX mgmt-plane on AWS — fresh install with EKS Pod Identity

**Purpose:** a shared reference for planning a fresh Palette VerteX
management-plane deployment into AWS EKS where every AWS API call from a
Palette pod uses **EKS Pod Identity** — no static IAM keys stored in
Kubernetes, no long-lived credentials to rotate, no in-tree node-role
permissions that get reconciled away.

## What you get with this pattern

- **No static AWS credentials** anywhere in the mgmt-plane. Every AWS call is
  a temporary STS credential exchanged through the Pod Identity Agent.
- **Short-lived credentials, automatically refreshed.** The AWS SDK inside each
  Palette pod handles the exchange — no rotation window to schedule.
- **One IAM role per component.** Blast radius stays tight; a compromise of
  one pod doesn't grant the perms another pod uses.
- **A clear auth story for auditors.** Every component's AWS access is a
  named Association linking a Kubernetes ServiceAccount to a specific IAM
  role in your account.

## The three artifacts in this folder

| File | Purpose |
|---|---|
| `arch-diagram.md` | Two Mermaid diagrams: the mgmt-plane at rest (AWS auth for every AWS-facing pod) and the workload-cluster provisioning path. Renders directly in GitHub. Bring to design reviews. |
| `component-inventory.md` | A per-component table naming each AWS-facing pod, its ServiceAccount, the AWS endpoints it calls, the IAM permissions it needs, and the auth mechanism. Basis for security-team review and the IAM role definitions. |
| `preflight-checklist.md` | The list of facts + decisions your team needs to have settled before the install can start. Send this ahead of the working session. |
| `values-pod-identity.yaml.tmpl` | The Helm chart values overlay that names the ServiceAccounts the Pod Identity Associations target. Apply on top of your environment's `values.yaml` at `helm install` time. |

## When this pattern is a fit

- **AWS commercial or GovCloud, current-generation EKS** (K8s 1.28+
  recommended). EKS Pod Identity was introduced in 2023 and is fully
  supported by AWS on both partitions.
- **Your platform team is comfortable with managed EKS addons and IAM roles
  with `pods.eks.amazonaws.com` trust policies.** Pod Identity uses a
  different trust model than IRSA (`oidc.eks.<region>.amazonaws.com` /
  `sts:AssumeRoleWithWebIdentity`); both work, Pod Identity is newer and
  cleaner.
- **You want the management-plane to be able to provision workload clusters
  under itself using Pod Identity too** (not just as an internal
  optimization). See the second Mermaid diagram — the `capa-controller-manager`
  service account is one of the Pod Identity Association targets, so
  workload provisioning inherits the same "no static keys" story.

## When this pattern is NOT a fit — use the fallback

- **Older EKS versions or clusters without the Pod Identity Agent addon
  available.** Fall back to IRSA (works on any EKS with an OIDC provider).
- **Air-gap environments with no ability to install AWS managed addons.**
  Fall back to static IAM user credentials stored as a Kubernetes Secret
  (`credentialType: secret` on the cloud account). Simplest, works
  everywhere; long-lived keys need to be rotated on your own schedule.
- **Cross-account STS assume-role patterns on AWS GovCloud.** There's a
  current product-side gap that blocks `credentialType: sts` on GovCloud
  during initial install; either use Pod Identity (this pattern) or static
  credentials until the gap is closed.

## The phased order — same as any customer engagement

The chart install fails silently in interesting ways if the IAM plumbing
isn't ready first. This is why we ask the phasing questions in the
preflight checklist BEFORE we start.

1. **Prereqs signed off.** From `preflight-checklist.md`. Nothing starts
   without these.
2. **EKS mgmt cluster provisioned.** Bare, no addons yet.
3. **Pod Identity Agent addon + IAM roles + Associations created.** All
   three Palette IAM roles (naming convention: `SpectroCloudPaletteRole`,
   `SpectroCloudHubbleRole`, `SpectroCloudIdentityRole`) plus the addon
   Associations for standard EKS addons (VPC CNI, EBS CSI, AWS Load Balancer
   Controller). Terraform for this is available; see the sibling
   engineering-facing runbook (link at the bottom of this file).
4. **Cluster addons installed.** VPC CNI, EBS CSI, AWS Load Balancer
   Controller. Each has its own Pod Identity Association.
5. **`spectro-mgmt-plane` chart installed with the values overlay
   (`values-pod-identity.yaml.tmpl`).** First-boot pods pick up Pod Identity
   env vars automatically because the Associations already exist.
6. **Verification pass.** Every AWS-facing pod has Pod Identity env vars;
   each can obtain temp credentials via the local agent; the load balancer
   comes up healthy; MongoDB replica set is up.
7. **Cloud account registration in the Tenant Console.**
   `credentialType: pod-identity`, ARN of the CAPA role.
8. **Workload cluster smoke test.** Provisioning end-to-end proves the
   whole chain.

## The failure modes we plan around

Two classes of failure that this pattern removes, one that it doesn't:

- **12-hour ECR token rot (removed).** Static ECR authentication tokens are
  short-lived — under a static-secret model, an in-cluster `dockerconfigjson`
  is stale in 12 hours and the next pack sync or image pull fails silently.
  Pod Identity eliminates this by having the AWS SDK request fresh tokens
  every time.
- **Node-role permission drift (removed).** In Palette-managed clusters, IAM
  policies attached to node roles get reconciled off within minutes.
  Anything relying on node-role permissions (in-tree ECR credential provider,
  legacy EBS-CSI patterns) is fragile. Pod Identity uses ServiceAccount →
  Role Associations, which live outside that reconciliation loop.
- **Cross-cluster and cross-account paths (NOT removed).** Pod Identity is
  in-cluster only. If a Palette pod needs to reach an AWS account other than
  the one hosting the mgmt cluster, that's still a role-assumption problem
  that Pod Identity doesn't solve on its own. Use `iam:AssumeRole` from
  within the Pod-Identity-granted role to jump.

## Chart-native components that stay on static ECR credentials

The `spectro-mgmt-plane` chart today uses `config.ociImageRegistry.username`
and `config.ociImageRegistry.password` to configure ECR access for the
components that pull packs and manage images (`specman`, `configserver`,
`imageswap`). This is a chart-owned pattern that predates Pod Identity;
moving it to Pod Identity is a chart-level change beyond the scope of this
runbook.

Practically, this means the customer's ECR credentials for that path should
be a long-lived IAM user, not a short-lived ECR token. Rotate those on your
own schedule (annually or per your policy).

## Where does this fit with the other planning documents in this folder set?

- `../dns-split-horizon/` — the DNS + CASB preflight for whether workload
  clusters can reach the mgmt-plane. Independent of the Pod Identity
  decision — both need to be answered.
- `../domino-cluster-profile/` — the Palette cluster profile for provisioning
  a Domino EKS workload cluster. That profile assumes the mgmt-plane already
  works and can call AWS to provision.
- `../mgmt-plane-lb-migration/` — the AWS Load Balancer type choice
  (Classic ELB vs. public NLB vs. internal NLB). Related but separate: even
  a fresh install using Pod Identity still needs to pick a LB shape.

## Companion engineering-facing runbook

This customer-facing pack summarizes the pattern and the decisions. The
step-by-step operational runbook with actual `aws`/`kubectl`/`helm`
commands, preflight and postflight scripts, and Terraform for the IAM
roles and Associations lives in the `vertex-goods` engineering repository
under `mgmt-plane-fresh-install-pod-identity/` and the sibling
`create-vertex-pod-identity-roles.sh`. Ask your Spectro Cloud contact for
access if you'd like to review it before the working session.
