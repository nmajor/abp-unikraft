#!/bin/bash
# Hetzner watchdog for long-running ABP Chromium builds.
#
# This script is designed to be run manually or from cron every 15 minutes.
# It keeps a single Hetzner build in flight, polls progress, generates a
# Codex-ready handoff prompt, optionally invokes Codex, and tears down the VM
# on success or failure.
#
# Commands:
#   cycle          Start or poll the build, retry on crash if allowed.
#   start          Alias for cycle.
#   status         Print the current watchdog state and build tail.
#   prompt         Render the current handoff prompt to stdout.
#   cleanup        Destroy the remote Hetzner VM and clear local state.
#   install-cron   Install a 15-minute cron entry that runs cycle.
#   uninstall-cron Remove the watchdog cron entry.
#
# Environment:
#   HETZNER_API_TOKEN   Required. Can also be loaded from ~/.zshrc.
#   GH_TOKEN            Optional. Falls back to `gh auth token` locally.
#   WATCHDOG_*          See the constants below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.cache/abp-watchdog}"
STATE_FILE="${WATCHDOG_STATE_FILE:-$STATE_DIR/state.env}"
PROMPT_FILE="${WATCHDOG_PROMPT_FILE:-$STATE_DIR/prompt.md}"
LOG_FILE="${WATCHDOG_LOG_FILE:-$STATE_DIR/watchdog.log}"
CRON_LOG_FILE="${WATCHDOG_CRON_LOG_FILE:-$STATE_DIR/cron.log}"
AUDIT_LOG_FILE="${WATCHDOG_AUDIT_LOG_FILE:-$STATE_DIR/audit.log}"
LOCK_DIR="${WATCHDOG_LOCK_DIR:-$STATE_DIR/lock}"
CYCLE_LOG_DIR="${WATCHDOG_CYCLE_LOG_DIR:-$STATE_DIR/checks}"

HETZNER_API="${HETZNER_API_TOKEN:-}"
GH_TOKEN="${GH_TOKEN:-}"
WATCHDOG_SERVER_TYPE="${WATCHDOG_SERVER_TYPE:-cpx51}"
WATCHDOG_SERVER_LOCATION="${WATCHDOG_SERVER_LOCATION:-ash}"
WATCHDOG_SERVER_IMAGE="${WATCHDOG_SERVER_IMAGE:-ubuntu-22.04}"
WATCHDOG_SERVER_NAME_PREFIX="${WATCHDOG_SERVER_NAME_PREFIX:-abp-watchdog}"
WATCHDOG_SSH_KEY_NAME="${WATCHDOG_SSH_KEY_NAME:-abp-build-key}"
WATCHDOG_REPO_URL="${WATCHDOG_REPO_URL:-https://github.com/nmajor/abp-unikraft.git}"
WATCHDOG_REPO_REF="${WATCHDOG_REPO_REF:-main}"
WATCHDOG_FP_CHROMIUM_TAG="${WATCHDOG_FP_CHROMIUM_TAG:-142.0.7444.175}"
WATCHDOG_ABP_BRANCH="${WATCHDOG_ABP_BRANCH:-dev}"
WATCHDOG_MAX_RETRIES="${WATCHDOG_MAX_RETRIES:-2}"
WATCHDOG_AUTO_RETRY="${WATCHDOG_AUTO_RETRY:-1}"
WATCHDOG_SSH_TIMEOUT="${WATCHDOG_SSH_TIMEOUT:-10}"
WATCHDOG_FLOW_TIMEOUT_HOURS="${WATCHDOG_FLOW_TIMEOUT_HOURS:-24}"
WATCHDOG_RUN_CODEX="${WATCHDOG_RUN_CODEX:-1}"
WATCHDOG_CODEX_MODEL="${WATCHDOG_CODEX_MODEL:-gpt-5}"
WATCHDOG_CODEX_TIMEOUT_SECONDS="${WATCHDOG_CODEX_TIMEOUT_SECONDS:-600}"
WATCHDOG_CODEX_SEARCH="${WATCHDOG_CODEX_SEARCH:-1}"
WATCHDOG_POST_BUILD_SMOKE_URLS="${WATCHDOG_POST_BUILD_SMOKE_URLS:-https://google.com https://www.olx.pt}"
WATCHDOG_BOOTSTRAP_TIMEOUT_MINUTES="${WATCHDOG_BOOTSTRAP_TIMEOUT_MINUTES:-30}"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout="${WATCHDOG_SSH_TIMEOUT}"
    -o LogLevel=ERROR
)

usage() {
    cat <<EOF
Usage: $0 [cycle|start|status|prompt|cleanup|install-cron|uninstall-cron]

State dir: ${STATE_DIR}
Remote base image: ${WATCHDOG_SERVER_IMAGE}
Default server type: ${WATCHDOG_SERVER_TYPE}
Default fp-chromium tag: ${WATCHDOG_FP_CHROMIUM_TAG}
Flow timeout hours: ${WATCHDOG_FLOW_TIMEOUT_HOURS}
EOF
}

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

