# CASB / SASE / SSL-inspection vendor signatures — response fingerprints

A field reference for identifying WHICH proxy is intercepting mgmt-plane traffic when the
diagnostic curl (`../diagnostic-curl.sh`) reports mode 2. Naming the vendor speeds the
network-team conversation — "you have Netskope in the path" lands better than "some
proxy" and points at the exact bypass ticket queue.

Each row is a distinct observed intercept pattern. Match on whichever headers your
diagnostic output shows.

| Vendor | HTTP status | `Location:` header pattern | Cookies / other headers | Notes |
|---|---|---|---|---|
| **Netskope** | 303 (most common), also 302 | `https://auth-npaproxy-liftoff.goskope.com/...`<br/>`https://*.npa.goskope.com/...` | `Set-Cookie: npa_auth=...`<br/>`npacl_state=...` param on the Location URL | The `-liftoff` in the hostname is the tenant identifier — varies by customer. `goskope.com` is the constant. This is what we saw with the Cosmos Navy customer (SCS ticket in Aug 2026). |
| **Zscaler** | 302, 307 | `https://gateway.zscaler.net/...`<br/>`https://*.zsvpn.com/...`<br/>`https://*.zpa-*.net/...` (ZPA) | `Server: Zscaler/*`<br/>`Via:` containing `zscaler` | Two products: ZIA (Internet Access) redirects to `gateway.zscaler.net`; ZPA (Private Access) redirects to a per-tenant `.zpa-*.net`. |
| **Palo Alto Prisma Access** | 302, 307 | `https://*.prismaaccess.com/...`<br/>`https://*.gpcloudservice.com/...` | `Via: prismaaccess`<br/>`Server: PAN-*` | Often paired with GlobalProtect. |
| **Cisco Umbrella** | 200 with HTML block-page (not always a redirect) | (block page inline) | `Server: OpenDNS`<br/>`Server: umbrella-block` | Umbrella often returns a full HTML block page at 200, not a 3xx. Body will contain `id="umbrella-block-page"` or `umbrella.cisco.com`. |
| **iBoss** | 302 or 200 block-page | `https://blockpage.iboss.com/...` (varies by tenant) | `Server: iboss`<br/>`Server: iBossHTTPProxy` | Historically federal-flavored — expect in gov customer environments. |
| **BlueCoat / Symantec Web Security** | 302, 307 | `https://*.bluecoat.com/...`<br/>tenant-specific hostname | `Server: BlueCoat`<br/>`X-Bluecoat-Via:` | Now Broadcom-owned. |
| **McAfee Web Gateway (Skyhigh)** | 302 | `https://*.myshn.net/...`<br/>`https://*.myshn.eu/...` | `Server: McAfee Web Gateway`<br/>`Server: MWG` | Skyhigh acquired the McAfee Web business — new intercepts use the Skyhigh hostnames. |
| **Forcepoint** | 302 | `https://*.websense.com/...`<br/>`https://*.forcepoint.com/...` | `Server: WSGATE`<br/>`X-Auth-Redirect:` | Websense was rebranded to Forcepoint. |
| **Menlo Security** | 302 | `https://*.menlosecurity.com/...`<br/>`https://safe.menlosecurity.com/...` | `Server: Menlo`<br/>`X-Menlo-*:` various | Isolation platform — often catches API traffic in "isolate everything" configs. |
| **Corporate Squid (no vendor CASB)** | 302, 407, or 200 with block-page | Varies (custom auth portal, internal CA cert page) | `Via: 1.1 <squid-hostname> (squid/<version>)` | Legacy on-prem. `Via:` header is the tell. |

## When the vendor doesn't self-identify

Some deployments strip `Server:` and other identifying headers. In that case:

1. **Look at the TLS chain.** `curl -vk https://<mgmt-hostname>/v1/auth/certs` shows the
   cert the client sees. If the `issuer` is `CN=<Customer> Root CA` or any organization
   other than the mgmt-plane's own CA (`hubble-intermicrosvccom-ca-issuer` on VerteX),
   there's TLS interception somewhere and CA substitution has happened.
2. **Compare cert fingerprint** against what the mgmt-plane serves. Ask the customer to
   `curl -vk` the mgmt-plane hostname from a host that's known NOT to be behind the
   CASB — the fingerprint mismatch is proof of interception.
3. **Ask the customer's IT team by function.** "What CASB / SASE / web-security product
   are you using?" is more productive than "why is my traffic being redirected."

## Response profile summary (for the runbook decision table)

Any of these = mode 2:

- HTTP status is a `3xx` on `/v1/auth/certs`
- `Location:` header present at all
- `Content-Type: text/html` combined with a small (`<2 KiB`) body
- TLS chain issuer is a corporate/vendor CA rather than the mgmt-plane's private CA
- ANY of the vendor signatures above

None of these = probably NOT mode 2:

- `Content-Type: application/json` and body starts with `{"apiDomain":`  → healthy (or mode 3 rare)
- Body is a HTML page from the mgmt-plane's own UI/landing (that's mode 1, wrong URL)

## Feedback loop

If you encounter a vendor / intercept pattern that isn't in the table above, add it. This
reference gets more useful with every customer engagement — the whole point is to shorten
the time from "TextConsumer error in jet logs" to "you have Vendor X in the path, here's
the ticket to file."
