#!/bin/bash
# Deploy ABP unikernel to KraftCloud
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

METRO="${UKC_METRO:-fra0}"
MEMORY="${ABP_MEMORY:-4096}"
INSTANCE_NAME="${ABP_INSTANCE_NAME:-abp-unikraft}"
RUNTIME="${ABP_RUNTIME:-index.unikraft.io/official/base-compat:latest}"

cd "${PROJECT_DIR}"

echo "==> Deploying ABP unikernel to KraftCloud (metro: ${METRO})"

KRAFT_TOKEN_ARGS=()

if [ -n "${UKC_TOKEN:-}" ]; then
    DECODED="$(printf '%s' "${UKC_TOKEN}" | base64 -d)"
    UKC_USER="${DECODED%%:*}"
    UKC_PASS="${DECODED#*:}"

    env -u UKC_TOKEN kraft login --user "${UKC_USER}" --token "${UKC_PASS}" index.unikraft.io >/dev/null
    env -u UKC_TOKEN kraft login --user "${UKC_USER}" --token "${UKC_PASS}" "api.${METRO}.kraft.cloud" >/dev/null
    KRAFT_TOKEN_ARGS=(--token "${UKC_PASS}")
fi

env -u UKC_TOKEN kraft cloud deploy \
    "${KRAFT_TOKEN_ARGS[@]}" \
    --metro "${METRO}" \
    --name "${INSTANCE_NAME}" \
    --runtime "${RUNTIME}" \
    --scale-to-zero idle \
    --scale-to-zero-stateful \
    --scale-to-zero-cooldown 5s \
    --compress \
    --restart on-failure \
    -p 443:15678/http+tls -p 1080:1080/tls \
    -M "${MEMORY}" \
    --no-prompt \
    .

echo ""
echo "==> Deployment complete!"
echo "    The ABP REST API is available at the FQDN shown above on port 443."
echo "    Test with: curl https://<fqdn>/api/v1/browser/status"
