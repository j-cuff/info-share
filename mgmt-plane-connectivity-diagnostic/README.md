# Palette / VerteX mgmt-plane connectivity diagnostic

Use this when a workload cluster's `jet` (or any Palette agent inside a workload cluster) can't
talk to the mgmt-plane API and crash-loops with a body-deserialization error such as:

    (*models.V1AuthCertsGet) is not supported by the TextConsumer, can be resolved by
    supporting TextUnmarshaler interface

The error message points at TLS/mTLS — that's a **misleading** interpretation. In most real
cases the underlying failure is a NETWORK-LAYER one: the request never reaches auth-service
in the mgmt-plane, or it does but through an intermediary that mangles the response.

## Why this playbook exists

We've now seen this exact deserialization error caused by **three completely different root
causes**. Each requires a different fix. Attempting the wrong fix wastes days and adds
resources to the cluster that later need to be undone. This playbook is the fast, ordered
diagnostic — you run it in ~5 minutes and know which of the three you're in.

## The three failure modes we've seen

| # | Root cause | Response profile | Fix |
|---|---|---|---|
| 1 | **Wrong URL in `hubble-info`** — jet is pointing at ingress landing page, UI, or wrong-vhost 404 | HTTP 200, `content-type: text/html`, HTML body | Edit `hubble-info` CM in `jet-system`. Restart jet. |
| 2 | **Corporate proxy / cloud broker / WAF intercepting HTTPS** — proxy MITM's the connection and injects a redirect, auth challenge, or block page | HTTP 3xx (often 303 See Other), or 200 with proxy-injected HTML | Network team: add mgmt-plane hostname/CIDR to the proxy bypass list. Nothing on the cluster side. |
| 3 | **Actual mTLS gate on auth-service** (rare — verified NOT the case in shipping VerteX 4.9.18) | HTTPS handshake fails, connection reset, or 403 | Provision a client cert. Not documented as a supported path — escalate to Spectro engineering. |

Mode 2 (proxy interception) is by far the most common in enterprise / govcloud environments —
Zscaler, Netskope, iBoss, Palo Alto Prisma, McAfee Web Gateway, corporate SSL-inspection
proxies, cloud broker networks. Any of these can transparently intercept egress HTTPS and
break jet without anyone realizing they're on the request path.

## The diagnostic — run this first

