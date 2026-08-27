# Migrating the Palette / VerteX mgmt-plane LB from Classic ELB → NLB

The `spectro-mgmt-plane` chart's Traefik ingress service is a `LoadBalancer`
of AWS Classic-ELB flavor by default. Classic ELB has three problems that
motivate migrating to a Network Load Balancer:

1. **IPs rotate under AWS maintenance.** Every rotation invalidates
   `/etc/hosts` pins, tenant-cluster CoreDNS phone-home entries, and any
   Palette cluster profile pinning `mgmt_elb_ip`. Operational cost is real.
2. **No PrivateLink compatibility.** VPC Endpoint Services (PrivateLink) sit
   in front of an NLB, not a Classic ELB. As long as we're on Classic, we
   cannot offer a customer the PrivateLink option we outline in the
   `dns-split-horizon` preflight for CASB-heavy environments.
3. **Classic ELB is on AWS's deprecation path.** New AWS features and TLS
   support target ALB/NLB; Classic sees no roadmap investment.

This directory contains the values overlays for the migration + a runbook.

## Files

| File | Role |
|---|---|
| `values-classic-current.yaml` | The values that produce our current Classic ELB. Kept so the delta to the two target shapes is explicit. |
| `values-nlb-public-eips.yaml` | Target: **PUBLIC NLB with pre-allocated Elastic IPs**. Solves the IP-rotation problem while keeping the mgmt-plane reachable from the public Internet. Sandbox-shaped. |
| `values-nlb-internal.yaml` | Target: **INTERNAL NLB with pre-allocated private IPs**. Prep for PrivateLink / VPC-peering topologies. Enterprise-shaped (CASB-in-path customers). |

## Where does this `ingress:` block go?

**Two things people miss.**

**1) The correct path is `ingress.ingress.annotations` — double-nested.**
`spectro-mgmt-plane` is an umbrella chart whose ingress subchart is named
`ingress`. Helm nests subchart values under the subchart's name in the
parent's values, so the fully-qualified path from the parent's perspective is
`ingress.ingress.annotations`. Files that flat-nest under a single `ingress:`
silently no-op on `helm upgrade` because the subchart's Service template
reads `.Values.ingress.annotations` in subchart-relative terms.

**2) You merge this into the SAME values file you already use for the
install, not as a separate file.** Your existing environment values file
(e.g. `values-<env>.yaml`, `palette-mgmt-install/values-<env>.yaml`, or
whatever you pass to `helm upgrade -f`) almost certainly already has an
`ingress:` block that looks like:

```yaml
ingress:
  enabled: true
  traefik:
    hostPort: false
```

You extend that block by adding a sibling `ingress:` subkey with the
annotations from the target values file:

```yaml
ingress:
  enabled: true
  traefik:
    hostPort: false
  ingress:                           # ← ADD THIS SUBKEY
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "external"
      # ... (from values-nlb-*.yaml)
```

You CAN also pass the target file as an extra `-f`:

```bash
helm upgrade hubble <chart> -n default \
  -f values-<env>.yaml \
  -f values-nlb-public-eips.yaml       # or values-nlb-internal.yaml
```

Helm does a deep merge of maps, so the later `-f` file's `ingress.ingress.*`
keys merge into the first file's `ingress.*` block. This works but is
easier to reason about if you inline the change.

**Verify before you apply:**

```bash
# Show what the chart would render for the traefik Service annotations —
# should include your new NLB annotations, and no others surprise you.
helm --kube-context <MGMT> template hubble <chart> -n default \
  -f values-<env>.yaml \
  -f values-nlb-public-eips.yaml \
  | yq eval 'select(.kind == "Service" and .metadata.name == "traefik-ingress-controller")' -
```

## Which target to pick

| If your situation is... | Pick |
|---|---|
| Sandbox / demo / customers reachable via public Internet, and the only pain is IP rotation | `values-nlb-public-eips.yaml` |
| Enterprise / DoD / CASB-inspected environments where tenant traffic must stay on private AWS network | `values-nlb-internal.yaml` |
| Both — some tenants public, some private | Dual approach: internal NLB for the tenant-facing endpoint + a separate ingress path for operators. Out of scope for this runbook; ping to discuss. |

## Prerequisites — do these BEFORE the maintenance window

