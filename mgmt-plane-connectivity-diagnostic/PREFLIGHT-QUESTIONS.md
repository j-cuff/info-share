# Pre-engagement questions — network intermediaries between workload clusters and mgmt-plane

These questions belong in the customer preflight questionnaire under a new section on
**network intermediaries**. Ask them BEFORE any install. Each one catches a specific class
of failure we've had to debug in the field.

## The questions

1. **Is there a CASB / SASE / corporate SSL-inspection layer between anything in your
   network and the mgmt-plane hostname?** This is the single question that catches the
   most-common failure mode in enterprise + GovCloud installs.
   * Vendors specifically observed to intercept mgmt-plane traffic:
     - **Netskope** — signature: 303 See Other redirect to `auth-npaproxy-liftoff.goskope.com`,
       `npa_auth` cookie
     - **Zscaler** — signature: redirect under `.zscaler.net` / `.zsvpn.com`, `Server: Zscaler`
     - **Palo Alto Prisma Access** — signature: redirect under `.prismaaccess.com`, `Via: prismaaccess`
     - **Cisco Umbrella, iBoss, BlueCoat/Symantec, Forcepoint, McAfee Web Gateway, corporate Squid** —
       various redirect / block-page shapes, generally identifiable by `Server:` or `Via:` headers
   * *Why it breaks Palette:* transparent HTTPS interception rewrites the TLS chain and
     often injects a redirect (HTTP 303) or an HTML block/auth page. `jet` in `jet-system`
     expects `application/json` from `/v1/auth/certs`; go-openapi sees `text/html` and
     invokes `TextConsumer`, which panics deserializing into `*models.V1AuthCertsGet`. Jet
     crash-loops with an error that reads like an mTLS problem but the mgmt-plane never even
     sees the request.
   * *Even self-hosted installs are affected.* Because `config.env.rootDomain` in the
     helm values propagates unchanged into `hubble-info.apiEndpoint` and `hubble-info.url`,
     jet's calls to auth-service resolve to the **external** Traefik ELB IP and egress the
     pod network, where the CASB catches them — even though jet and auth-service are in the
     same cluster.
   * *If yes, two fix paths (see the diagnostic runbook for detail):*
     - **Path A (preferred long-term):** the customer's network team adds a proxy bypass
       rule for HTTPS to `<mgmt-plane hostname>:443`, no SSL inspection, no redirect. This
       is a change-management ask — factor lead time into the engagement schedule.
     - **Path B (install-time immediate):** apply the split-horizon DNS workaround via
       CoreDNS on the mgmt cluster so intra-cluster traffic resolves the mgmt-plane
       hostname to the Traefik `ClusterIP`. Field-proven, undocumented by Spectro. Example
       Corefile snippet: `examples/coredns-split-horizon-corefile.yaml`. Only fixes
       intra-cluster egress; workload clusters in other VPCs still need Path A.
   * *Do NOT recommend* `reachSystem.enabled=true` in the helm values as a fix — that
     configures Palette's own outbound proxy usage (a different scenario), not inbound
     interception. Enabling it may be independently useful for pack-sync-through-proxy
     scenarios but does not help this failure mode.

2. **Is egress from workload cluster nodes/pods full-tunnel VPN'd back to a corporate
   perimeter, and does that perimeter enforce SSL inspection?**
   Same failure mode as (1), just with the interception happening at a different network
   hop. If yes, same bypass rule needed.

3. **Does the mgmt-plane hostname resolve to a different IP from inside the workload cluster
   than from the mgmt-plane itself?**
   Enterprise split-horizon DNS is common in GovCloud environments — the mgmt-plane's
   Traefik ELB may be reachable from outside a corporate perimeter but resolved to an
   internal-only IP (or a proxy VIP) from inside it. Confirm the resolved IP matches the
   ELB IP end-to-end.

4. **Are all responses from the mgmt-plane hostname signed by the mgmt-plane's own TLS
   chain?**
   Run `curl -vk https://<mgmt-plane-hostname>` from a workload cluster pod. The `subject`
   and `issuer` in the served cert should match what the mgmt-plane's traefik-tls
   Certificate says — NOT a corporate CA (`Corp Root CA`, `Zscaler Root CA`,
   `Netskope Root CA`, etc.). A corporate CA in the response chain = SSL inspection in the
   path = mgmt-plane responses aren't reaching jet unmangled.

5. **What's the outbound HTTPS request flow, hop by hop, from a workload cluster pod to
   the mgmt-plane?**
   Ask the customer to trace it: pod → node → node-egress (NAT gateway? Transit gateway?
   VPN?) → corporate network → any proxy / broker / WAF → mgmt-plane ingress.
   Every hop is a potential MITM. Every hop's TLS decisions matter.

## What to include in the engagement kick-off

Once you have the answers, include this in your kick-off doc for the customer:

> **Required bypass rule for workload-cluster → mgmt-plane traffic:**
>
> * Source: workload cluster pod CIDR (and/or node CIDR — confirm which egresses)
> * Destination: `<mgmt-plane hostname>` on TCP/443
> * SSL inspection: **DISABLED**. mgmt-plane responses use a private CA that internal
>   microservices verify against; SSL inspection breaks this chain.
> * Proxy authentication: **NOT REQUIRED**. jet does not present proxy credentials.
> * Redirect handling: **NONE**. Traffic must pass through unchanged.
>
> Provide this rule to your network / cloud broker team before the mgmt-plane install
> begins. If the customer's network team requires a change-management process, factor
> that lead time into the engagement schedule.

## Diagnostic evidence you can share with the customer's network team

If the customer isn't sure whether interception is happening, hand them the diagnostic
script in this folder's README. A response with any of these markers is proof of
interception:

* `Server:` header containing a proxy vendor string
* `Via:` header present
* `HTTP/1.1 3xx` with a `Location:` pointing at anything other than the mgmt-plane
* TLS cert (from `curl -vk`) issued by a corporate CA rather than the mgmt-plane CA

That evidence — together with the specific ask above — is enough for the network team to
scope and implement the bypass. Without evidence you'll typically get "we don't intercept
outbound traffic" as a first response even when they do; the response body proves
otherwise.