From a debug pod **inside `jet-system`** (same namespace jet actually runs in — critical
because that's where routing/proxy overlays might behave differently than the node):

```bash
kubectl -n jet-system run curltest --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command --timeout=30s -- \
  sh -c '
    URL=$(cat /var/run/hubble-info-url 2>/dev/null)
    if [ -z "$URL" ]; then
      # Fallback if the CM key isn'"'"'t projected as a file — read the raw CM the way jet does
      URL="<paste the .data.url from hubble-info here>"
    fi
    PORT="<paste .data.apiEndpointPort — usually empty>"
    [ -n "$PORT" ] && URL="$URL:$PORT"

    echo "==> GET https://$URL/v1/auth/certs"
    curl -sk -D - -o /tmp/body \
      -w "\n---\nstatus=%{http_code}\ncontent_type=%{content_type}\nsize=%{size_download}\nredirect_url=%{redirect_url}\n" \
      "https://$URL/v1/auth/certs"

    echo "--- first 400 bytes of body ---"
    head -c 400 /tmp/body
    echo
    echo "--- HTTP headers only (any Via / X-Forwarded / Server hint at a proxy?) ---"
    grep -iE "via:|x-forwarded|server:|x-proxy|zscaler|netskope|iboss|prisma|forcepoint|cloudflare|akamai" /tmp/body 2>/dev/null || echo "(no obvious proxy signatures)"
  '
```

Then match the observed response against the table below.

## Response → diagnosis table

### Expected working response (what a healthy install returns)

```
status=200
content_type=application/json
size=~2000 bytes
body starts: {"apiDomain":"...","caCert":"-----BEGIN CERTIFICATE-----\n...","insecureSkipVerify":false,"rootDomain":"..."}
```

If you see this — connectivity IS fine. The error jet is throwing is a different problem
(check jet's env, RBAC, or actual application bug).

### Mode 1 — wrong URL in `hubble-info`

```
status=200
content_type=text/html
body starts: <!DOCTYPE html>...
```

You're hitting a UI, an ingress default backend, or a wrong-vhost landing page. Fix:

```bash
kubectl -n jet-system get cm hubble-info -o yaml
# compare against reference:
#   url: <hostname-only, no scheme, no port>
#   apiEndpoint: <same>
#   apiEndpointPort: ""     # empty unless mgmt-plane is on non-443

# If wrong, edit the CM (or fix at the chart values level so it re-renders):
kubectl -n jet-system edit cm hubble-info

# Restart jet to pick up the new value
kubectl -n jet-system rollout restart deploy/jet
```

### Mode 2 — proxy interception (the common one in enterprise / GovCloud)

```
status=303 See Other        (or 302 / 307 / 200-with-injected-HTML)
content_type: text/html
Location: <some-proxy-auth-portal-URL>
Server or Via: <proxy vendor string>
```

The mgmt-plane is fine. Traffic egressing from `jet-system` toward the mgmt-plane hostname
is being transparently intercepted by an enterprise **CASB / SASE / SSL-inspection layer**
that returns a redirect (to an auth page) or an HTML block-page. Jet's HTTP client sees
`content-type: text/html`, invokes the go-openapi `TextConsumer` for its expected
`*models.V1AuthCertsGet`, and panics.

Why this happens even when jet and auth-service live in the SAME cluster: the mgmt-plane
hostname (`config.env.rootDomain` in the VerteX helm values) resolves to the **external**
Traefik ELB IP, not the in-cluster ClusterIP. That means jet's request leaves the pod
network, egresses the node, and gets caught by whatever CASB is inline on that egress path.

**Vendor detection** — the response usually names itself. Look at the diagnostic output for:

| Vendor | Tell-tale signals |
|---|---|
| **Netskope** | `Location: https://auth-npaproxy-liftoff.goskope.com/...`, `Set-Cookie: npa_auth=...`, sometimes `Server: netskope` |
| **Zscaler** | `Location: https://gateway.zscaler.net/...` or `.zsvpn.com`, `Server:` containing `Zscaler` |
| **Palo Alto Prisma Access** | `Location:` under `.prismaaccess.com` or `.gpcloudservice.com`, `Via: prismaaccess` |
| **Cisco Umbrella / iBoss** | `Server: iboss` or `Server: OpenDNS`, block-page HTML that names the vendor |
| **BlueCoat / Symantec** | `Server: BlueCoat`, `X-Bluecoat-Via:` |
| **Corporate Squid / generic** | `Via: 1.1 <squid-hostname>`, no vendor in Server but a `Via:` present |

The **presence of any redirect (3xx)** or `Location:` at all when hitting `/v1/auth/certs`
is dispositive proof. Auth-service does not redirect on that endpoint.

#### Fix — two paths, ranked

**Path A (preferred long-term) — network-team bypass rule.**

Give the customer's network team this exact ask:

> "Add a bypass rule for HTTPS traffic to `<mgmt-plane hostname>:443`. Source: everything
> that needs to talk to the mgmt-plane (workload cluster pod CIDRs, and — for self-hosted —
> the mgmt cluster's own pod CIDR). Traffic must NOT be MITM'd or subject to SSL inspection.
> The mgmt-plane presents its own TLS chain that internal microservices verify against a
> private CA; any CA substitution breaks the chain."

Lead time here is the customer's change-management cycle, usually days.

**Path B (immediate, install-time) — split-horizon DNS via CoreDNS on the mgmt cluster.**

For traffic that ORIGINATES INSIDE the mgmt cluster (this includes jet talking to
auth-service in a self-hosted VerteX install), resolve the mgmt-plane hostname to the
Traefik `ClusterIP` **inside** the cluster. That way the traffic never leaves the pod
network and never reaches the CASB. External traffic (browsers, workload clusters in other
networks) continues to resolve to the public ELB IP and route through whatever egress path
they normally use.

This is the "Rule 2b" pattern named in the internal workspace CLAUDE.md. **It is NOT
documented in Spectro's docs today** — it's a field-proven install-time workaround. A worked
example is in [`examples/coredns-split-horizon-corefile.yaml`](examples/coredns-split-horizon-corefile.yaml).

Caveats:
* Only fixes egress originating INSIDE the mgmt cluster. Workload clusters in other VPCs
  and browsers still route to the external ELB IP — for those, you still need Path A.
* If the Traefik ClusterIP changes (rare, but possible after a mgmt-plane reinstall),
  refresh the hosts block.

**Path C (looks tempting, is wrong) — `reach-system` in the VerteX helm values.**

Don't do this. `reach-system` configures Palette to egress THROUGH a corporate proxy for
its OWN outbound internet access (pack sync, license servers, etc.). It's the opposite
direction from what you need — the customer's problem is inbound traffic being intercepted
by a CASB, not outbound Palette-to-internet requests. Enabling `reach-system` may be
independently required for other reasons in the customer's environment, but it will not
fix the jet crash-loop. See
[reach-system doc](https://docs.spectrocloud.com/vertex/install-palette-vertex/install-on-kubernetes/vertex-helm-ref/#reach-system)
for the actual purpose.

### Mode 3 — actual mTLS gate (rare, verify carefully)

```
status=000                        (TCP/TLS handshake failure)
or connection reset
or status=403 with body: <empty> or an auth-service error page
```

**Only conclude mode 3 if modes 1 and 2 are BOTH ruled out.** Auth-service in shipping
VerteX 4.9.18 does NOT require client certs for `/v1/auth/certs` — verified against a
working sandbox where jet has no client cert mounted and gets a clean 200 JSON back.

If you're here after ruling out 1 and 2, escalate to Spectro engineering — this would be a
build-specific behavior we haven't documented.

## Related runbooks

* [`vertex-workload-cluster-provisioning/jet-mtls-CORRECTED-FIX.md`](../vertex-workload-cluster-provisioning/jet-mtls-CORRECTED-FIX.md) — mTLS-side fix, now framed as "mode 3 only"
* [`vertex-workload-cluster-provisioning/persistent-fix/`](../vertex-workload-cluster-provisioning/persistent-fix/) — the durable helm post-renderer for mode 3. Do NOT deploy unless mode 3 is confirmed.
* [`../CUSTOMER-PREFLIGHT-QUESTIONNAIRE.md`](../CUSTOMER-PREFLIGHT-QUESTIONNAIRE.md) — Section E has the pre-engagement questions that catch mode 2 before it becomes a ticket.

## Attribution

Mode 2 diagnosis was contributed by a customer engineer who ran the diagnostic curl and saw
the HTTP 303 come back from their cloud broker. That single observation reframed a
multi-week debug we'd been treating as an mTLS/chart problem into a network policy request.
Lesson: **always match the failing symptom against a known-working reference before
building on top of an existing hypothesis.**