audit_log() {
    ensure_state_dir
    printf '[%s] phase=%s status=%s server=%s ip=%s retry=%s release=%s :: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${WATCHDOG_PHASE:-}" \
        "${WATCHDOG_LAST_STATUS:-}" \
        "${WATCHDOG_SERVER_NAME:-}" \
        "${WATCHDOG_SERVER_IP:-}" \
        "${WATCHDOG_RETRY_COUNT:-0}" \
        "${WATCHDOG_RELEASE_TAG:-}" \
        "$*" >> "${AUDIT_LOG_FILE}"
}


# Save full remote build log for postmortem before cleanup.
save_remote_log() {
    if [ -z "${WATCHDOG_SERVER_IP:-}" ]; then
        return 0
    fi
    ensure_state_dir
    local ts target tmp
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    target="${STATE_DIR}/remote-build-${ts}.log"
    tmp="$(mktemp)"
    # Try to fetch the whole log; fall back to tail if it is huge.
    if ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "test -f /root/watchdog-build.log" >/dev/null 2>&1; then
        ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}"             "wc -c < /root/watchdog-build.log" >"${tmp}" 2>/dev/null || true
        local size
        size=$(cat "${tmp}" 2>/dev/null || echo 0)
        # Cap at ~5 MiB to avoid huge state files.
        if [ "${size}" -gt 5242880 ]; then
            ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}"                 "tail -c 5242880 /root/watchdog-build.log" >"${target}" 2>/dev/null || true
        else
            ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}"                 "cat /root/watchdog-build.log" >"${target}" 2>/dev/null || true
        fi
        rm -f "${tmp}"
        if [ -s "${target}" ]; then
            log "Saved remote build log to ${target}"
        else
            rm -f "${target}"
        fi
    fi
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2
    exit 1
}

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
    mkdir -p "${CYCLE_LOG_DIR}"
}

acquire_lock() {
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        log "Another watchdog cycle is already running."
        exit 0
    fi
    trap 'rm -rf "${LOCK_DIR}"' EXIT
}

load_env_from_zshrc() {
    local token_line token_value
    if [ ! -f "$HOME/.zshrc" ]; then
        return 0
    fi

    if [ -z "${HETZNER_API}" ]; then
        token_line="$(grep '^export HETZNER_API_TOKEN=' "$HOME/.zshrc" | tail -n1 || true)"
        token_value="${token_line#export HETZNER_API_TOKEN=}"
        token_value="${token_value%\"}"
        token_value="${token_value#\"}"
        token_value="${token_value%\'}"
        token_value="${token_value#\'}"
        if [ -n "${token_value}" ] && [ "${token_value}" != "${token_line}" ]; then
            HETZNER_API="${token_value}"
        fi
    fi

    if [ -z "${GH_TOKEN}" ]; then
        token_line="$(grep '^export GH_TOKEN=' "$HOME/.zshrc" | tail -n1 || true)"
        token_value="${token_line#export GH_TOKEN=}"
        token_value="${token_value%\"}"
        token_value="${token_value#\"}"
        token_value="${token_value%\'}"
        token_value="${token_value#\'}"
        if [ -n "${token_value}" ] && [ "${token_value}" != "${token_line}" ]; then
            GH_TOKEN="${token_value}"
        fi
    fi
}

resolve_github_token() {
    if [ -n "${GH_TOKEN}" ]; then
        return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
}

require_credentials() {
    load_env_from_zshrc
    resolve_github_token

    if [ -z "${HETZNER_API}" ]; then
        die "HETZNER_API_TOKEN is missing. Export it or load a shell that sources ~/.zshrc."
    fi
    if [ -z "${GH_TOKEN}" ]; then
        die "GitHub auth is missing. Set GH_TOKEN or authenticate gh locally."
    fi
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
        die "ssh, scp, curl, gh, python3, and grep are required."
    fi
    if [ "${WATCHDOG_RUN_CODEX}" = "1" ] && ! command -v codex >/dev/null 2>&1; then
        die "codex CLI is required when WATCHDOG_RUN_CODEX=1."
    fi
}

