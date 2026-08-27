# Preflight checklist — mgmt-plane fresh install with Pod Identity

Answer / gather these before the install working session. Anything missing
becomes a blocker at the wrong moment (usually mid-install, when unwinding is
expensive).

## A. Account and network

1. **AWS account ID** for the mgmt cluster.
2. **AWS region** and **partition** (`aws` for commercial, `aws-us-gov` for
   GovCloud).
3. **VPC ID** for the mgmt cluster. Which subnets are private (workers) and
   which are public (LB)?
4. **CIDR ranges** for the VPC + subnets. We'll size the LB accordingly.
5. **AZ coverage** — ≥ 2 AZs required (the mgmt-plane runs a 3-replica
   MongoDB StatefulSet; spreading is on us if you give us the AZs).
6. **rootDomain** — the DNS name the mgmt-plane will serve on. Certificate
   plan (AWS-managed via ACM, or bring-your-own PEM?).

## B. Identity and access

7. **Operator identity** used to run the install. Needs `iam:*`, `eks:*`,
   `ec2:*` on the mgmt account. If SSO, know the assume-role name.
8. **IAM role naming convention or prefix** your org requires. The install
   creates three named roles (`SpectroCloudPaletteRole`, `SpectroCloudHubbleRole`,
   `SpectroCloudIdentityRole`) plus roles for EBS-CSI, VPC-CNI, and the AWS
   Load Balancer Controller. Any conventions we need to honor (`RBP-*`,
   `platform-*`, etc.)?
9. **Permissions-boundary policy** (if your org requires one on every new
   IAM role). Provide the ARN.
10. **KMS keys** — does your org require IAM roles to be scoped to specific
    KMS keys? If yes, provide the key ARNs the mgmt-plane can use.
11. **Cross-account requirements** — will the mgmt cluster host Palette-only
    (single-account), or will it manage workload clusters in other AWS
    accounts? If cross-account, list the target accounts + how the trust is
    established today (assume-role, PrivateLink, VPC peering).

## C. EKS cluster

12. **EKS cluster provisioning tool** — will you provision it, or would you
    like us to via Terraform? If yours: eksctl, Terraform, CloudFormation,
    CDK, in-house automation?
13. **Node group shape** — instance types, node count, disk sizes. We
    recommend ≥ 3 workers, 4vCPU / 16GiB minimum for a comfortable
    mgmt-plane footprint.
14. **Kubernetes version** — pick from the versions supported by both AWS
    EKS and the Palette chart you're installing.
15. **CNI + StorageClass** — VPC CNI (default) is expected. Default
    StorageClass for the mongo PVCs (typically `gp3` on commercial or
    `gp2`/`gp3` on GovCloud).

## D. Load balancer

16. **Public NLB or internal NLB in front of the mgmt-plane?**
    - Public NLB → simplest, mgmt-plane hostname resolves to public IPs.
    - Internal NLB → requires DNS resolution for the mgmt-plane hostname to
      work only from inside VPCs that can reach the internal LB.
    - Both → dual-listener; if this is what you want, tell us upfront.
17. **Static IPs required?** If yes, allocate Elastic IPs (public NLB) or
    reserve private IPs in the subnet CIDRs (internal NLB) ahead of time.
18. **DNS record** for the rootDomain — who owns it (Route53, external DNS,
    corporate), and what's the propagation timeline?

## E. Registry

19. **ECR mirror** — where do the mgmt-plane images live? Full registry
    hostname (e.g. `<account>.dkr.ecr.<region>.amazonaws.com`) + prefix.
20. **ECR pull credentials** — for the chart's built-in
    `config.ociImageRegistry.username/password`. We recommend a long-lived
    IAM user with `AmazonEC2ContainerRegistryReadOnly` scoped to the mgmt-plane
    repos, not a short-lived ECR token (see the README section on why).

## F. Cloud account (post-install)

21. **CAPA-facing IAM role ARN** — will use `SpectroCloudPaletteRole`
    (created by the install). You'll register this via
    Tenant Console → Settings → Cloud Accounts, `credentialType:
    pod-identity`.
22. **Workload cluster account(s)** — same account as the mgmt-plane, or
    different? (This decides whether we need cross-account role trust
    between `SpectroCloudPaletteRole` and the target accounts.)

## G. Reachability from tenant clusters to the mgmt-plane

Separate from the install itself, but blocks the workload-cluster smoke
test at the end. See the sibling `../dns-split-horizon/README.md`
questionnaire — the DNS + CASB path from tenant clusters to the mgmt-plane
needs to be sorted out too. Answer that questionnaire alongside this one.

## H. Change management

23. **Windows / freezes** we should know about — is IAM change subject to
    a review process? EKS addon installs?
24. **Testing environment first?** — install into a non-prod AWS account
    first is strongly recommended; it validates the whole chain (IAM +
    addons + chart + workload cluster provisioning) before touching
    production.
25. **Success criteria** — what does "the install is done" look like in
    your team's language? Provisioning a specific workload cluster? A
    passing set of security scans? Uptime SLO reached?

## Sending this back

Reply inline with answers, or a doc / spreadsheet — whatever is easiest.
If any answer is "unsure, let's discuss," that's a valid response and
we'll cover it in the working session.

Deliverables from us based on your answers:

- IAM role definitions matching your policy boundaries and naming
  conventions.
- Terraform (or CloudFormation, if you prefer) for Phases 2 and 3.
- A tailored `values.yaml` for your environment's ECR, DNS, and LB shape.
- A go/no-go review meeting before we run the install.
