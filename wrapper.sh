#!/bin/bash
set -e

ABP_INTERNAL_PORT=15679
EXTERNAL_PORT="${ABP_PORT:-15678}"
ABP_BINARY="/opt/abp/abp-chrome/abp"

echo "Starting ABP on internal port ${ABP_INTERNAL_PORT}..."

# Start ABP in the background (binds to 127.0.0.1 only)
"${ABP_BINARY}" \
    --abp-port="${ABP_INTERNAL_PORT}" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --use-mock-keychain \
    --user-data-dir=/tmp/abp-data \
    --abp-session-dir=/tmp/abp-sessions \
    --abp-window-size=1280,800 \
    --disable-background-networking \
    --disable-default-apps \
    --disable-extensions \
    --disable-sync \
    --no-first-run \
    --disable-translate &

ABP_PID=$!

# Wait for ABP to be ready
echo "Waiting for ABP to become ready..."
for i in $(seq 1 60); do
    if socat -u TCP:127.0.0.1:${ABP_INTERNAL_PORT},connect-timeout=1 /dev/null 2>/dev/null; then
        echo "ABP is ready after ${i}s"
        break
    fi
    sleep 1
done

# Start socat to proxy 0.0.0.0:EXTERNAL_PORT -> 127.0.0.1:ABP_INTERNAL_PORT
echo "Starting proxy on 0.0.0.0:${EXTERNAL_PORT} -> 127.0.0.1:${ABP_INTERNAL_PORT}"
socat TCP-LISTEN:${EXTERNAL_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${ABP_INTERNAL_PORT} &
PROXY_PID=$!

echo "ABP unikernel ready! API available on port ${EXTERNAL_PORT}"

# Wait for either process to exit
wait $ABP_PID $PROXY_PID