state_write() {
    cat > "${STATE_FILE}" <<EOF
WATCHDOG_PHASE="${WATCHDOG_PHASE:-}"
WATCHDOG_SERVER_ID="${WATCHDOG_SERVER_ID:-}"
WATCHDOG_SERVER_IP="${WATCHDOG_SERVER_IP:-}"
WATCHDOG_SERVER_NAME="${WATCHDOG_SERVER_NAME:-}"
WATCHDOG_REMOTE_BUILD_PID="${WATCHDOG_REMOTE_BUILD_PID:-}"
WATCHDOG_RETRY_COUNT="${WATCHDOG_RETRY_COUNT:-0}"
WATCHDOG_LAST_STATUS="${WATCHDOG_LAST_STATUS:-}"
WATCHDOG_RELEASE_TAG="${WATCHDOG_RELEASE_TAG:-}"
WATCHDOG_STARTED_AT="${WATCHDOG_STARTED_AT:-}"
WATCHDOG_STARTED_AT_EPOCH="${WATCHDOG_STARTED_AT_EPOCH:-}"
WATCHDOG_LAST_CHECK_AT="${WATCHDOG_LAST_CHECK_AT:-}"
WATCHDOG_REPO_SHA="${WATCHDOG_REPO_SHA:-}"
WATCHDOG_REPO_DIRTY="${WATCHDOG_REPO_DIRTY:-}"
WATCHDOG_BOOTSTRAP_STATUS="${WATCHDOG_BOOTSTRAP_STATUS:-}"
WATCHDOG_LAST_CYCLE_ID="${WATCHDOG_LAST_CYCLE_ID:-}"
EOF
}

state_load() {
    if [ -f "${STATE_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
    fi
}

state_clear() {
    rm -f "${STATE_FILE}" "${PROMPT_FILE}"
    WATCHDOG_PHASE=""
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_REMOTE_BUILD_PID=""
    WATCHDOG_RETRY_COUNT="0"
    WATCHDOG_LAST_STATUS=""
    WATCHDOG_RELEASE_TAG=""
    WATCHDOG_STARTED_AT=""
    WATCHDOG_STARTED_AT_EPOCH=""
    WATCHDOG_LAST_CHECK_AT=""
    WATCHDOG_REPO_SHA=""
    WATCHDOG_REPO_DIRTY=""
    WATCHDOG_BOOTSTRAP_STATUS=""
    WATCHDOG_LAST_CYCLE_ID=""
    state_write
}

git_preflight() {
    local branch remote_sha local_sha status_output
    branch="${WATCHDOG_REPO_REF}"

    if ! git -C "${PROJECT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        WATCHDOG_LAST_STATUS="project directory is not a git repository"
        state_write
        audit_log "preflight failed: project directory is not a git repository"
        log "Project directory is not a git repository: ${PROJECT_DIR}"
        return 1
    fi

    status_output="$(git -C "${PROJECT_DIR}" status --porcelain --untracked-files=all | grep -vE '^\?\? \.omc(/|$)' || true)"
    if [ -n "${status_output}" ]; then
        WATCHDOG_REPO_DIRTY="1"
        WATCHDOG_LAST_STATUS="repo has uncommitted changes"
        state_write
        audit_log "preflight failed: repo has uncommitted changes"
        log "Refusing to start watchdog from a dirty repo. Commit and push first."
        printf '%s\n' "${status_output}" >> "${LOG_FILE}"
        return 1
    fi

    git -C "${PROJECT_DIR}" fetch origin "${branch}" >/dev/null 2>&1
    local_sha="$(git -C "${PROJECT_DIR}" rev-parse HEAD)"
    remote_sha="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}")"
    if [ "${local_sha}" != "${remote_sha}" ]; then
        WATCHDOG_REPO_DIRTY="0"
        WATCHDOG_LAST_STATUS="repo is not synced to origin/${branch}"
        state_write
        audit_log "preflight failed: repo is not synced to origin/${branch}"
        log "Refusing to start watchdog until local HEAD is pushed to origin/${branch}."
        return 1
    fi

    WATCHDOG_REPO_SHA="${local_sha}"
    WATCHDOG_REPO_DIRTY="0"
    state_write
    audit_log "preflight passed for repo commit ${WATCHDOG_REPO_SHA}"
    return 0
}

write_cycle_snapshot() {
    local cycle_id snapshot_file remote_tail
    ensure_state_dir
    cycle_id="$(date -u +%Y%m%dT%H%M%SZ)"
    WATCHDOG_LAST_CYCLE_ID="${cycle_id}"
    state_write
    snapshot_file="${CYCLE_LOG_DIR}/${cycle_id}.log"
    {
        printf 'timestamp=%s\n' "${cycle_id}"
        printf 'phase=%s\n' "${WATCHDOG_PHASE:-}"
        printf 'status=%s\n' "${WATCHDOG_LAST_STATUS:-}"
        printf 'server_id=%s\n' "${WATCHDOG_SERVER_ID:-}"
        printf 'server_name=%s\n' "${WATCHDOG_SERVER_NAME:-}"
        printf 'server_ip=%s\n' "${WATCHDOG_SERVER_IP:-}"
        printf 'retry_count=%s\n' "${WATCHDOG_RETRY_COUNT:-0}"
        printf 'release_tag=%s\n' "${WATCHDOG_RELEASE_TAG:-}"
        printf 'repo_sha=%s\n' "${WATCHDOG_REPO_SHA:-}"
        printf 'repo_dirty=%s\n' "${WATCHDOG_REPO_DIRTY:-}"
        printf 'bootstrap_status=%s\n' "${WATCHDOG_BOOTSTRAP_STATUS:-}"
        printf 'started_at=%s\n' "${WATCHDOG_STARTED_AT:-}"
        printf 'last_check_at=%s\n' "${WATCHDOG_LAST_CHECK_AT:-}"
        printf '\n[git]\n'
        git -C "${PROJECT_DIR}" status --short --branch
        if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
            printf '\n[remote log tail]\n'
            remote_tail="$(remote_log_tail 80 || true)"
            printf '%s\n' "${remote_tail}"
        fi
    } > "${snapshot_file}"
}

