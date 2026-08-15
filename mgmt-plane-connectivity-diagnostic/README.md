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

### Mode 2 — proxy interception (the important new one)

```
status=303 See Other        (or 302 / 307 / 200-with-injected-HTML)
content_type: text/html
Location: <some-proxy-auth-portal-URL>
Server or Via: <proxy vendor string>
```

**Do NOT change anything on the cluster.** The mgmt-plane is fine. Traffic from
`jet-system` egress is being transparently intercepted by an enterprise proxy / cloud broker
that returns a redirect (to an auth page) or an HTML block-page. Jet's HTTP client sees
`content-type: text/html`, invokes the go-openapi `TextConsumer` for its expected
`*models.V1AuthCertsGet`, and panics.

Fix path:

1. **Prove it's a proxy** — verify the response is coming from something OTHER than the
   mgmt-plane Traefik. Signals:
   - `Server:` header lists a proxy vendor (Zscaler, Squid, BlueCoat, etc.)
   - `Via:` header present
   - `Location:` header points at a corporate auth portal (SSO login, click-thru NDR page)
   - Response TLS cert (from `curl -vk`) is signed by an internal corporate CA, NOT
     `hubble-intermicrosvccom-ca-issuer` or a public CA
2. **Escalate to the network team** with a specific ask:
   > "Add a proxy bypass rule for outbound HTTPS from workload-cluster pod CIDR to
   > `<mgmt-plane hostname>` on port 443. Traffic must NOT be MITM'd or subject to SSL
   > inspection — the mgmt-plane presents its own TLS chain that internal microservices
   > verify against a private CA."
3. **Do not deploy any cluster-side workaround** while waiting for the network team.
   Don't patch jet, don't create client certificates, don't install cert-manager mirrors.
   None of it will help — the mgmt-plane never sees the request.

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
