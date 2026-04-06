#!/bin/sh
set -e

ABP_INTERNAL_PORT=15679
EXTERNAL_PORT="${ABP_PORT:-15678}"
ABP_BINARY="/opt/abp/abp-chrome/abp"

# Stealth configuration — override via environment variables.
# These map to fingerprint-chromium's native flags.
ABP_FINGERPRINT_SEED="${ABP_FINGERPRINT_SEED:-$$}"
ABP_FINGERPRINT_PLATFORM="${ABP_FINGERPRINT_PLATFORM:-windows}"
ABP_TIMEZONE="${ABP_TIMEZONE:-America/New_York}"
ABP_FINGERPRINT_BRAND="${ABP_FINGERPRINT_BRAND:-Chrome}"
ABP_FINGERPRINT_HARDWARE_CONCURRENCY="${ABP_FINGERPRINT_HARDWARE_CONCURRENCY:-8}"
ABP_DISABLE_SPOOFING="${ABP_DISABLE_SPOOFING:-}"
ABP_WINDOW_SIZE="${ABP_WINDOW_SIZE:-1280,800}"

# Proxy configuration — set ABP_PROXY_SERVER to route all traffic through a proxy.
# Examples:
#   ABP_PROXY_SERVER=socks5://user:pass@gate.soax.com:1080
#   ABP_PROXY_SERVER=http://user:pass@proxy.example.com:8080
#
# Chrome cannot handle credentials in --proxy-server (ERR_NO_SUPPORTED_PROXIES).
# When credentials are present, we start a local gost forwarder that handles auth,
# and point Chrome at the local forwarder instead.
PROXY_ARGS=""
GOST_LOCAL_PORT=18080
if [ -n "${ABP_PROXY_SERVER:-}" ]; then
    case "${ABP_PROXY_SERVER}" in
        *@*)
        # Authenticated proxy — start local gost forwarder
        echo "  Proxy has credentials — starting local gost forwarder on :${GOST_LOCAL_PORT}"
        /usr/local/bin/gost -L "http://:${GOST_LOCAL_PORT}" -F "${ABP_PROXY_SERVER}" &
        GOST_PID=$!
        sleep 1
        # Verify gost started
        if kill -0 $GOST_PID 2>/dev/null; then
            echo "  gost forwarder running (PID ${GOST_PID})"
            PROXY_ARGS="--proxy-server=http://127.0.0.1:${GOST_LOCAL_PORT}"
        else
            echo "  WARNING: gost failed to start, falling back to direct proxy"
            PROXY_ARGS="--proxy-server=${ABP_PROXY_SERVER}"
        fi
        ;;
        *)
        # No credentials — pass directly to Chrome
        PROXY_ARGS="--proxy-server=${ABP_PROXY_SERVER}"
        ;;
    esac
    if [ -n "${ABP_PROXY_BYPASS:-}" ]; then
        PROXY_ARGS="${PROXY_ARGS} --proxy-bypass-list=${ABP_PROXY_BYPASS}"
    fi
fi

# Public SOCKS5 proxy for CapSolver to connect through (same Decodo upstream)
GOST_PUBLIC_PORT="${ABP_GOST_PUBLIC_PORT:-1080}"
GOST_PUBLIC_USER="${ABP_GOST_PUBLIC_USER:-capsolver}"
GOST_PUBLIC_PASS="${ABP_GOST_PUBLIC_PASS:-}"

if [ -n "${GOST_PUBLIC_PASS:-}" ]; then
    case "${ABP_PROXY_SERVER:-}" in
        *@*)
            echo "  Starting public HTTP proxy on :${GOST_PUBLIC_PORT} for CapSolver"
            /usr/local/bin/gost -L "http://${GOST_PUBLIC_USER}:${GOST_PUBLIC_PASS}@:${GOST_PUBLIC_PORT}" -F "${ABP_PROXY_SERVER}" &
            GOST_PUBLIC_PID=$!
            sleep 1
            if kill -0 $GOST_PUBLIC_PID 2>/dev/null; then
                echo "  Public HTTP proxy running (PID ${GOST_PUBLIC_PID})"
            else
                echo "  WARNING: Public HTTP proxy failed to start"
            fi
            ;;
    esac
fi

echo "Starting ABP Stealth on internal port ${ABP_INTERNAL_PORT}..."
echo "  Fingerprint seed: ${ABP_FINGERPRINT_SEED}"
echo "  Platform: ${ABP_FINGERPRINT_PLATFORM}"
echo "  Brand: ${ABP_FINGERPRINT_BRAND}"
echo "  Hardware concurrency: ${ABP_FINGERPRINT_HARDWARE_CONCURRENCY}"
echo "  Timezone: ${ABP_TIMEZONE}"
echo "  Window size: ${ABP_WINDOW_SIZE}"
if [ -n "${ABP_DISABLE_SPOOFING}" ]; then
    echo "  Disable spoofing: ${ABP_DISABLE_SPOOFING}"
fi
if [ -n "${ABP_PROXY_SERVER:-}" ]; then
    echo "  Proxy: ${ABP_PROXY_SERVER}"
fi
echo "Starting proxy on 0.0.0.0:${EXTERNAL_PORT} -> 127.0.0.1:${ABP_INTERNAL_PORT}"

# Start socat proxy (ABP binds to 127.0.0.1 only)
socat TCP-LISTEN:${EXTERNAL_PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${ABP_INTERNAL_PORT} &

# Start ABP with fingerprint-chromium stealth flags.
#
# fingerprint-chromium handles: canvas, WebGL, audio, fonts, Client Hints,
# CDP detection, navigator.webdriver, GPU vendor/renderer, plugins, UA string,
# hardware concurrency, client rects, measureText, timezone.
#
# stealth-extra edits handle: pointer/hover media queries, screen properties,
# window.outerWidth/Height, navigator.deviceMemory, automation flag removal.
set -- "${ABP_BINARY}" \
    --abp-port="${ABP_INTERNAL_PORT}" \
    --fingerprint="${ABP_FINGERPRINT_SEED}" \
    --fingerprint-platform="${ABP_FINGERPRINT_PLATFORM}" \
    --fingerprint-brand="${ABP_FINGERPRINT_BRAND}" \
    --fingerprint-hardware-concurrency="${ABP_FINGERPRINT_HARDWARE_CONCURRENCY}" \
    --timezone="${ABP_TIMEZONE}" \
    --headless=new \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-non-proxied-udp \
    --use-mock-keychain \
    --user-data-dir=/tmp/abp-data \
    --abp-session-dir=/tmp/abp-sessions \
    --abp-window-size="${ABP_WINDOW_SIZE}" \
    --disable-sync \
    --no-first-run \
    --lang=en-US \
    --disable-breakpad \
    --disable-background-networking \
    --disable-component-update \
    --disable-default-apps \
    --disable-extensions \
    --disable-gpu

if [ -n "${ABP_DISABLE_SPOOFING}" ]; then
    set -- "$@" --disable-spoofing="${ABP_DISABLE_SPOOFING}"
fi

if [ -n "${PROXY_ARGS}" ]; then
    # Intentionally split two flag tokens when bypass is present.
    # shellcheck disable=SC2086
    set -- "$@" ${PROXY_ARGS}
fi

# Suppress dbus connection attempts (no system bus in unikernel).
# Use "disabled:" pseudo-address so libdbus returns immediately.
export DBUS_SESSION_BUS_ADDRESS=disabled:
export DBUS_SYSTEM_BUS_ADDRESS=disabled:

exec "$@"
