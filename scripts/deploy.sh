#!/bin/bash
# Deploy ABP unikernel to KraftCloud
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

METRO="${UKC_METRO:-fra0}"
MEMORY="${ABP_MEMORY:-4096}"
INSTANCE_NAME="${ABP_INSTANCE_NAME:-abp-unikraft}"

cd "${PROJECT_DIR}"

echo "==> Deploying ABP unikernel to KraftCloud (metro: ${METRO})"

kraft cloud deploy \
    --metro "${METRO}" \
    --name "${INSTANCE_NAME}" \
    --scale-to-zero \
    -p 443:15678 -p 1080:1080 \
    -M "${MEMORY}" \
    .

echo ""
echo "==> Deployment complete!"
echo "    The ABP REST API is available at the FQDN shown above on port 443."
echo "    Test with: curl https://<fqdn>/api/v1/browser/status"
