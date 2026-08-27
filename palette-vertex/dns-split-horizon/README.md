# Palette / VerteX + AWS — preflight for reaching the mgmt-plane from tenant clusters

**Purpose:** a short set of questions to answer *together* before we sit down,
so we can pick the right long-term pattern for reaching your self-hosted
Palette / VerteX management plane from the tenant clusters you'll be
provisioning under it in AWS. The wrong answer here doesn't cause install-time
failures — it causes tenant clusters to become silently unreachable weeks
later, usually the first time a CASB signature updates or a load-balancer IP
rotates.

## The failure we're preparing to avoid

Tenant clusters provision successfully, then never transition to `Running`
because the mgmt-plane agent on each tenant cluster
(`cluster-management-agent` / CMA) can't reach the mgmt-plane's rootDomain.
The class of problem we've most commonly seen in AWS enterprise environments
is **CASB / SASE / SSL-inspection interception**: a corporate proxy (Netskope,
Zscaler, Palo Alto Prisma Access, iBoss, Cisco Umbrella, Forcepoint, Menlo)
sits between the tenant VPC and the mgmt-plane's public IP and returns its own
HTML/redirects to CMA. Signature: CMA receives `HTTP 303` (or a `200
text/html`) from the mgmt-plane hostname, with `Server:` or `Via:` headers
naming the vendor.

Two artifacts in this folder are the *workaround* if we can't solve it at
the AWS/network layer:

| File | What it is |
|---|---|
| `coredns-phonehome.yaml` | Add-Manifest layer for a Palette cluster profile. Patches `kube-system/coredns` on the tenant cluster to resolve the mgmt-plane rootDomain to a specific IP (bypasses public DNS + CASB in one step). |
| `example-palette-cluster-profile.tf` | Minimal Terraform showing how the CoreDNS layer plugs into a cluster profile via the Palette API. |

We prefer to solve this at the AWS layer instead. The questions below decide
whether we can.

## Questions to answer before the meeting

### A. Network path — tenant clusters ↔ mgmt-plane

1. Where does the mgmt-plane live? AWS account + VPC.
2. Where do the tenant clusters live? Same account + VPC, same account
   different VPC, or different AWS account entirely?
3. If different VPCs / accounts: is there existing **VPC peering**, a
   **Transit Gateway**, or **PrivateLink** between them? Or does tenant →
   mgmt-plane traffic go out to the Internet and back in?
4. Does the mgmt-plane sit behind a **public** load balancer, an **internal**
   load balancer, or both (dual listener)? We care about which one the
   tenant clusters are meant to hit.

### B. The CASB / SSL-inspection layer

5. Which vendor is inspecting outbound HTTPS from the tenant VPCs? (Netskope,
   Zscaler, Prisma Access, iBoss, Umbrella, Forcepoint, Menlo, other.)
6. Can specific hostnames be added to a **bypass / do-not-decrypt list**?
   Who owns that config, and what's the typical turnaround for a rule change?
7. Does the CASB apply to **all** egress from the tenant VPC, or only to
   traffic that leaves through a specific NAT / proxy? (Determines whether
   private-network paths — peering, PrivateLink — sidestep it.)

### C. AWS-native DNS options we should evaluate

The CoreDNS workaround is a `kube-system` mutation on every tenant cluster.
Any of these AWS-native patterns is preferable — none of them require us to
touch tenant CoreDNS.

8. **Route53 private hosted zone associated with tenant VPCs.** Create a
   private zone for the mgmt-plane rootDomain, put an ALIAS/CNAME to the
   mgmt-plane's internal load balancer, associate the zone with every
   tenant VPC. Tenant CoreDNS resolves through VPC-provided DNS naturally,
   traffic never leaves AWS's private network, CASB never sees it. Requires:
   - Willingness to serve the mgmt-plane on an internal LB (or dual-
     listener), AND
   - Cross-account zone association if tenants are in different accounts
     (`create-vpc-association-authorization` on the zone account +
     `associate-vpc-with-hosted-zone` from the tenant account).

    → Is Route53 owned by the same team we're engaging with, or a central
       network / platform team? What's the lead time for a private-hosted-
       zone change?

9. **AWS PrivateLink (VPC Endpoint Service).** The mgmt-plane exposes an
   NLB behind an Endpoint Service; tenant VPCs create VPC Endpoints for it.
   Best when tenants and mgmt-plane are in different AWS accounts and you
   don't want to peer or share a Transit Gateway.

    → Are your tenant workloads already using PrivateLink for any other
       shared services? Same platform team owning that?

10. **Route53 Resolver — Outbound endpoint + forwarding rule.** If your
    corporate DNS already knows the mgmt-plane rootDomain (via an internal
    DNS zone), tenant VPCs can forward that specific domain to the
    corporate resolver instead of resolving via public DNS. Useful when the
    rootDomain is in your company's internal zone (`example.corp`,
    `mgmt.internal`) and DNS is already served from Windows/BIND/Infoblox.

11. **Route53 Resolver — Inbound endpoint.** Reverse of #10 — your on-prem
    resolvers forward the mgmt-plane rootDomain to an Inbound Endpoint in
    the mgmt-plane VPC. Useful when tenants include on-prem clusters
    registering to a cloud mgmt-plane.

### D. Deployment logistics

12. Is the mgmt-plane already installed, or are we standing it up as part
    of this engagement? (If installed, changing its rootDomain or moving
    it behind a different LB is expensive — may lock us into a
    workaround.)
13. Is a **change-management window** required to modify tenant VPC DNS
    settings (associating a private zone, adding a Resolver rule)? What's
    the lead time?
14. If we end up needing the CoreDNS workaround, does the tenant cluster
    profile go through GitOps / a review process, or can we apply it
    directly through the Palette UI during the engagement?

## Decision matrix

| If your environment... | Best pattern |
|---|---|
| Tenants peer to mgmt-plane VPC (or share a TGW) | Route53 private hosted zone associated with tenant VPCs → internal LB (#8) |
| Tenants are in different accounts, no peering, don't want to peer | AWS PrivateLink (#9) |
| Corporate DNS is the source of truth for the rootDomain | Route53 Resolver Outbound endpoint + forwarding rule (#10) |
| Hybrid — on-prem tenants registering to a cloud mgmt-plane | Route53 Resolver Inbound endpoint (#11) |
| CASB is the ONLY thing in the way and a bypass rule is easy to get | CASB do-not-decrypt on the rootDomain (question #6) — cleanest and stays public |
| None of the above achievable on the engagement timeline | CoreDNS phone-home layer (`coredns-phonehome.yaml`) — acceptable *temporarily*, plan to replace |

## Why we prefer AWS-native over the CoreDNS workaround

- **It survives infrastructure changes.** Route53 records follow load
  balancer DNS names automatically; the CoreDNS `hosts { }` block pins an
  IP that rotates without warning.
- **It doesn't mutate `kube-system` on every tenant cluster.** Cluster
  upgrades, add-on reconciliations, and admission-policy engines
  (Kyverno, VAP) all have opinions about anything living there.
- **It composes with existing corporate DNS.** Most enterprises already
  have a split-horizon story; Route53 fits into it. The CoreDNS hack
  doesn't.
- **It works for non-Palette workloads too.** Any pod on any tenant
  cluster that needs to reach the mgmt-plane will resolve it correctly,
  not just CMA.

