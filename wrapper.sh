#!/bin/bash
set -e

ABP_PORT="${ABP_PORT:-15678}"
ABP_BINARY="/opt/abp/abp-chrome/abp"

echo "Starting ABP on port ${ABP_PORT}..."

exec "${ABP_BINARY}" \
    --abp-port="${ABP_PORT}" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-software-rasterizer \
    --use-mock-keychain \
    --user-data-dir=/tmp/abp-data \
    --abp-session-dir=/tmp/abp-sessions \
    --abp-window-size=1280,800 \
    --disable-background-networking \
    --disable-default-apps \
    --disable-extensions \
    --disable-sync \
    --no-first-run \
    --disable-translate
