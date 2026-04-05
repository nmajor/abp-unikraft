#!/bin/bash
# Automated Hetzner build orchestrator for ABP Stealth.
#
# This script:
#   1. Creates a Hetzner CCX43 VM
#   2. Waits for SSH access
#   3. Uploads the build script
#   4. Runs the build remotely (4-6 hours)
#   5. Downloads the artifact
#   6. Destroys the VM (cost safeguard)
#
# Prerequisites:
#   - HETZNER_API_TOKEN env var set
#   - SSH key at ~/.ssh/id_ed25519
#   - gh CLI authenticated (for release upload)
#
# Usage:
#   ./scripts/hetzner-build.sh
#
# The script has multiple safeguards to ensure the VM is always destroyed:
#   - trap on EXIT always deletes the server
#   - 6-hour timeout kills the build if stuck
#   - Remote script auto-poweroff after completion
#
# Cost: CCX43 (16 cores, 64GB) ≈ €0.085/hr ≈ €0.50 for a 6-hour build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
HETZNER_API="${HETZNER_API_TOKEN:?Set HETZNER_API_TOKEN in your environment}"
SERVER_TYPE="${HETZNER_SERVER_TYPE:-ccx43}"   # 16 cores, 64GB RAM
SERVER_IMAGE="${HETZNER_IMAGE:-ubuntu-22.04}"
SERVER_LOCATION="${HETZNER_LOCATION:-fsn1}"   # Falkenstein (cheapest)
SERVER_NAME="abp-build-$(date +%Y%m%d-%H%M%S)"
SSH_KEY_NAME="abp-build-key"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
MAX_BUILD_HOURS=6
BUILD_TIMEOUT=$((MAX_BUILD_HOURS * 3600))
LOCAL_GH_TOKEN="${GH_TOKEN:-}"

# State file for cleanup
STATE_FILE="/tmp/hetzner-build-${SERVER_NAME}.state"

