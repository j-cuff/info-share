# Persistent fix — jet ↔ auth-service mTLS on VerteX

**What this bundle does:** makes the jet ↔ auth-service mTLS wiring survive every
`helm install` / `helm upgrade` of the mgmt-plane chart. No kubectl patches to redo, no manual
copies to remember, no reconcile loops fighting each other.

**How it works:** ships as a **helm post-renderer** — a small kustomize overlay that intercepts
`helm` output before it's applied to the cluster, injects a correct `Certificate` for
`jet-system` and patches the jet Deployment with the volume+mount+SA it should have shipped
with. The chart itself is unchanged; the overlay lives beside your release invocation.

## When to use each path

| Path | Use it when |
|---|---|
| **A. Helm post-renderer (this bundle)** | You install via `helm install`/`helm upgrade` directly, or via a wrapper that lets you pass `--post-renderer`. |
| **B. GitOps overlay (Argo/Flux)** | Your mgmt-plane release is managed by an Argo `Application` or Flux `Kustomization`. Same kustomize files, but wired into your source repo instead of `--post-renderer`. Notes at the end. |

## Prerequisites

* `helm` ≥ 3.6 (post-renderer support)
* `kustomize` ≥ 4.0 on the machine running `helm`
* `cert-manager` already in the cluster with ClusterIssuer
  `hubble-intermicrosvccom-ca-issuer` (the mgmt-plane chart provisions this at install).

## Files in this bundle

* `kustomization.yaml`   — declares the overlay
* `certificate-jet-authtls.yaml` — creates `Certificate/auth-tls` in `jet-system` (correct
  CN and SANs, auto-renewed by cert-manager)
* `patch-jet-deployment.yaml`    — strategic merge patch: volume + mount + SA on the jet
  Deployment
* `post-render.sh` — trivial wrapper helm invokes; `helm` pipes its rendered manifest to this
  script's stdin, expects kustomized YAML on stdout

## One-time prep — remove the wrong-shape Certificate from your cluster

If your cluster still has the old `Certificate/jet-client` (the one with
`commonName: jet.jet-system.svc.cluster.local`), delete it before your first apply with this
overlay. Also delete its Secret so the reconcile loop stops:

```bash
kubectl -n jet-system delete certificate jet-client 2>/dev/null || true
kubectl -n jet-system delete secret      jet-client-tls 2>/dev/null || true
```

If the wrong Certificate came from a GitOps source, remove it from that source too — otherwise
your GitOps controller will just re-add it.

## Every install/upgrade — use the post-renderer

Wherever you run `helm install` / `helm upgrade` today, add
`--post-renderer /path/to/persistent-fix/post-render.sh`:

```bash
helm upgrade --install spectro-mgmt-plane ./spectro-mgmt-plane-4.9.18.tgz \
  --namespace hubble-system --create-namespace \
  -f values-sandbox-ecr.yaml \
  -f values-imageswap.yaml \
  --post-renderer ./runbooks/vertex-workload-cluster-provisioning/persistent-fix/post-render.sh
```

That's it. Every apply now:

1. Creates the correct `Certificate/auth-tls` in `jet-system`, which cert-manager reconciles
   into `Secret/auth-tls` with `CN=auth-service` and the auth-service SANs.
2. Patches the shipped jet Deployment (which has no wiring) to mount that secret at
   `/secrets/authtls`, use `spectro-hubble` SA, and be ready for the mTLS gate on jet ≥4.9.10.

No cert-manager reconcile loop — the Certificate spec matches what auth-service expects, so
the Secret is stable. No helm reconcile loop — the wiring is part of the rendered manifest
helm just applied.

## Verify after each upgrade

```bash
# Deployment mounts auth-tls (not jet-client-tls)
kubectl -n jet-system get deploy jet -o json \
  | jq '.spec.template.spec.volumes[] | select(.name=="authtls") | .secret.secretName'
# → "auth-tls"

# CN is correct
kubectl -n jet-system get secret auth-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject
# → CN=auth-service

# auth-service is quiet
kubectl -n hubble-system logs deploy/auth --tail=200 --since=3m | grep -iE 'tls|certificate required'
# → empty
```

## Path B — GitOps (Argo/Flux)

Same YAML files, different wiring. Two workable patterns:

* **Argo `Application` with the chart PLUS a second `Application` that applies the overlay** —
  the second Application manages `certificate-jet-authtls.yaml` + a kustomize patch that gets
  applied to the jet Deployment. Argo's sync waves ensure the Certificate comes up before the
  jet Deployment tries to mount it.
* **Argo/Flux with a `helm.postRenderer` field** — Argo 2.7+ supports post-renderers via
  `spec.source.plugin` or a custom plugin. Flux HelmRelease supports `postRenderers` natively:

  ```yaml
  apiVersion: helm.toolkit.fluxcd.io/v2
  kind: HelmRelease
  metadata:
    name: spectro-mgmt-plane
  spec:
    postRenderers:
      - kustomize:
          patches:
            - target:
                kind: Deployment
                name: jet
                namespace: jet-system
              patch: |
                <contents of patch-jet-deployment.yaml>
          resources:
            - <path to certificate-jet-authtls.yaml>
  ```

## Why this is the fix, not a workaround

* **Certificate CN matches what auth-service authorizes** — `CN=auth-service`, same as
  `hubble-system/auth-tls`. The CA (`hubble-intermicrosvccom-ca-issuer`) is the same one
  auth-service trusts. Handshake passes on first try.
* **cert-manager owns the `Secret/auth-tls` in `jet-system`, but its Certificate spec is
  correct**, so reconciles don't undo anything. Every rotation just refreshes with the same
  CN/SANs.
* **The volume+mount is applied by helm itself** (via the post-renderer), so it's part of the
  chart-managed state. Helm's next `upgrade` reconciles TO this state, not away from it.
* **No new operator or controller required.** cert-manager is already there. FIPS-compatible,
  airgap-portable, no additional images to mirror. If you also want reflector for cross-
  namespace secret hygiene elsewhere in your platform, add it — but you don't need it for
  this fix.

## Ownership

The mgmt-plane chart still doesn't ship this wiring. This bundle is a **customer-side
workaround** while we chase the chart fix upstream (PCP-7290 / PSQA-426 / PCP-6661). Once the
chart provisions the Certificate + Deployment patch itself, the overlay becomes a no-op and
can be removed.
