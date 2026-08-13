#!/usr/bin/env bash
# helm post-renderer wrapper.
#
# helm invokes this script per-release: it pipes its rendered manifest to stdin and expects
# transformed YAML on stdout. We pipe stdin into a temp directory, run kustomize with the
# neighboring overlay, and stream the result out.
#
# Requires: kustomize on PATH.

set -euo pipefail

# Resolve the directory this script lives in (works from symlinks, spaces in path, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# helm streams its rendered manifest on stdin; kustomize expects it on disk
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cat > "$STAGE/all.yaml"

# Build a throwaway kustomization that (1) imports the chart-rendered manifest and (2) layers
# our overlay on top. The overlay's kustomization.yaml adds the Certificate and the
# Deployment patch.
cat > "$STAGE/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - all.yaml
  - $SCRIPT_DIR
EOF

kustomize build "$STAGE"