hetzner_api() {
    local method="$1" endpoint="$2"
    shift 2
    curl -s -X "${method}" \
        -H "Authorization: Bearer ${HETZNER_API}" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1${endpoint}" "$@"
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

resolve_github_token() {
    if [ -n "${LOCAL_GH_TOKEN}" ]; then
        return 0
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        LOCAL_GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
    [ -n "${LOCAL_GH_TOKEN}" ]
}

run_local_preflight() {
    log "Running local repo preflight gauntlet..."
    bash "${PROJECT_DIR}/scripts/preflight-fp-chromium-build.sh" repo "${PROJECT_DIR}"
}

# ===================================================================
# CLEANUP — always destroy the server, no matter what happens
# ===================================================================
cleanup() {
    local exit_code=$?
    if [ -f "${STATE_FILE}" ]; then
        local server_id
        server_id=$(cat "${STATE_FILE}")
        log "CLEANUP: Destroying server ${server_id} (${SERVER_NAME})..."
        hetzner_api DELETE "/servers/${server_id}" > /dev/null 2>&1 || true
        rm -f "${STATE_FILE}"
        log "CLEANUP: Server destroyed. No ongoing Hetzner charges."
    fi
    if [ ${exit_code} -ne 0 ]; then
        log "Build exited with code ${exit_code}"
    fi
}
trap cleanup EXIT

# ===================================================================
# Step 1: Find SSH key ID
# ===================================================================
run_local_preflight

log "Finding SSH key..."
SSH_KEY_ID=$(hetzner_api GET "/ssh_keys?name=${SSH_KEY_NAME}" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ssh_keys'][0]['id'])" 2>/dev/null || echo "")

if [ -z "${SSH_KEY_ID}" ]; then
    log "ERROR: SSH key '${SSH_KEY_NAME}' not found in Hetzner. Upload it first."
    exit 1
fi
log "SSH key ID: ${SSH_KEY_ID}"

# ===================================================================
# Step 2: Create server
# ===================================================================
log "Creating ${SERVER_TYPE} server '${SERVER_NAME}' in ${SERVER_LOCATION}..."
CREATE_RESPONSE=$(hetzner_api POST "/servers" -d "{
    \"name\": \"${SERVER_NAME}\",
    \"server_type\": \"${SERVER_TYPE}\",
    \"image\": \"${SERVER_IMAGE}\",
    \"location\": \"${SERVER_LOCATION}\",
    \"ssh_keys\": [${SSH_KEY_ID}],
    \"start_after_create\": true
}")

SERVER_ID=$(echo "${CREATE_RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['id'])" 2>/dev/null || echo "")
SERVER_IP=$(echo "${CREATE_RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])" 2>/dev/null || echo "")

if [ -z "${SERVER_ID}" ] || [ -z "${SERVER_IP}" ]; then
    log "ERROR: Failed to create server. Response:"
    echo "${CREATE_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${CREATE_RESPONSE}"
    exit 1
fi

# Save server ID for cleanup trap
echo "${SERVER_ID}" > "${STATE_FILE}"

log "Server created: ID=${SERVER_ID}, IP=${SERVER_IP}"
log "Cost: ~€0.085/hr. Will be destroyed automatically on completion or failure."

# ===================================================================
# Step 3: Wait for SSH
# ===================================================================
log "Waiting for SSH access..."
for i in $(seq 1 60); do
    if ssh ${SSH_OPTS} "root@${SERVER_IP}" "echo ready" 2>/dev/null; then
        log "SSH ready after ${i} attempts."
        break
    fi
    if [ "$i" -eq 60 ]; then
        log "ERROR: SSH not available after 60 attempts. Cleaning up."
        exit 1
    fi
    sleep 5
done

# ===================================================================
# Step 4: Upload build script and project files
# ===================================================================
log "Uploading build files..."

# Upload the build script
scp ${SSH_OPTS} "${SCRIPT_DIR}/build-on-fp-chromium.sh" "root@${SERVER_IP}:/root/build-on-fp-chromium.sh"

# Upload stealth-extra and feature edit scripts
scp ${SSH_OPTS} "${SCRIPT_DIR}/verify-abp-overlay-contract.sh" "root@${SERVER_IP}:/root/verify-abp-overlay-contract.sh"
scp ${SSH_OPTS} "${SCRIPT_DIR}/apply-stealth-extra-edits.sh" "root@${SERVER_IP}:/root/apply-stealth-extra-edits.sh"
scp ${SSH_OPTS} "${SCRIPT_DIR}/apply-feature-edits.sh" "root@${SERVER_IP}:/root/apply-feature-edits.sh"

# Upload stealth-extra patches (for reference, edits script is primary)
scp ${SSH_OPTS} -r "${PROJECT_DIR}/patches/stealth-extra" "root@${SERVER_IP}:/root/stealth-extra-patches/"

if resolve_github_token; then
    log "Uploading GitHub token for unattended release upload..."
    TOKEN_FILE=$(mktemp)
    chmod 600 "${TOKEN_FILE}"
    printf '%s' "${LOCAL_GH_TOKEN}" > "${TOKEN_FILE}"
    scp ${SSH_OPTS} "${TOKEN_FILE}" "root@${SERVER_IP}:/root/.gh_token"
    rm -f "${TOKEN_FILE}"
else
    log "WARNING: No GH_TOKEN env var or gh auth token available locally."
    log "Remote build will not be able to create a GitHub release unattended."
fi

log "Files uploaded."

# ===================================================================
# Step 5: Run build with timeout
# ===================================================================
log "Starting build (timeout: ${MAX_BUILD_HOURS}h)..."
log "You can monitor progress with: ssh ${SSH_OPTS} root@${SERVER_IP} 'tail -f /root/build.log'"

# Run build in background on remote with nohup, stream to log file.
# The build script expects to be run from the repo dir, so we set up
# the repo clone as part of the build itself.
ssh ${SSH_OPTS} "root@${SERVER_IP}" bash -s << 'REMOTE_SCRIPT'
set -e

# Disable the auto-poweroff at the end of build-on-fp-chromium.sh
# (we handle cleanup from the orchestrator side)
export SKIP_POWEROFF=1

cat > /root/run-build.sh << 'BUILDWRAPPER'
#!/bin/bash
set -euo pipefail

exec > >(tee /root/build.log) 2>&1

echo "=== Build started at $(date) ==="
echo "=== Host: $(hostname), $(nproc) cores, $(free -h | awk '/Mem:/{print $2}') RAM ==="

if [ -f /root/.gh_token ]; then
    export GH_TOKEN="$(cat /root/.gh_token)"
    chmod 600 /root/.gh_token
fi

# Clone the repo (contains our scripts)
if [ ! -d /root/abp-unikraft ]; then
    apt-get update && apt-get install -y git curl
    # Install gh CLI
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update && apt-get install -y gh
    git clone https://github.com/nmajor/abp-unikraft.git /root/abp-unikraft
fi

# Run the actual build
chmod +x /root/abp-unikraft/scripts/build-on-fp-chromium.sh
bash /root/abp-unikraft/scripts/build-on-fp-chromium.sh

echo "=== Build completed at $(date) ==="
BUILDWRAPPER

chmod +x /root/run-build.sh
nohup /root/run-build.sh &
echo $! > /root/build.pid
echo "Build PID: $(cat /root/build.pid)"
REMOTE_SCRIPT

log "Build started remotely. PID saved."

# ===================================================================
# Step 6: Monitor build with timeout
# ===================================================================
BUILD_START=$(date +%s)
log "Monitoring build progress..."

while true; do
    ELAPSED=$(( $(date +%s) - BUILD_START ))

    # Check timeout
    if [ ${ELAPSED} -gt ${BUILD_TIMEOUT} ]; then
        log "ERROR: Build exceeded ${MAX_BUILD_HOURS}h timeout. Killing."
        ssh ${SSH_OPTS} "root@${SERVER_IP}" "kill \$(cat /root/build.pid) 2>/dev/null || true" 2>/dev/null || true
        exit 1
    fi

    # Check if build process is still running
    BUILD_ALIVE=$(ssh ${SSH_OPTS} "root@${SERVER_IP}" \
        "kill -0 \$(cat /root/build.pid 2>/dev/null) 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")

    if [ "${BUILD_ALIVE}" = "no" ]; then
        # Build finished — check if it succeeded
        BUILD_EXIT=$(ssh ${SSH_OPTS} "root@${SERVER_IP}" \
            "tail -5 /root/build.log 2>/dev/null" 2>/dev/null || echo "unknown")
        log "Build finished after $((ELAPSED / 60)) minutes."
        log "Last output: ${BUILD_EXIT}"

        if echo "${BUILD_EXIT}" | grep -q "ALL DONE"; then
            log "BUILD SUCCEEDED!"
            # Get the release tag
            RELEASE_TAG=$(ssh ${SSH_OPTS} "root@${SERVER_IP}" \
                "grep 'Release:' /root/build.log | tail -1 | awk '{print \$NF}'" 2>/dev/null || echo "unknown")
            log "Release: ${RELEASE_TAG}"
        else
            log "BUILD FAILED. Fetching log tail..."
            ssh ${SSH_OPTS} "root@${SERVER_IP}" "tail -50 /root/build.log" 2>/dev/null || true
            exit 1
        fi
        break
    fi

    # Print progress every 5 minutes
    HOURS=$((ELAPSED / 3600))
    MINS=$(( (ELAPSED % 3600) / 60 ))
    LAST_LINE=$(ssh ${SSH_OPTS} "root@${SERVER_IP}" \
        "tail -1 /root/build.log 2>/dev/null" 2>/dev/null || echo "...")
    log "[${HOURS}h${MINS}m] ${LAST_LINE}"

    sleep 300  # Check every 5 minutes
done

# ===================================================================
# Step 7: Server destruction happens automatically via trap
# ===================================================================
log "Server will be destroyed by cleanup trap."
log "Done!"