Both target shapes require the AWS Load Balancer Controller (LBC). Live check
we ran on the mgmt cluster (2026-08-26): **LBC is not currently installed.**
Without LBC, applying either `values-nlb-*.yaml` produces a Service whose
`type: LoadBalancer` stays Pending forever, because the `type: external`
annotation tells the in-tree controller to skip AND there's nothing else to
pick it up.

Prereq checklist (order matters):

- [ ] **Install AWS Load Balancer Controller** on the mgmt cluster.
      Follow: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/
      IRSA setup for the LBC service account is required; the trust policy
      needs `system:serviceaccount:kube-system:aws-load-balancer-controller`.
      Verify it's healthy: `kubectl -n kube-system get deploy aws-load-balancer-controller`.
- [ ] **Pre-allocate IPs.**
      * For `values-nlb-public-eips.yaml`: two Elastic IPs in the mgmt cluster's
        region, one per AZ the NLB will attach to. Tag them
        `spectro:purpose = vertex-mgmt-nlb` so nobody accidentally releases them.
      * For `values-nlb-internal.yaml`: two unassigned IPs in the private subnets
        the NLB will attach to. Verify with
        `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=...`
        that neither IP is already claimed by an ENI.
- [ ] **Confirm subnet tags** for LBC auto-discovery:
      * Public NLB: subnets tagged `kubernetes.io/role/elb=1`.
      * Internal NLB: subnets tagged `kubernetes.io/role/internal-elb=1`.
      If not tagged, pin them explicitly via
      `aws-load-balancer-subnets` in the values overlay.
- [ ] **Inventory every downstream consumer** of the current LB IP — see the
      "Downstream update checklist" below. Anything you miss will break for
      the duration of a support call.

## The migration — delete-and-recreate

**The AWS cloud-controller reads `aws-load-balancer-type` only at Service
create time.** `helm upgrade` with new annotations lands the annotations on
the Service object but the Classic ELB stays put. To flip the LB flavor you
have to delete the Service (which destroys the ELB) and recreate it (which
provisions an NLB).

Order of operations (do inside a maintenance window):

```bash
# 1. Snapshot the current state so you can compare / roll back
kubectl --context <MGMT> -n ingress-traefik get svc traefik-ingress-controller -o yaml \
  > /tmp/svc-classic-snapshot.yaml
OLD_LB_HOSTNAME=$(kubectl --context <MGMT> -n ingress-traefik get svc traefik-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
OLD_LB_IP=$(dig +short "$OLD_LB_HOSTNAME" | head -1)
echo "old LB: $OLD_LB_HOSTNAME ($OLD_LB_IP)"

# 2. Apply the new values via helm — this only lands the annotations, doesn't yet
#    swap the LB.
helm --kube-context <MGMT> upgrade hubble <chart> \
  --namespace default \
  -f values-nlb-public-eips.yaml         # or values-nlb-internal.yaml
kubectl --context <MGMT> -n ingress-traefik get svc traefik-ingress-controller \
  -o jsonpath='{.metadata.annotations}' | jq .
# ↑ verify the NLB annotations are present. LB itself is still Classic.

# 3. THE DELETE-RECREATE — this is the maintenance-window action.
#    Delete the Service; the Classic ELB is destroyed within ~1-2 min.
#    Then re-run helm upgrade to re-create the Service (it will render with the
#    NLB annotations this time, and LBC will provision an NLB).
kubectl --context <MGMT> -n ingress-traefik delete svc traefik-ingress-controller
helm --kube-context <MGMT> upgrade hubble <chart> \
  --namespace default \
  -f values-nlb-public-eips.yaml
kubectl --context <MGMT> -n ingress-traefik get svc traefik-ingress-controller -w
# Wait for status.loadBalancer.ingress[0].hostname to populate.
# For a public NLB with EIPs, the hostname will look like
#   <name>-<hash>.elb.<region>.amazonaws.com
# and dig it → should return your pre-allocated EIPs.

# 4. Capture the new endpoint
NEW_LB_HOSTNAME=$(kubectl --context <MGMT> -n ingress-traefik get svc traefik-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NEW_LB_IP=$(dig +short "$NEW_LB_HOSTNAME" | head -1)
echo "new LB: $NEW_LB_HOSTNAME ($NEW_LB_IP)"
```

Expected downtime: from the moment you run `kubectl delete svc` until the NLB
is reachable, the mgmt-plane API is unreachable from any tenant cluster. Plan
for 3–5 minutes of API-hard-down. During that window:

- Tenant clusters will accumulate jet errors in their controllers — they
  will retry, so most catch up on their own once reachability returns.
- The Palette UI is unreachable (Traefik is the ingress for it too).
- In-flight `helm` / `kubectl` operations from the mgmt cluster's own
  controllers will queue and retry.

## Downstream update checklist — everything that pins the OLD LB IP

Once the new LB is up and you have `NEW_LB_HOSTNAME` / `NEW_LB_IP`, work
through every place the old value is referenced. Anything you miss stays
broken until you find it.

- [ ] **DNS records** — Route53 public zone, Route53 private zone, corporate
      DNS. Anything currently pointing at `OLD_LB_HOSTNAME` (as an ALIAS or
      CNAME) or `OLD_LB_IP` (as an A record) needs updating.
- [ ] **Operator laptops' `/etc/hosts`** — every SE / operator with a manual
      pin for the mgmt-plane rootDomain. This includes anyone using a
      launchd script that auto-refreshes it.
- [ ] **Tenant cluster CoreDNS phone-home entries**. Every workload cluster
      provisioned by this mgmt-plane has a `hosts { }` block in
      `kube-system/coredns` mapping the rootDomain → OLD_LB_IP. Update via
      the Palette Add-Manifest layer's profile variable (`mgmt_elb_ip`),
      then reconcile each cluster profile.
- [ ] **Palette cluster profile Terraform** — the `mgmt_elb_ip` variable in
      any `terraform.tfvars` we're maintaining (Domino profile, ECK profile,
      dns-split-horizon example). Update the tfvars, re-plan, re-apply.
- [ ] **VerteX chart's own `config.env.rootDomain`** — if the rootDomain is
      a hostname whose backing DNS record was pointed at the OLD_LB_HOSTNAME,
      the DNS update covers it. If it was pointed at OLD_LB_IP directly
      (uncommon but possible), the A record needs updating.
- [ ] **Firewall / SG allowlist entries** — anything in a security group or
      corporate firewall that references OLD_LB_IP directly.

Recommend running a repo-wide grep for the old IP after the migration:

```bash
grep -rnw "$OLD_LB_IP" ~/workspace 2>/dev/null
grep -rnw "$OLD_LB_HOSTNAME" ~/workspace 2>/dev/null
```

## Rollback

If something in the migration goes sideways within the maintenance window,
roll back by reverting the values file and re-applying:

```bash
# Delete the new (NLB) Service
kubectl --context <MGMT> -n ingress-traefik delete svc traefik-ingress-controller

# Re-apply the original values → recreates a Classic ELB
helm --kube-context <MGMT> upgrade hubble <chart> \
  --namespace default \
  -f values-classic-current.yaml
```

Caveat: the new Classic ELB will have a NEW hostname / IP again — you can't
get the ORIGINAL Classic ELB back, because AWS destroyed it in step 3.
Rollback puts you back on a Classic-ELB shape, not the exact original one.
All downstream pins still need updating; only the flavor is restored.

## Verifying the migration

After the swap:

- [ ] `dig +short <NEW_LB_HOSTNAME>` returns the pre-allocated IPs.
- [ ] `curl -sk -o /dev/null -w '%{http_code}\n' https://<rootDomain>/v1/health`
      returns 200 from an operator laptop (public NLB) or from a tenant EC2
      (internal NLB).
- [ ] `kubectl --context <TENANT> -n jet-system logs deploy/jet` shows
      successful auth calls (no `TextConsumer` errors, no `no such host`).
- [ ] Palette UI loads at the rootDomain.
- [ ] `kubectl --context <MGMT> -n ingress-traefik describe svc traefik-ingress-controller`
      shows the LBC-generated events (`SuccessfullyReconciled`) and no
      warnings.

Bonus: verify EIP allocations survived a chart upgrade cycle. Run
`helm upgrade` a second time with no values changes; the LB should NOT
re-provision (the annotations are unchanged so LBC is a no-op).

## Related

- `values-classic-current.yaml` — the before-state for the diff.
- Info-share `palette-vertex/dns-split-horizon/README.md` — the customer
  preflight this migration unlocks (specifically the PrivateLink path in
  the decision matrix, which requires an internal NLB).
- SUS-1958 — the chart-level tenant-API-endpoint override that would
  eliminate the need for the tenant-side CoreDNS workaround. Independent
  of this migration but complementary.
