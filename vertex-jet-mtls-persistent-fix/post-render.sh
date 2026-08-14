#!/usr/bin/env bash
# helm post-renderer wrapper.
#
# helm invokes this script per-release: pipes its rendered manifest to stdin, expects
# transformed YAML on stdout. We stage the helm output + the two neighboring overlay
# files (Certificate CR + Deployment strategic-merge patch) in a temp dir, generate a
# single kustomization.yaml that composes them, then run kustomize build.
#
# Why inline the kustomization instead of using a separate overlay dir: patches only
# resolve if their target lives in the same accumulation. helm's rendered Deployment/jet
# lives in `all.yaml`, so the patch must be listed in the same kustomization that
# includes `all.yaml`.
#
# Requires: kustomize on PATH.

set -euo pipefail

# Resolve the directory this script lives in (works from symlinks, spaces in path, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Capture helm's rendered manifest from stdin
cat > "$STAGE/all.yaml"

# 2. Copy overlay files (Certificate + patch) into the same dir
cp "$SCRIPT_DIR/certificate-jet-authtls.yaml" \
   "$SCRIPT_DIR/patch-jet-deployment.yaml" \
   "$STAGE/"

# 3. Write the composed kustomization inline. all.yaml supplies Deployment/jet; the patch
#    below finds it there because it's part of the same accumulation.
cat > "$STAGE/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - all.yaml
  - certificate-jet-authtls.yaml
patches:
  - path: patch-jet-deployment.yaml
EOF

kustomize build "$STAGE"
