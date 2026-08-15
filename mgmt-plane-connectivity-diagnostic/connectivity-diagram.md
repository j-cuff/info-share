# Connectivity diagram — where the failure modes live

## Working path

```mermaid
flowchart LR
  subgraph WC["Workload cluster"]
    JET["jet-manager<br/>(jet-system)"]
    CM["ConfigMap<br/>hubble-info<br/>.data.url = mgmt.example.com"]
    CM -.reads.-> JET
  end

  subgraph NET["Network path"]
    NODE["Node egress<br/>(NAT / VPN / TGW)"]
    INT["intermediaries?<br/>(proxy / WAF / broker)"]
    NODE --> INT
  end

  subgraph MP["Mgmt-plane cluster"]
    ELB["Traefik ELB<br/>mgmt.example.com"]
    TRAEFIK["Traefik ingress"]
    AUTH["auth-service<br/>(hubble-system)"]
    ELB --> TRAEFIK --> AUTH
  end

  JET -->|GET /v1/auth/certs| NODE
  INT -->|"HTTPS 443<br/>NO SSL inspection<br/>NO redirect"| ELB
  AUTH -->|"200 application/json<br/>{apiDomain,caCert,...}"| JET
```

## Failure mode 1 — wrong URL in `hubble-info`

Jet points at the wrong hostname or scheme, hits an unrelated endpoint that returns HTML.

```mermaid
flowchart LR
  JET["jet-manager"]
  CM["hubble-info<br/>.data.url = https://mgmt.example.com<br/>(scheme included → jet splits on : wrong)<br/>OR url = ui.example.com<br/>(UI landing page, not API)"]
  UI["Wrong endpoint:<br/>UI landing / ingress default backend / 404 page"]

  CM -->|misconfigured| JET
  JET -->|"GET /v1/auth/certs"| UI
  UI -->|"200 text/html<br/>&lt;!DOCTYPE html&gt;..."| JET
  JET -->|"TextConsumer<br/>can't parse HTML into<br/>V1AuthCertsGet"| CRASH["CrashLoopBackOff"]

  style CM fill:#fdd
  style UI fill:#fdd
  style CRASH fill:#f88
```

**Fix:** correct the `hubble-info` CM. `kubectl -n jet-system edit cm hubble-info`, remove
any scheme, ensure hostname matches the mgmt-plane's Traefik ELB DNS name.

## Failure mode 2 — corporate proxy / cloud broker interception (the important one)

Traffic egresses the workload cluster, hits a corporate proxy or cloud broker in the
enterprise network path, which transparently intercepts HTTPS and returns a redirect,
authentication challenge, or block page.

```mermaid
flowchart LR
  JET["jet-manager"]
  NODE["Node egress"]
  PROXY["Corporate proxy<br/>Zscaler / Netskope / iBoss<br/>Palo Alto Prisma / Squid /<br/>corp SSL inspection"]
  MP["Mgmt-plane<br/>(never sees the request)"]

  JET -->|"GET /v1/auth/certs"| NODE
  NODE --> PROXY
  PROXY -.blocked.-> MP
  PROXY -->|"303 See Other<br/>Location: auth portal<br/>OR 200 text/html<br/>block page"| JET
  JET -->|"TextConsumer<br/>can't parse redirect body<br/>into V1AuthCertsGet"| CRASH["CrashLoopBackOff"]

  style PROXY fill:#f99
  style CRASH fill:#f88
  style MP fill:#ddd,stroke-dasharray:5 5
```

**Fix:** network team adds a bypass rule — no cluster-side change works. See
[PREFLIGHT-QUESTIONS.md](PREFLIGHT-QUESTIONS.md).

## Failure mode 3 — actual mTLS gate (rare, verify carefully)

Auth-service is configured to require a client cert on `/v1/auth/certs`. Not the case in
shipping VerteX 4.9.18, but hypothesized for some builds.

```mermaid
flowchart LR
  JET["jet-manager<br/>(no client cert)"]
  ELB["Traefik ELB"]
  AUTH["auth-service<br/>configured to require client cert"]

  JET -->|"GET /v1/auth/certs<br/>no client cert"| ELB
  ELB --> AUTH
  AUTH -->|"TLS handshake fails<br/>OR 403<br/>OR mangled response"| JET
  JET --> CRASH["CrashLoopBackOff"]

  style AUTH fill:#fda
  style CRASH fill:#f88
```

**Fix:** provision a client cert for jet. See
[../vertex-workload-cluster-provisioning/persistent-fix/](../vertex-workload-cluster-provisioning/persistent-fix/).
**Only apply this if modes 1 and 2 are ruled out.**

## Trust boundaries — what the network team needs to see

```mermaid
flowchart TB
  subgraph POD["Pod trust zone (workload cluster)"]
    JET["jet"]
    JETCA["Trusts: mgmt-plane's traefik-tls CA<br/>(injected via hubble-info.caCert)"]
  end

  subgraph EGRESS["Egress path — this is what needs to be TRANSPARENT"]
    direction LR
    E1["node NAT"] --> E2["corp network"] --> E3["cloud broker / proxy"] --> E4["internet / VPC"]
  end

  subgraph MPLANE["Mgmt-plane trust zone"]
    ELB["ELB / Traefik"]
    ELBCA["Presents: cert signed by<br/>mgmt-plane's hubble-ca"]
  end

  JET --> EGRESS --> ELB
  ELB -.presents cert.- ELBCA
  JETCA -.verifies.- ELBCA

  RULE["Rule for network team:<br/><br/>Any intermediary in EGRESS zone that<br/>terminates TLS and re-signs with a<br/>corporate CA will BREAK the verification<br/>chain jet uses. Bypass required."]

  style RULE fill:#ffd,stroke:#000,stroke-width:2px
  style JETCA fill:#dfd
  style ELBCA fill:#dfd
```

The whole thing works only if the TLS chain jet sees at the pod IS the chain the mgmt-plane
served. Any middlebox that "helpfully" decrypts and re-encrypts (SSL inspection, corporate
MITM, cloud broker re-signing) substitutes a different CA into the chain — jet's client
rejects it (or the response body is mangled with a redirect / block page).
