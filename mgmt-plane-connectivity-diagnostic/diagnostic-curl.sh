#!/usr/bin/env bash
# mgmt-plane connectivity diagnostic — runs the actual GET jet would run, from a debug pod
# in the same namespace jet runs in. Prints a compact summary the network team can use.
#
# Usage:
#   ./diagnostic-curl.sh [namespace]
#   Defaults to jet-system.
#
# Requires: kubectl context pointing at a workload cluster (or mgmt cluster if diagnosing
# from there). Container image curlimages/curl must be pullable from the cluster (mirror
# it to your registry if airgap).

set -uo pipefail

NS="${1:-jet-system}"
POD="conn-diag-$$"
IMAGE="${DIAG_IMAGE:-curlimages/curl:8.10.1}"

echo "==> Reading URL fields from $NS/hubble-info"
URL=$(kubectl -n "$NS" get cm hubble-info -o jsonpath='{.data.url}' 2>/dev/null)
PORT=$(kubectl -n "$NS" get cm hubble-info -o jsonpath='{.data.apiEndpointPort}' 2>/dev/null)

if [ -z "$URL" ]; then
  echo "!! hubble-info ConfigMap missing or .data.url is empty in namespace $NS"
  echo "   This alone would break jet. Check the mgmt-plane install."
  exit 2
fi

FULL="$URL"
if [ -n "$PORT" ]; then FULL="$URL:$PORT"; fi
TARGET="https://$FULL/v1/auth/certs"

echo "   url:             $URL"
echo "   apiEndpointPort: '${PORT:-(empty, defaults to 443)}'"
echo "   effective URL:   $TARGET"

echo
echo "==> Running curl from a debug pod in $NS (mimics jet's own egress path)"

kubectl -n "$NS" run "$POD" --rm -i --restart=Never \
  --image="$IMAGE" --command --timeout=45s -- \
  sh -c '
    TARGET="'"$TARGET"'"
    echo "--- HEADERS ---"
    curl -sk -D - -o /tmp/body \
      -w "---\nstatus=%{http_code}\ncontent_type=%{content_type}\nsize=%{size_download}\nredirect_url=%{redirect_url}\nremote_ip=%{remote_ip}\n" \
      "$TARGET"

    echo "--- FIRST 400 BYTES OF BODY ---"
    head -c 400 /tmp/body
    echo

    echo "--- TLS CERTIFICATE CHAIN (issuers matter — look for corporate CAs) ---"
    echo | openssl s_client -connect "'"${FULL}"'":443 -servername "'"$URL"'" 2>/dev/null \
      | openssl x509 -noout -subject -issuer 2>/dev/null \
      || echo "(openssl not available in image — install a fuller image or check manually)"

    echo "--- PROXY / INTERMEDIARY SIGNATURES ---"
    grep -iE "via:|x-forwarded|x-proxy|server:|zscaler|netskope|iboss|prisma|forcepoint|bluecoat|cloudflare|akamai|mcafee|squid" /tmp/body 2>/dev/null \
      || echo "(no obvious proxy vendor strings in body)"
  '

RC=$?
echo
echo "==> Diagnostic complete (exit $RC)"
echo
echo "Match your response against runbook README.md — Mode 1 / Mode 2 / Mode 3 sections."
echo "If Mode 2 (proxy interception), the ask for the network team is in PREFLIGHT-QUESTIONS.md."
