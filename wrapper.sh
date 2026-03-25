#!/bin/bash
set -e

ABP_INTERNAL_PORT=15679
EXTERNAL_PORT="${ABP_PORT:-15678}"
ABP_BINARY="/opt/abp/abp-chrome/abp"

# Stealth configuration — override via environment variables.
ABP_FINGERPRINT_SEED="${ABP_FINGERPRINT_SEED:-$RANDOM}"
ABP_FINGERPRINT_PLATFORM="${ABP_FINGERPRINT_PLATFORM:-windows}"
ABP_TIMEZONE="${ABP_TIMEZONE:-America/New_York}"

echo "Starting ABP Stealth on internal port ${ABP_INTERNAL_PORT}..."
echo "  Fingerprint seed: ${ABP_FINGERPRINT_SEED}"
echo "  Platform: ${ABP_FINGERPRINT_PLATFORM}"
echo "  Timezone: ${ABP_TIMEZONE}"
echo "Starting proxy on 0.0.0.0:${EXTERNAL_PORT} -> 127.0.0.1:${ABP_INTERNAL_PORT}"

# Start socat proxy (ABP binds to 127.0.0.1 only)
socat TCP-LISTEN:${EXTERNAL_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${ABP_INTERNAL_PORT} &

# Start ABP with stealth flags.
# Note: --disable-default-apps, --disable-extensions are intentionally REMOVED
# as they are automation telltale signals. The --abp-fingerprint flag triggers
# the C++ stealth patches to activate.
exec "${ABP_BINARY}" \
    --abp-port="${ABP_INTERNAL_PORT}" \
    --abp-fingerprint="${ABP_FINGERPRINT_SEED}" \
    --abp-fingerprint-platform="${ABP_FINGERPRINT_PLATFORM}" \
    --abp-timezone="${ABP_TIMEZONE}" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-blink-features=AutomationControlled \
    --use-mock-keychain \
    --user-data-dir=/tmp/abp-data \
    --abp-session-dir=/tmp/abp-sessions \
    --abp-window-size=1280,800 \
    --disable-sync \
    --no-first-run \
    --lang=en-US
