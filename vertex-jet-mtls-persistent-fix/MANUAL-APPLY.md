# Manual-apply path — jet ↔ auth-service mTLS fix

**Use this while we finalize the helm post-renderer.** The two YAML files in this folder are
the same content the automated script would apply. Applying them by hand fixes the immediate
problem; the trade-off is you'll need to re-apply the Deployment patch after any `helm upgrade`
of the mgmt-plane chart (the Certificate CR survives because it's not chart-managed).

## The two files you need

* `certificate-jet-authtls.yaml` — cert-manager Certificate that produces `Secret/auth-tls`
  in `jet-system`, CN=`auth-service`, signed by the same intra-microservice CA auth-service
  trusts.
* `patch-jet-deployment.yaml` — strategic merge patch that adds `serviceAccountName:
  spectro-hubble`, a volume, and a volumeMount to `Deployment/jet` in `jet-system`.

## Prerequisites

* cert-manager already in the cluster with `ClusterIssuer/hubble-intermicrosvccom-ca-issuer`
  in `Ready=True` (the mgmt-plane chart provisions this at install).
* `kubectl` ≥ 1.22 (for `--patch-file` support).
* The wrong-shape Certificate CR has been removed — see Step 1.

## Step 1 — Break the existing reconcile loop (only if you have the wrong Certificate)

If `kubectl -n jet-system get certificate jet-client` returns a Certificate with
`commonName: jet.jet-system.svc.cluster.local`, it's actively reissuing `Secret/jet-client-tls`
to a wrong-CN cert and needs to go:

```bash
kubectl -n jet-system delete certificate jet-client 2>/dev/null || true
kubectl -n jet-system delete secret      jet-client-tls 2>/dev/null || true
```

If it comes back within seconds, something in your source-of-truth (helm values, Argo App,
Flux Kustomization) is reconciling it — find and remove that too. For a plain-helm install
with no GitOps, deletion sticks.

## Step 2 — Apply the correct Certificate

```bash
kubectl apply -f certificate-jet-authtls.yaml
```

Verify cert-manager materialized the secret with the right CN:

```bash
kubectl -n jet-system get secret auth-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject
# expected: subject=O=spectrocloud, CN=auth-service
```

## Step 3 — Patch the jet Deployment to mount it

```bash
kubectl patch deployment jet -n jet-system --type=strategic \
  --patch-file=patch-jet-deployment.yaml
```

Verify the mount:

```bash
kubectl -n jet-system get deploy jet -o json \
  | jq '.spec.template.spec | {sa: .serviceAccountName,
                               volume: (.volumes[]? | select(.name=="authtls") | .secret.secretName),
                               mount:  (.containers[]?.volumeMounts[]? | select(.name=="authtls") | .mountPath)}'
# expected:
#   sa:     "spectro-hubble"
#   volume: "auth-tls"
#   mount:  "/secrets/authtls"
```

## Step 4 — Bounce jet and verify

```bash
kubectl -n jet-system rollout restart deploy/jet
kubectl -n jet-system rollout status  deploy/jet --timeout=120s

# auth-service should stop rejecting jet
kubectl -n hubble-system logs deploy/auth --tail=200 --since=3m \
  | grep -iE 'tls|certificate required'
# expected: empty

# jet should register cleanly
kubectl -n jet-system logs deploy/jet --tail=200 \
  | grep -iE 'register|heartbeat|leader|watching'
```

## What survives, what doesn't

| After a `helm upgrade` of the mgmt-plane chart | Behavior |
|---|---|
| `Certificate/auth-tls` in `jet-system` | ✅ Survives. Not chart-managed. |
| `Secret/auth-tls` in `jet-system` | ✅ Survives. cert-manager reconciles it based on the Certificate. |
| jet Deployment volume + mount + SA | ❌ Reverted. Chart re-renders the Deployment with no wiring. Re-run Step 3 after each `helm upgrade`. |

The post-renderer script (`post-render.sh` in this folder) automates Step 3 so it doesn't
have to be manually re-applied. We'll deliver that as the follow-up. It's already
dry-run-validated against the actual VerteX 4.9.18 chart.

## Rollback

If something goes wrong and you need to undo just this fix:

```bash
# Revert the Deployment to the chart's default (no wiring). Helm will restore it on next upgrade;
# for immediate revert:
kubectl -n jet-system patch deploy jet --type=strategic -p '{
  "spec":{"template":{"spec":{
    "serviceAccountName": null,
    "volumes": null,
    "containers":[{"name":"jet-manager","volumeMounts":null}]
  }}}}'

kubectl delete -f certificate-jet-authtls.yaml
```
