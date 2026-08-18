#!/usr/bin/env bash
# Verifies the split-horizon DNS fix (Path B in ../README.md — mode 2 CASB interception)
# is actually working from inside the mgmt cluster.
#
# Runs three checks:
#   1. CoreDNS resolves the mgmt-plane hostname to the Traefik ClusterIP (not the ELB IP)
#   2. A curl from jet-system to the mgmt-plane hostname now returns application/json
#   3. jet is out of CrashLoopBackOff and its logs no longer show TextConsumer errors
#
# Usage:
#   ./verify-split-horizon.sh <mgmt-plane-hostname>
#   e.g. ./verify-split-horizon.sh vertex.example.com
#
# Requires: kubectl context on the mgmt cluster; ability to pull curlimages/curl (mirror
# into the airgap registry if needed and set DIAG_IMAGE).

set -uo pipefail

HOST="${1:-}"
IMAGE="${DIAG_IMAGE:-curlimages/curl:8.10.1}"

if [ -z "$HOST" ]; then
  echo "usage: $0 <mgmt-plane-hostname>"
  echo "  (this is your config.env.rootDomain from the VerteX helm values)"
  exit 1
fi

echo "=============================================================================="
echo "Split-horizon DNS verification for: $HOST"
echo "=============================================================================="

# ---- Check 1: DNS resolution inside the cluster --------------------------------------
echo
echo "==> [1/3] Resolve $HOST from inside jet-system"
POD="dnsverify-$$"
INSIDE=$(kubectl -n jet-system run "$POD" --rm -i --restart=Never \
  --image="$IMAGE" --command --timeout=30s -- \
  sh -c "nslookup $HOST 2>/dev/null | awk '/Address:/{addr=\$2} END{print addr}'" 2>/dev/null \
  | tail -1)

echo "   inside-cluster A record: ${INSIDE:-<no answer>}"

# ---- Check 2: What does DNS say from OUTSIDE the cluster? -----------------------------
echo
echo "==> [2/3] Resolve $HOST from OUTSIDE the cluster (from your operator machine)"
OUTSIDE=$(dig +short "$HOST" 2>/dev/null | tail -1)
echo "   external A record:       ${OUTSIDE:-<no answer via dig — try nslookup>}"

# Assessment
echo
if [ -z "$INSIDE" ] || [ -z "$OUTSIDE" ]; then
  echo "   !! Could not resolve on one side or both. Investigate DNS before proceeding."
elif [ "$INSIDE" = "$OUTSIDE" ]; then
  echo "   !! Split-horizon is NOT active — inside and outside resolve to the same IP."
  echo "      If you applied coredns-split-horizon-corefile.yaml recently, restart CoreDNS:"
  echo "        kubectl -n kube-system rollout restart deploy/coredns"
elif echo "$INSIDE" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
  echo "   ✓ Split-horizon is active — inside resolves to a private (RFC1918) IP."
  echo "     Inside:  $INSIDE  (looks like Traefik ClusterIP)"
  echo "     Outside: $OUTSIDE (public ELB IP)"
else
  echo "   ?? Inside resolves to a non-private IP ($INSIDE). Confirm it's actually the"
  echo "      Traefik ClusterIP:  kubectl -n <ingress-ns> get svc traefik -o jsonpath='{.spec.clusterIP}'"
fi

# ---- Check 3: Does the actual GET now succeed? ---------------------------------------
echo
echo "==> [3/3] Actual GET from jet-system to $HOST/v1/auth/certs"
POD="respverify-$$"
kubectl -n jet-system run "$POD" --rm -i --restart=Never \
  --image="$IMAGE" --command --timeout=30s -- \
  sh -c "
    curl -sk -D - -o /tmp/body \
      -w '   --> status=%{http_code} ct=%{content_type} size=%{size_download}\n' \
      https://$HOST/v1/auth/certs
    echo '   --- first 120 bytes ---'
    head -c 120 /tmp/body
  " 2>&1 | tail -20

# ---- jet health -----------------------------------------------------------------------
echo
echo "==> jet Deployment state"
kubectl -n jet-system get deploy jet -o wide 2>&1 | tail -3

echo
echo "==> Recent jet log lines mentioning TextConsumer / auth (last 5m):"
kubectl -n jet-system logs deploy/jet --tail=200 --since=5m 2>/dev/null \
  | grep -iE "textconsumer|v1authcertsget|initauth|/v1/auth/certs" | tail -10 \
  || echo "   (nothing matching — good sign if jet is Running)"

echo
echo "=============================================================================="
echo "Interpretation:"
echo "  ✓ Check 1 shows Traefik ClusterIP, check 3 returns 200 application/json,"
echo "    and jet has no recent TextConsumer errors → split-horizon fix worked."
echo "  ✗ Check 3 still returns 3xx or text/html → check that CoreDNS was restarted,"
echo "    that jet was restarted AFTER the DNS change, and that /etc/hosts inside jet's"
echo "    pod isn't hard-coding the old external IP."
echo "=============================================================================="