hetzner_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    curl -sS -X "${method}" \
        -H "Authorization: Bearer ${HETZNER_API}" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1${endpoint}" "$@"
}

check_zshrc_has_token() {
    if [ -f "$HOME/.zshrc" ] && grep -q '^export HETZNER_API_TOKEN=' "$HOME/.zshrc"; then
        log "Found HETZNER_API_TOKEN export in ~/.zshrc."
    fi
}

find_ssh_key_id() {
    local response key_id
    response="$(hetzner_api GET "/ssh_keys?name=${WATCHDOG_SSH_KEY_NAME}")"
    key_id="$(printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ssh_keys"][0]["id"])' 2>/dev/null || true)"
    if [ -z "${key_id}" ]; then
        die "Hetzner SSH key '${WATCHDOG_SSH_KEY_NAME}' not found."
    fi
    printf '%s\n' "${key_id}"
}

create_server() {
    local ssh_key_id create_response
    ssh_key_id="$(find_ssh_key_id)"
    WATCHDOG_SERVER_NAME="${WATCHDOG_SERVER_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"

    log "Creating Hetzner server ${WATCHDOG_SERVER_NAME} (${WATCHDOG_SERVER_TYPE}, ${WATCHDOG_SERVER_LOCATION})..."
    create_response="$(hetzner_api POST "/servers" -d "{
        \"name\": \"${WATCHDOG_SERVER_NAME}\",
        \"server_type\": \"${WATCHDOG_SERVER_TYPE}\",
        \"image\": \"${WATCHDOG_SERVER_IMAGE}\",
        \"location\": \"${WATCHDOG_SERVER_LOCATION}\",
        \"ssh_keys\": [${ssh_key_id}],
        \"start_after_create\": true
    }")"

    WATCHDOG_SERVER_ID="$(printf '%s' "${create_response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server"]["id"])' 2>/dev/null || true)"
    WATCHDOG_SERVER_IP="$(printf '%s' "${create_response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server"]["public_net"]["ipv4"]["ip"])' 2>/dev/null || true)"
    if [ -z "${WATCHDOG_SERVER_ID}" ] || [ -z "${WATCHDOG_SERVER_IP}" ]; then
        printf '%s\n' "${create_response}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${create_response}"
        die "Failed to create Hetzner server."
    fi

    WATCHDOG_PHASE="provisioning"
    WATCHDOG_BOOTSTRAP_STATUS="server created"
    WATCHDOG_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    WATCHDOG_STARTED_AT_EPOCH="$(date -u +%s)"
    state_write
    audit_log "created Hetzner server"
    log "Server ready: ${WATCHDOG_SERVER_ID} @ ${WATCHDOG_SERVER_IP}"
}

cleanup_server() {
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 0
    fi

    log "Destroying Hetzner server ${WATCHDOG_SERVER_ID} (${WATCHDOG_SERVER_NAME:-unknown})..."
    hetzner_api DELETE "/servers/${WATCHDOG_SERVER_ID}" >/dev/null 2>&1 || true
    audit_log "destroyed Hetzner server"
}

server_exists() {
    local response
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 1
    fi
    response="$(hetzner_api GET "/servers/${WATCHDOG_SERVER_ID}" 2>/dev/null || true)"
    printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("server") else 1)' >/dev/null 2>&1
}

wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 60); do
        if ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "echo ready" >/dev/null 2>&1; then
            log "SSH is ready."
            WATCHDOG_BOOTSTRAP_STATUS="ssh ready"
            state_write
            return 0
        fi
        sleep 5
    done
    log "SSH did not become ready in time."
    return 1
}

prepare_remote_repo() {
    log "Preparing remote repo checkout..."
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" bash -s -- \
        "${WATCHDOG_REPO_URL}" \
        "${WATCHDOG_REPO_REF}" \
        "${WATCHDOG_REPO_SHA}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_ABP_BRANCH}" \
        "${GH_TOKEN}" <<'REMOTE'
set -euo pipefail
REPO_URL="$1"
REPO_REF="$2"
REPO_SHA="$3"
FP_TAG="$4"
ABP_BRANCH="$5"
GH_TOKEN="$6"

export GH_TOKEN
export FP_CHROMIUM_TAG="${FP_TAG}"
export ABP_BRANCH="${ABP_BRANCH}"
export SKIP_POWEROFF=1

if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git curl
fi

if [ ! -d /root/abp-unikraft ]; then
    git clone --branch "${REPO_REF}" "${REPO_URL}" /root/abp-unikraft
else
    cd /root/abp-unikraft
    git fetch origin "${REPO_REF}"
fi

cd /root/abp-unikraft
git checkout --detach "${REPO_SHA}"
test "$(git rev-parse HEAD)" = "${REPO_SHA}"
chmod +x /root/abp-unikraft/scripts/build-on-fp-chromium.sh
REMOTE
    WATCHDOG_BOOTSTRAP_STATUS="repo prepared"
    state_write
}

start_remote_build() {
    log "Starting remote build..."
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" bash -s -- \
        "${GH_TOKEN}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_REPO_SHA}" <<'REMOTE'
set -euo pipefail
GH_TOKEN="$1"
FP_TAG="$2"
REPO_SHA="$3"

export GH_TOKEN
export FP_CHROMIUM_TAG="${FP_TAG}"
export ABP_REPO_SHA="${REPO_SHA}"
export SKIP_POWEROFF=1

cd /root/abp-unikraft
nohup bash ./scripts/build-on-fp-chromium.sh > /root/watchdog-build.log 2>&1 &
echo $! > /root/watchdog-build.pid
echo started
REMOTE
    WATCHDOG_REMOTE_BUILD_PID="$(ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "cat /root/watchdog-build.pid" 2>/dev/null || true)"
    WATCHDOG_PHASE="building"
    WATCHDOG_BOOTSTRAP_STATUS="build process started"
    state_write
    audit_log "started remote build"
}

remote_pid_alive() {
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" \
        "test -f /root/watchdog-build.pid && kill -0 \$(cat /root/watchdog-build.pid) >/dev/null 2>&1"
}

remote_log_tail() {
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" \
        "tail -n ${1:-40} /root/watchdog-build.log 2>/dev/null || true"
}

remote_kill_build() {
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" \
        "if [ -f /root/watchdog-build.pid ]; then kill \$(cat /root/watchdog-build.pid) 2>/dev/null || true; fi"
}

bootstrap_remote_build() {
    WATCHDOG_PHASE="bootstrapping"
    WATCHDOG_BOOTSTRAP_STATUS="waiting for ssh"
    WATCHDOG_LAST_STATUS="waiting for SSH"
    state_write
    audit_log "bootstrap waiting for SSH"
    wait_for_ssh

    WATCHDOG_BOOTSTRAP_STATUS="preparing remote repo"
    WATCHDOG_LAST_STATUS="preparing remote repo at ${WATCHDOG_REPO_SHA}"
    state_write
    audit_log "bootstrap preparing remote repo"
    prepare_remote_repo

    WATCHDOG_BOOTSTRAP_STATUS="starting remote build"
    WATCHDOG_LAST_STATUS="starting remote build"
    state_write
    audit_log "bootstrap starting remote build"
    start_remote_build
}

render_prompt() {
    ensure_state_dir
    state_load
    local log_excerpt
    if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        log_excerpt="$(remote_log_tail 40 | sed 's/^/  /' || true)"
    else
        log_excerpt="  (no active server)"
    fi
    cat > "${PROMPT_FILE}" <<EOF
# ABP Watchdog Prompt

Objective:
- Rebase and keep the ABP Chromium build on the latest validated fp-chromium base.
- Preserve ABP protocol features, bandwidth metering, and full-page screenshot support.
- Keep the native fingerprint-chromium switch contract and avoid legacy ABP stealth flag remapping.
- Improve this workflow over time: if you discover a durable fix, encode it in the repo so the next watchdog run is smoother.

Current state:
- Phase: ${WATCHDOG_PHASE:-unknown}
- Server: ${WATCHDOG_SERVER_NAME:-none}
- Server ID: ${WATCHDOG_SERVER_ID:-none}
- Server IP: ${WATCHDOG_SERVER_IP:-none}
- Repo ref: ${WATCHDOG_REPO_REF}
- Repo commit: ${WATCHDOG_REPO_SHA:-unknown}
- Retry count: ${WATCHDOG_RETRY_COUNT:-0}/${WATCHDOG_MAX_RETRIES}
- Last status: ${WATCHDOG_LAST_STATUS:-unknown}
- Release: ${WATCHDOG_RELEASE_TAG:-none}
- Source commit: ${WATCHDOG_REPO_SHA:-unknown}
- Started at: ${WATCHDOG_STARTED_AT:-unknown}
- Last check: ${WATCHDOG_LAST_CHECK_AT:-unknown}
- Bootstrap status: ${WATCHDOG_BOOTSTRAP_STATUS:-unknown}
- Smoke-test targets after deploy: ${WATCHDOG_POST_BUILD_SMOKE_URLS}

Recent build log:
${log_excerpt}

Next action:
- If the build is still running, keep watching, inspect the remote log, and only intervene if progress has stalled or a fix is required.
- If the build failed, preserve the current Hetzner VM for diagnosis, fix the repo-side issue, commit and push the fix, and let the next watchdog cycle restart on that same machine.
- If the build completed, verify the GitHub release asset, update Dockerfile to the new release tag, deploy, run deployment verification, smoke-test ${WATCHDOG_POST_BUILD_SMOKE_URLS}, and then clear the watchdog state.

Self-improvement rules:
- Do not edit the repo during a healthy running build just to "improve" the workflow. Stay read-only unless a concrete failure or missing guardrail was observed.
- Prefer durable fixes over one-off commands. Patch scripts, docs, and verification so the next run avoids the same failure.
- Record recurring Hetzner, GitHub token, upload, and compiler issues in docs/workflows/watchdog-deployment.md or docs/workflows/hetzner-build.md.
- Tighten timeouts, retries, and verification when you find a gap, but keep the workflow idempotent.
- If you do edit the repo, leave it clean and pushed before the watchdog is allowed to start another VM.
- Preserve the current Hetzner VM when a build fails unless the overall watchdog flow has exceeded ${WATCHDOG_FLOW_TIMEOUT_HOURS} hours or the user explicitly asks for cleanup.
- Stop the cron loop by uninstalling it when the workflow is in a terminal completed or failed state.
EOF
    cat "${PROMPT_FILE}"
}

run_codex_cycle() {
    if [ "${WATCHDOG_RUN_CODEX}" != "1" ]; then
        return 0
    fi

    render_prompt >/dev/null
    local last_message
    last_message="${STATE_DIR}/codex-last-message.txt"
    local codex_cmd=(codex)
    if [ "${WATCHDOG_CODEX_SEARCH}" = "1" ]; then
        codex_cmd+=(--search)
    fi
    codex_cmd+=(
        exec
        --dangerously-bypass-approvals-and-sandbox
        -C "${PROJECT_DIR}"
        -m "${WATCHDOG_CODEX_MODEL}"
        --output-last-message "${last_message}"
        -
    )
    log "Invoking Codex for watchdog cycle..."
    audit_log "starting codex cycle"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${WATCHDOG_CODEX_TIMEOUT_SECONDS}" \
            "${codex_cmd[@]}" < "${PROMPT_FILE}" >> "${LOG_FILE}" 2>&1 || true
    else
        "${codex_cmd[@]}" < "${PROMPT_FILE}" >> "${LOG_FILE}" 2>&1 || true
    fi
    audit_log "finished codex cycle"
}

reset_server_state() {
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_REMOTE_BUILD_PID=""
    WATCHDOG_BOOTSTRAP_STATUS=""
    state_write
}

handle_failure() {
    local reason="$1"
    WATCHDOG_LAST_STATUS="${reason}"
    state_write
    audit_log "${reason}"
    write_cycle_snapshot
    save_remote_log || true
    WATCHDOG_RETRY_COUNT="$((WATCHDOG_RETRY_COUNT + 1))"
    WATCHDOG_PHASE="repair_pending"
    WATCHDOG_LAST_STATUS="awaiting repo fix/push before restart on existing VM"
    state_write
    audit_log "repair pending after failure"
    log "Build failed. Preserving Hetzner server for diagnosis and restart after the next pushed fix."
    write_cycle_snapshot
    run_codex_cycle
    return 0
}

resume_bootstrap() {
    local elapsed_seconds bootstrap_timeout_seconds
    bootstrap_timeout_seconds="$((WATCHDOG_BOOTSTRAP_TIMEOUT_MINUTES * 60))"
    elapsed_seconds="$(( $(date -u +%s) - WATCHDOG_STARTED_AT_EPOCH ))"
    if [ "${elapsed_seconds}" -gt "${bootstrap_timeout_seconds}" ]; then
        handle_failure "bootstrap timed out after ${WATCHDOG_BOOTSTRAP_TIMEOUT_MINUTES} minutes"
        return 1
    fi

    if [ "${WATCHDOG_BOOTSTRAP_STATUS:-}" = "" ] || [ "${WATCHDOG_BOOTSTRAP_STATUS:-}" = "server created" ]; then
        wait_for_ssh
    fi
    if [ "${WATCHDOG_BOOTSTRAP_STATUS:-}" = "ssh ready" ]; then
        prepare_remote_repo
    fi
    if [ "${WATCHDOG_BOOTSTRAP_STATUS:-}" = "repo prepared" ]; then
        start_remote_build
    fi

    WATCHDOG_LAST_STATUS="build started"
    state_write
    write_cycle_snapshot
}

check_env() {
    if [ -f "$HOME/.zshrc" ]; then
        check_zshrc_has_token
    fi
    require_credentials
}

start_cycle() {
    ensure_state_dir
    acquire_lock
    state_load
    check_env
    WATCHDOG_LAST_CHECK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    audit_log "cycle started"
    write_cycle_snapshot

    if [ -n "${WATCHDOG_STARTED_AT_EPOCH:-}" ]; then
        local now_epoch elapsed_seconds timeout_seconds
        now_epoch="$(date -u +%s)"
        elapsed_seconds="$((now_epoch - WATCHDOG_STARTED_AT_EPOCH))"
        timeout_seconds="$((WATCHDOG_FLOW_TIMEOUT_HOURS * 3600))"
        if [ "${elapsed_seconds}" -gt "${timeout_seconds}" ]; then
            WATCHDOG_LAST_STATUS="watchdog flow timed out"
            state_write
            audit_log "watchdog flow timed out"
            log "Watchdog flow exceeded ${WATCHDOG_FLOW_TIMEOUT_HOURS}h. Killing remote job and destroying the server."
            remote_kill_build || true
            save_remote_log || true
            cleanup_server
            reset_server_state
            WATCHDOG_PHASE="failed"
            state_write
            audit_log "terminal failure after timeout"
            run_codex_cycle
            uninstall_cron >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if [ -n "${WATCHDOG_SERVER_ID:-}" ] && [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        if ! server_exists; then
            WATCHDOG_LAST_STATUS="tracked Hetzner server no longer exists"
            WATCHDOG_PHASE="repair_pending"
            state_write
            audit_log "tracked Hetzner server no longer exists"
            reset_server_state
        fi
    fi

    if [ -n "${WATCHDOG_SERVER_ID:-}" ] && [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        if [ "${WATCHDOG_PHASE:-}" = "repair_pending" ]; then
            local previous_sha new_sha
            previous_sha="${WATCHDOG_REPO_SHA:-}"
            if ! git_preflight; then
                WATCHDOG_LAST_STATUS="awaiting repo fix/push before restart on existing VM"
                state_write
                write_cycle_snapshot
                run_codex_cycle
                return 0
            fi
            new_sha="${WATCHDOG_REPO_SHA:-}"
            if [ "${new_sha}" = "${previous_sha}" ]; then
                WATCHDOG_LAST_STATUS="waiting for a newly pushed fix before restarting existing VM"
                state_write
                audit_log "repair pending; no new pushed commit yet"
                write_cycle_snapshot
                run_codex_cycle
                return 0
            fi
            WATCHDOG_LAST_STATUS="restarting build on existing VM with pushed fix ${new_sha}"
            state_write
            audit_log "restarting build on existing VM with pushed fix"
            if ! bootstrap_remote_build; then
                WATCHDOG_PHASE="repair_pending"
                WATCHDOG_LAST_STATUS="restart incomplete; existing VM preserved"
                state_write
                audit_log "restart incomplete; existing VM preserved"
                write_cycle_snapshot
                run_codex_cycle
                return 0
            fi
            WATCHDOG_LAST_STATUS="build restarted on existing VM"
            state_write
            write_cycle_snapshot
            run_codex_cycle
            return 0
        fi

        if [ "${WATCHDOG_PHASE:-}" = "provisioning" ] || [ "${WATCHDOG_PHASE:-}" = "bootstrapping" ]; then
            WATCHDOG_LAST_STATUS="resuming bootstrap"
            state_write
            audit_log "resuming bootstrap for existing server"
            if ! bootstrap_remote_build; then
                WATCHDOG_PHASE="bootstrapping"
                WATCHDOG_LAST_STATUS="bootstrap incomplete; will resume next cycle"
                state_write
                audit_log "bootstrap incomplete; leaving server running"
                write_cycle_snapshot
                run_codex_cycle
                return 0
            fi
            write_cycle_snapshot
            run_codex_cycle
            return 0
        fi

        if remote_pid_alive >/dev/null 2>&1; then
            WATCHDOG_PHASE="building"
            WATCHDOG_LAST_STATUS="remote build running"
            state_write
            audit_log "build still running"
            log "Build is still running on ${WATCHDOG_SERVER_IP}."
            remote_log_tail 20 | tee -a "${LOG_FILE}" || true
            run_codex_cycle
            return 0
        fi

        local tail_text
        tail_text="$(remote_log_tail 120 || true)"
        if printf '%s\n' "${tail_text}" | grep -q 'ALL DONE!'; then
            WATCHDOG_PHASE="completed"
            WATCHDOG_LAST_STATUS="build completed"
            WATCHDOG_RELEASE_TAG="$(printf '%s\n' "${tail_text}" | sed -n 's/.*Release: .*\/tag\/\([^ ]*\).*/\1/p' | tail -n1)"
            state_write
            audit_log "build completed"
            write_cycle_snapshot
            log "Build completed."
            if [ -n "${WATCHDOG_RELEASE_TAG:-}" ] && command -v gh >/dev/null 2>&1; then
                gh release view "${WATCHDOG_RELEASE_TAG}" --repo nmajor/abp-unikraft >/dev/null 2>&1 || true
            fi
            cleanup_server
            reset_server_state
            audit_log "cron will be removed after completion"
            printf '%s\n' "${tail_text}" | tail -n 40
            run_codex_cycle
            uninstall_cron >/dev/null 2>&1 || true
            return 0
        fi

        WATCHDOG_LAST_STATUS="build failed or stopped"
        state_write
        audit_log "build failed or stopped"
        log "Build stopped unexpectedly."
        printf '%s\n' "${tail_text}" | tail -n 80 | tee -a "${LOG_FILE}" || true
        handle_failure "build failed or stopped"
        return $?
    fi

    if ! git_preflight; then
        write_cycle_snapshot
        return 0
    fi

    WATCHDOG_RETRY_COUNT="${WATCHDOG_RETRY_COUNT:-0}"
    start_fresh_build
    audit_log "fresh build started"
    run_codex_cycle
}

start_fresh_build() {
    create_server
    if ! bootstrap_remote_build; then
        WATCHDOG_PHASE="bootstrapping"
        WATCHDOG_LAST_STATUS="bootstrap incomplete; will resume next cycle"
        state_write
        audit_log "bootstrap incomplete after fresh server creation"
        write_cycle_snapshot
        return 0
    fi
    WATCHDOG_LAST_STATUS="build started"
    state_write
    write_cycle_snapshot
    log "Remote build started. Watch log: ssh ${SSH_OPTS[*]} root@${WATCHDOG_SERVER_IP} 'tail -f /root/watchdog-build.log'"
}

status() {
    ensure_state_dir
    state_load
    cat <<EOF
Phase: ${WATCHDOG_PHASE:-unknown}
Server: ${WATCHDOG_SERVER_NAME:-none}
Server ID: ${WATCHDOG_SERVER_ID:-none}
Server IP: ${WATCHDOG_SERVER_IP:-none}
Repo ref: ${WATCHDOG_REPO_REF}
Repo commit: ${WATCHDOG_REPO_SHA:-none}
Retry count: ${WATCHDOG_RETRY_COUNT:-0}/${WATCHDOG_MAX_RETRIES}
Last status: ${WATCHDOG_LAST_STATUS:-unknown}
Release: ${WATCHDOG_RELEASE_TAG:-none}
Source commit: ${WATCHDOG_REPO_SHA:-none}
Bootstrap status: ${WATCHDOG_BOOTSTRAP_STATUS:-none}
EOF
    if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        remote_log_tail 20 || true
    fi
}

cleanup_command() {
    ensure_state_dir
    state_load
    cleanup_server
    state_clear
    uninstall_cron >/dev/null 2>&1 || true
    audit_log "manual cleanup invoked"
    log "Local watchdog state cleared."
}

uninstall_cron() {
    ensure_state_dir
    local current_crontab tmp_crontab
    current_crontab="$(crontab -l 2>/dev/null || true)"
    tmp_crontab="$(mktemp)"
    printf '%s\n' "${current_crontab}" | grep -v 'ABP watchdog deployment' > "${tmp_crontab}" || true
    crontab "${tmp_crontab}"
    rm -f "${tmp_crontab}"
    audit_log "removed watchdog cron entry"
    log "Removed watchdog cron entry."
}

install_cron() {
    ensure_state_dir
    local repo_root cron_line current_crontab tmp_crontab marker
    repo_root="${PROJECT_DIR}"
    marker="# ABP watchdog deployment"
    cron_line="*/15 * * * * cd ${repo_root} && zsh -lc 'WATCHDOG_STATE_DIR=${STATE_DIR} WATCHDOG_AUTO_RETRY=1 WATCHDOG_RUN_CODEX=1 WATCHDOG_CODEX_SEARCH=1 WATCHDOG_CODEX_TIMEOUT_SECONDS=600 ./scripts/watchdog-hetzner.sh cycle >> ${CRON_LOG_FILE} 2>&1' ${marker}"

    current_crontab="$(crontab -l 2>/dev/null || true)"
    tmp_crontab="$(mktemp)"
    printf '%s\n' "${current_crontab}" | grep -v 'ABP watchdog deployment' > "${tmp_crontab}" || true
    printf '%s\n' "${cron_line}" >> "${tmp_crontab}"
    crontab "${tmp_crontab}"
    rm -f "${tmp_crontab}"

    audit_log "installed watchdog cron entry"
    log "Installed cron entry:"
    printf '%s\n' "${cron_line}"
}

main() {
    local cmd="${1:-cycle}"
    case "${cmd}" in
        cycle|start)
            start_cycle
            ;;
        status)
            status
            ;;
        prompt)
            render_prompt
            ;;
        cleanup)
            cleanup_command
            ;;
        install-cron)
            install_cron
            ;;
        uninstall-cron)
            uninstall_cron
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
