#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.cache/abp-watchdog}"
STATE_FILE="${STATE_DIR}/state.env"
PROMPT_FILE="${STATE_DIR}/prompt.md"
AUDIT_LOG_FILE="${STATE_DIR}/audit.log"
CRON_LOG_FILE="${STATE_DIR}/cron.log"
LOG_FILE="${STATE_DIR}/watchdog.log"
CHECKS_DIR="${STATE_DIR}/checks"
LOCK_DIR="${STATE_DIR}/lock"
LOCK_META_FILE="${LOCK_DIR}/meta.env"

HETZNER_API="${HETZNER_API_TOKEN:-}"
GH_TOKEN="${GH_TOKEN:-}"
WATCHDOG_CODEX_BIN="${WATCHDOG_CODEX_BIN:-/var/lib/asdf/installs/nodejs/24.8.0/bin/codex}"
WATCHDOG_CODEX_MODEL="${WATCHDOG_CODEX_MODEL:-gpt-5}"
WATCHDOG_CODEX_TIMEOUT_SECONDS="${WATCHDOG_CODEX_TIMEOUT_SECONDS:-600}"
WATCHDOG_CODEX_SEARCH="${WATCHDOG_CODEX_SEARCH:-1}"
WATCHDOG_RUN_CODEX="${WATCHDOG_RUN_CODEX:-1}"

WATCHDOG_SERVER_TYPE="${WATCHDOG_SERVER_TYPE:-cpx51}"
WATCHDOG_SERVER_LOCATION="${WATCHDOG_SERVER_LOCATION:-ash}"
WATCHDOG_SERVER_IMAGE="${WATCHDOG_SERVER_IMAGE:-ubuntu-22.04}"
WATCHDOG_SERVER_NAME_PREFIX="${WATCHDOG_SERVER_NAME_PREFIX:-abp-watchdog}"
WATCHDOG_SSH_KEY_NAME="${WATCHDOG_SSH_KEY_NAME:-abp-build-key}"
WATCHDOG_REPO_URL="${WATCHDOG_REPO_URL:-https://github.com/nmajor/abp-unikraft.git}"
WATCHDOG_REPO_REF="${WATCHDOG_REPO_REF:-main}"
WATCHDOG_FP_CHROMIUM_TAG="${WATCHDOG_FP_CHROMIUM_TAG:-142.0.7444.175}"
WATCHDOG_ABP_BRANCH="${WATCHDOG_ABP_BRANCH:-dev}"
WATCHDOG_FLOW_TIMEOUT_HOURS="${WATCHDOG_FLOW_TIMEOUT_HOURS:-24}"
WATCHDOG_LOCK_WARN_MINUTES="${WATCHDOG_LOCK_WARN_MINUTES:-60}"
WATCHDOG_LOCK_WARN_SKIPS="${WATCHDOG_LOCK_WARN_SKIPS:-4}"
WATCHDOG_SSH_TIMEOUT="${WATCHDOG_SSH_TIMEOUT:-10}"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout="${WATCHDOG_SSH_TIMEOUT}"
    -o LogLevel=ERROR
)

usage() {
    cat <<EOF
Usage: $0 [cycle|status|prompt|cleanup|install-cron|uninstall-cron]

State dir: ${STATE_DIR}
Server type: ${WATCHDOG_SERVER_TYPE}
fp-chromium tag: ${WATCHDOG_FP_CHROMIUM_TAG}
Flow timeout hours: ${WATCHDOG_FLOW_TIMEOUT_HOURS}
EOF
}

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

audit_log() {
    ensure_state_dir
    printf '[%s] phase=%s status=%s flow=%s server=%s ip=%s repair=%s release=%s :: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${WATCHDOG_PHASE:-}" \
        "${WATCHDOG_LAST_STATUS:-}" \
        "${WATCHDOG_FLOW_ID:-}" \
        "${WATCHDOG_SERVER_NAME:-}" \
        "${WATCHDOG_SERVER_IP:-}" \
        "${WATCHDOG_REPAIR_COUNT:-0}" \
        "${WATCHDOG_RELEASE_TAG:-}" \
        "$*" >> "${AUDIT_LOG_FILE}"
}

ensure_state_dir() {
    mkdir -p "${STATE_DIR}" "${CHECKS_DIR}"
}

shell_escape() {
    printf '%q' "${1:-}"
}

state_load() {
    if [ -f "${STATE_FILE}" ]; then
        local rc
        set +e
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
        rc=$?
        set -e
        if [ "${rc}" -ne 0 ]; then
            WATCHDOG_LAST_STATUS="watchdog state file is corrupt"
            return 0
        fi
    fi
    return 0
}

state_write() {
    cat > "${STATE_FILE}" <<EOF
WATCHDOG_FLOW_ID=$(shell_escape "${WATCHDOG_FLOW_ID:-}")
WATCHDOG_PHASE=$(shell_escape "${WATCHDOG_PHASE:-idle}")
WATCHDOG_SERVER_ID=$(shell_escape "${WATCHDOG_SERVER_ID:-}")
WATCHDOG_SERVER_IP=$(shell_escape "${WATCHDOG_SERVER_IP:-}")
WATCHDOG_SERVER_NAME=$(shell_escape "${WATCHDOG_SERVER_NAME:-}")
WATCHDOG_REPO_SHA=$(shell_escape "${WATCHDOG_REPO_SHA:-}")
WATCHDOG_LAST_REMOTE_PHASE=$(shell_escape "${WATCHDOG_LAST_REMOTE_PHASE:-}")
WATCHDOG_LAST_FAILURE_SUMMARY=$(shell_escape "${WATCHDOG_LAST_FAILURE_SUMMARY:-}")
WATCHDOG_RELEASE_TAG=$(shell_escape "${WATCHDOG_RELEASE_TAG:-}")
WATCHDOG_LAST_STATUS=$(shell_escape "${WATCHDOG_LAST_STATUS:-}")
WATCHDOG_STARTED_AT=$(shell_escape "${WATCHDOG_STARTED_AT:-}")
WATCHDOG_STARTED_AT_EPOCH=$(shell_escape "${WATCHDOG_STARTED_AT_EPOCH:-}")
WATCHDOG_LAST_CHECK_AT=$(shell_escape "${WATCHDOG_LAST_CHECK_AT:-}")
WATCHDOG_REPAIR_COUNT=$(shell_escape "${WATCHDOG_REPAIR_COUNT:-0}")
WATCHDOG_LAST_CYCLE_ID=$(shell_escape "${WATCHDOG_LAST_CYCLE_ID:-}")
WATCHDOG_LOCK_SKIP_COUNT=$(shell_escape "${WATCHDOG_LOCK_SKIP_COUNT:-0}")
WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=$(shell_escape "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}")
EOF
}

state_clear() {
    rm -f "${STATE_FILE}" "${PROMPT_FILE}"
    WATCHDOG_FLOW_ID=""
    WATCHDOG_PHASE="idle"
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_REPO_SHA=""
    WATCHDOG_LAST_REMOTE_PHASE=""
    WATCHDOG_LAST_FAILURE_SUMMARY=""
    WATCHDOG_RELEASE_TAG=""
    WATCHDOG_LAST_STATUS=""
    WATCHDOG_STARTED_AT=""
    WATCHDOG_STARTED_AT_EPOCH=""
    WATCHDOG_LAST_CHECK_AT=""
    WATCHDOG_REPAIR_COUNT="0"
    WATCHDOG_LAST_CYCLE_ID=""
    WATCHDOG_LOCK_SKIP_COUNT="0"
    WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=""
    state_write
}

write_cycle_snapshot() {
    local cycle_id snapshot_file remote_tail
    ensure_state_dir
    cycle_id="$(date -u +%Y%m%dT%H%M%SZ)"
    WATCHDOG_LAST_CYCLE_ID="${cycle_id}"
    state_write
    snapshot_file="${CHECKS_DIR}/${cycle_id}.log"
    {
        printf 'timestamp=%s\n' "${cycle_id}"
        printf 'flow_id=%s\n' "${WATCHDOG_FLOW_ID:-}"
        printf 'phase=%s\n' "${WATCHDOG_PHASE:-}"
        printf 'status=%s\n' "${WATCHDOG_LAST_STATUS:-}"
        printf 'server_id=%s\n' "${WATCHDOG_SERVER_ID:-}"
        printf 'server_name=%s\n' "${WATCHDOG_SERVER_NAME:-}"
        printf 'server_ip=%s\n' "${WATCHDOG_SERVER_IP:-}"
        printf 'repo_sha=%s\n' "${WATCHDOG_REPO_SHA:-}"
        printf 'remote_phase=%s\n' "${WATCHDOG_LAST_REMOTE_PHASE:-}"
        printf 'failure_summary=%s\n' "${WATCHDOG_LAST_FAILURE_SUMMARY:-}"
        printf 'repair_count=%s\n' "${WATCHDOG_REPAIR_COUNT:-0}"
        printf 'release_tag=%s\n' "${WATCHDOG_RELEASE_TAG:-}"
        printf 'last_check_at=%s\n' "${WATCHDOG_LAST_CHECK_AT:-}"
        printf 'lock_skip_count=%s\n' "${WATCHDOG_LOCK_SKIP_COUNT:-0}"
        if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
            printf '\n[remote tail]\n'
            remote_tail="$(remote_tail 80 || true)"
            printf '%s\n' "${remote_tail}"
        fi
    } > "${snapshot_file}"
}

record_lock_skip() {
    local now_epoch lock_started_epoch="" lock_age_minutes=""
    now_epoch="$(date -u +%s)"
    state_load
    WATCHDOG_LOCK_SKIP_COUNT="$(( ${WATCHDOG_LOCK_SKIP_COUNT:-0} + 1 ))"
    if [ -z "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}" ]; then
        WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH="${now_epoch}"
    fi
    if [ -f "${LOCK_META_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${LOCK_META_FILE}"
        if [ -n "${LOCK_ACQUIRED_AT_EPOCH:-}" ]; then
            lock_age_minutes="$(( (now_epoch - LOCK_ACQUIRED_AT_EPOCH) / 60 ))"
        fi
    fi
    WATCHDOG_LAST_STATUS="watchdog cycle skipped because another cycle is still running"
    state_write
    if [ -n "${lock_age_minutes}" ] && [ "${lock_age_minutes}" -ge "${WATCHDOG_LOCK_WARN_MINUTES}" ] && [ "${WATCHDOG_LOCK_SKIP_COUNT}" -ge "${WATCHDOG_LOCK_WARN_SKIPS}" ]; then
        audit_log "lock still held after ${WATCHDOG_LOCK_SKIP_COUNT} skipped cycles (~${lock_age_minutes} minutes); investigate stuck watchdog run"
        log "Another watchdog cycle is still running; lock age is ~${lock_age_minutes} minutes across ${WATCHDOG_LOCK_SKIP_COUNT} skips."
    else
        audit_log "skipped cycle because another watchdog run is active"
        if [ -n "${lock_age_minutes}" ]; then
            log "Another watchdog cycle is already running (~${lock_age_minutes} minutes old lock)."
        else
            log "Another watchdog cycle is already running."
        fi
    fi
}

acquire_lock() {
    ensure_state_dir
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        record_lock_skip
        exit 0
    fi
    cat > "${LOCK_META_FILE}" <<EOF
LOCK_PID="$$"
LOCK_ACQUIRED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOCK_ACQUIRED_AT_EPOCH="$(date -u +%s)"
EOF
    trap 'rm -rf "${LOCK_DIR}"' EXIT
}

reset_lock_skip_tracking() {
    if [ "${WATCHDOG_LOCK_SKIP_COUNT:-0}" != "0" ] || [ -n "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}" ]; then
        WATCHDOG_LOCK_SKIP_COUNT="0"
        WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=""
        state_write
    fi
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

require_credentials() {
    load_env_from_zshrc
    if [ -z "${GH_TOKEN}" ] && command -v gh >/dev/null 2>&1; then
        GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi

    [ -n "${HETZNER_API}" ] || { log "ERROR: HETZNER_API_TOKEN is missing."; exit 1; }
    [ -n "${GH_TOKEN}" ] || { log "ERROR: GitHub auth is missing."; exit 1; }
    command -v ssh >/dev/null 2>&1 || { log "ERROR: ssh is required."; exit 1; }
    command -v scp >/dev/null 2>&1 || { log "ERROR: scp is required."; exit 1; }
    command -v curl >/dev/null 2>&1 || { log "ERROR: curl is required."; exit 1; }
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 is required."; exit 1; }
    command -v grep >/dev/null 2>&1 || { log "ERROR: grep is required."; exit 1; }

    if [ "${WATCHDOG_RUN_CODEX}" = "1" ]; then
        if [ -x "${WATCHDOG_CODEX_BIN}" ]; then
            :
        elif command -v codex >/dev/null 2>&1; then
            WATCHDOG_CODEX_BIN="$(command -v codex)"
        else
            log "ERROR: codex CLI is required when WATCHDOG_RUN_CODEX=1."
            exit 1
        fi
    fi
}

git_preflight() {
    local branch status_output local_sha remote_sha
    branch="${WATCHDOG_REPO_REF}"
    status_output="$(git -C "${PROJECT_DIR}" status --porcelain --untracked-files=all | grep -vE '^\?\? \.omc(/|$)' || true)"
    if [ -n "${status_output}" ]; then
        WATCHDOG_LAST_STATUS="repo has uncommitted changes"
        state_write
        audit_log "preflight failed: repo has uncommitted changes"
        return 1
    fi

    git -C "${PROJECT_DIR}" fetch origin "${branch}" >/dev/null 2>&1
    local_sha="$(git -C "${PROJECT_DIR}" rev-parse HEAD)"
    remote_sha="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}")"
    if [ "${local_sha}" != "${remote_sha}" ]; then
        WATCHDOG_LAST_STATUS="repo is not synced to origin/${branch}"
        state_write
        audit_log "preflight failed: repo is not synced to origin/${branch}"
        return 1
    fi

    WATCHDOG_REPO_SHA="${local_sha}"
    state_write
    return 0
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

find_ssh_key_id() {
    local response key_id
    response="$(hetzner_api GET "/ssh_keys?name=${WATCHDOG_SSH_KEY_NAME}")"
    key_id="$(printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ssh_keys"][0]["id"])' 2>/dev/null || true)"
    [ -n "${key_id}" ] || { log "ERROR: Hetzner SSH key '${WATCHDOG_SSH_KEY_NAME}' not found."; exit 1; }
    printf '%s\n' "${key_id}"
}

create_server() {
    local ssh_key_id create_response
    ssh_key_id="$(find_ssh_key_id)"
    WATCHDOG_SERVER_NAME="${WATCHDOG_SERVER_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"
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
    [ -n "${WATCHDOG_SERVER_ID}" ] && [ -n "${WATCHDOG_SERVER_IP}" ] || { log "ERROR: failed to create Hetzner server."; exit 1; }
    WATCHDOG_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    WATCHDOG_STARTED_AT_EPOCH="$(date -u +%s)"
    WATCHDOG_FLOW_ID="${WATCHDOG_FLOW_ID:-flow-$(date -u +%Y%m%dT%H%M%SZ)}"
    WATCHDOG_PHASE="provisioning"
    WATCHDOG_LAST_STATUS="created Hetzner server"
    state_write
    audit_log "created Hetzner server"
    log "Server ready: ${WATCHDOG_SERVER_ID} @ ${WATCHDOG_SERVER_IP}"
}

cleanup_server() {
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 0
    fi
    log "Destroying Hetzner server ${WATCHDOG_SERVER_ID} (${WATCHDOG_SERVER_NAME})..."
    hetzner_api DELETE "/servers/${WATCHDOG_SERVER_ID}" >/dev/null 2>&1 || true
    audit_log "destroyed Hetzner server"
}

server_exists_api() {
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 1
    fi
    local response
    response="$(hetzner_api GET "/servers/${WATCHDOG_SERVER_ID}" 2>/dev/null || true)"
    printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("server") else 1)' >/dev/null 2>&1
}

server_reachable_ssh() {
    if [ -z "${WATCHDOG_SERVER_IP:-}" ]; then
        return 1
    fi
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "echo ready" >/dev/null 2>&1
}

confirm_server_available() {
    if server_exists_api; then
        return 0
    fi
    if server_reachable_ssh; then
        audit_log "Hetzner API missed tracked server but SSH still works; preserving current VM"
        return 0
    fi
    sleep 5
    if server_exists_api || server_reachable_ssh; then
        audit_log "tracked server check recovered after retry"
        return 0
    fi
    return 1
}

wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 60); do
        if server_reachable_ssh; then
            return 0
        fi
        sleep 5
    done
    return 1
}

remote_run() {
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" bash -s -- "$@" <<'REMOTE'
set -euo pipefail
"$@"
REMOTE
}

install_remote_support() {
    local token_file
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "mkdir -p /root/abp-watchdog"
    scp "${SSH_OPTS[@]}" "${PROJECT_DIR}/scripts/watchdog-remote.sh" "root@${WATCHDOG_SERVER_IP}:/root/abp-watchdog/watchdog-remote.sh" >/dev/null
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "chmod +x /root/abp-watchdog/watchdog-remote.sh"

    token_file="$(mktemp)"
    chmod 600 "${token_file}"
    printf '%s' "${GH_TOKEN}" > "${token_file}"
    scp "${SSH_OPTS[@]}" "${token_file}" "root@${WATCHDOG_SERVER_IP}:/root/.gh_token" >/dev/null
    rm -f "${token_file}"
}

remote_status() {
    local tmp
    tmp="$(mktemp)"
    if ! remote_run /root/abp-watchdog/watchdog-remote.sh status > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    # shellcheck disable=SC1090
    . "${tmp}"
    rm -f "${tmp}"
    return 0
}

remote_tail() {
    remote_run /root/abp-watchdog/watchdog-remote.sh tail "${1:-80}" 2>/dev/null || true
}

save_remote_log() {
    if [ -z "${WATCHDOG_SERVER_IP:-}" ]; then
        return 0
    fi
    local target ts
    ensure_state_dir
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    target="${STATE_DIR}/remote-build-${ts}.log"
    remote_run /root/abp-watchdog/watchdog-remote.sh tail 4000 > "${target}" 2>/dev/null || true
    [ -s "${target}" ] || rm -f "${target}"
}

remote_start() {
    install_remote_support
    remote_run /root/abp-watchdog/watchdog-remote.sh start \
        "${WATCHDOG_REPO_SHA}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_ABP_BRANCH}" \
        "${WATCHDOG_REPO_URL}" \
        "${WATCHDOG_REPO_REF}" >/dev/null
    WATCHDOG_PHASE="building"
    WATCHDOG_LAST_STATUS="remote build running"
    WATCHDOG_LAST_REMOTE_PHASE="building"
    state_write
}

remote_restart() {
    install_remote_support
    remote_run /root/abp-watchdog/watchdog-remote.sh restart \
        "${WATCHDOG_REPO_SHA}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_ABP_BRANCH}" \
        "${WATCHDOG_REPO_URL}" \
        "${WATCHDOG_REPO_REF}" >/dev/null
    WATCHDOG_PHASE="building"
    WATCHDOG_LAST_STATUS="remote build restarted"
    WATCHDOG_LAST_REMOTE_PHASE="building"
    state_write
}

render_prompt() {
    local log_excerpt
    log_excerpt="$(remote_tail 80 | sed 's/^/  /' || true)"
    cat > "${PROMPT_FILE}" <<EOF
# ABP Watchdog Repair Prompt

Goal:
- Fix the repo-side cause of the current Hetzner build failure.
- Commit and push the fix.
- Do not create or destroy VMs.
- Leave the repo clean.

Current flow:
- Flow: ${WATCHDOG_FLOW_ID:-unknown}
- Phase: ${WATCHDOG_PHASE:-unknown}
- Server: ${WATCHDOG_SERVER_NAME:-none}
- Server ID: ${WATCHDOG_SERVER_ID:-none}
- Server IP: ${WATCHDOG_SERVER_IP:-none}
- Commit currently associated with flow: ${WATCHDOG_REPO_SHA:-unknown}
- Last remote phase: ${WATCHDOG_LAST_REMOTE_PHASE:-unknown}
- Last failure summary: ${WATCHDOG_LAST_FAILURE_SUMMARY:-unknown}

Constraints:
- The watchdog owns infrastructure lifecycle.
- Preserve the existing Hetzner VM.
- If you change code, commit and push it.
- Do not manually mutate watchdog state files.

Recent remote build log:
${log_excerpt}

Expected output:
- short root-cause statement
- repo files changed
- pushed commit SHA
- note that the watchdog can now restart on the same VM
EOF
    cat "${PROMPT_FILE}"
}

run_codex_repair_cycle() {
    if [ "${WATCHDOG_RUN_CODEX}" != "1" ]; then
        return 0
    fi
    render_prompt >/dev/null
    local cmd=("${WATCHDOG_CODEX_BIN}")
    if [ "${WATCHDOG_CODEX_SEARCH}" = "1" ]; then
        cmd+=(--search)
    fi
    cmd+=(
        exec
        --dangerously-bypass-approvals-and-sandbox
        -C "${PROJECT_DIR}"
        -m "${WATCHDOG_CODEX_MODEL}"
        -
    )
    audit_log "starting codex repair cycle"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${WATCHDOG_CODEX_TIMEOUT_SECONDS}" "${cmd[@]}" < "${PROMPT_FILE}" >> "${LOG_FILE}" 2>&1 || true
    else
        "${cmd[@]}" < "${PROMPT_FILE}" >> "${LOG_FILE}" 2>&1 || true
    fi
    audit_log "finished codex repair cycle"
}

mark_failed_and_cleanup() {
    WATCHDOG_PHASE="aborted"
    WATCHDOG_LAST_STATUS="$1"
    state_write
    audit_log "$1"
    save_remote_log || true
    cleanup_server
    uninstall_cron >/dev/null 2>&1 || true
    reset_runtime_state_keep_summary
}

reset_runtime_state_keep_summary() {
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_LAST_REMOTE_PHASE=""
    WATCHDOG_RELEASE_TAG=""
    state_write
}

handle_completed_flow() {
    WATCHDOG_PHASE="completed"
    WATCHDOG_LAST_STATUS="build completed"
    WATCHDOG_LAST_REMOTE_PHASE="completed"
    WATCHDOG_RELEASE_TAG="${REMOTE_RELEASE_TAG:-}"
    state_write
    audit_log "build completed"
    write_cycle_snapshot
    cleanup_server
    uninstall_cron >/dev/null 2>&1 || true
    reset_runtime_state_keep_summary
}

handle_repair_pending() {
    WATCHDOG_PHASE="repair_pending"
    WATCHDOG_LAST_REMOTE_PHASE="${REMOTE_PHASE:-failed}"
    WATCHDOG_LAST_FAILURE_SUMMARY="${REMOTE_FAILURE_SUMMARY:-build failed}"
    WATCHDOG_LAST_STATUS="awaiting repo fix/push before restart on existing VM"
    WATCHDOG_REPAIR_COUNT="$(( ${WATCHDOG_REPAIR_COUNT:-0} + 1 ))"
    state_write
    audit_log "repair pending after remote failure"
    save_remote_log || true

    if git_preflight && [ "${WATCHDOG_REPO_SHA}" != "${REMOTE_COMMIT_SHA:-}" ]; then
        audit_log "restarting build on existing VM with pushed fix ${WATCHDOG_REPO_SHA}"
        remote_restart
        return 0
    fi

    write_cycle_snapshot
    run_codex_repair_cycle
}

start_new_flow() {
    git_preflight || { write_cycle_snapshot; return 0; }
    create_server
    WATCHDOG_PHASE="bootstrapping"
    WATCHDOG_LAST_STATUS="waiting for SSH"
    state_write
    audit_log "waiting for SSH"
    wait_for_ssh || { mark_failed_and_cleanup "failed to reach new server by SSH"; return 1; }
    remote_start
    write_cycle_snapshot
}

poll_remote_flow() {
    if ! confirm_server_available; then
        mark_failed_and_cleanup "tracked Hetzner server disappeared"
        return 1
    fi

    wait_for_ssh || { WATCHDOG_LAST_STATUS="server is up but SSH is not ready"; state_write; write_cycle_snapshot; return 0; }
    install_remote_support

    if ! remote_status; then
        WATCHDOG_LAST_STATUS="remote supervisor unavailable"
        state_write
        write_cycle_snapshot
        return 0
    fi

    WATCHDOG_LAST_REMOTE_PHASE="${REMOTE_PHASE:-unknown}"
    case "${REMOTE_PHASE:-idle}" in
        building)
            WATCHDOG_PHASE="building"
            WATCHDOG_LAST_STATUS="remote build running"
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            state_write
            write_cycle_snapshot
            ;;
        completed)
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            handle_completed_flow
            ;;
        failed|stopped)
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            handle_repair_pending
            ;;
        idle)
            if [ "${WATCHDOG_PHASE:-idle}" = "repair_pending" ]; then
                handle_repair_pending
            else
                WATCHDOG_LAST_STATUS="remote supervisor idle"
                state_write
                write_cycle_snapshot
            fi
            ;;
        *)
            WATCHDOG_LAST_STATUS="unexpected remote phase: ${REMOTE_PHASE:-unknown}"
            state_write
            write_cycle_snapshot
            ;;
    esac
}

start_cycle() {
    ensure_state_dir
    acquire_lock
    state_load
    require_credentials
    reset_lock_skip_tracking

    WATCHDOG_LAST_CHECK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    audit_log "cycle started"

    if [ -n "${WATCHDOG_STARTED_AT_EPOCH:-}" ]; then
        local now_epoch elapsed_seconds timeout_seconds
        now_epoch="$(date -u +%s)"
        elapsed_seconds="$(( now_epoch - WATCHDOG_STARTED_AT_EPOCH ))"
        timeout_seconds="$(( WATCHDOG_FLOW_TIMEOUT_HOURS * 3600 ))"
        if [ "${elapsed_seconds}" -gt "${timeout_seconds}" ]; then
            mark_failed_and_cleanup "watchdog flow exceeded ${WATCHDOG_FLOW_TIMEOUT_HOURS}h"
            return 1
        fi
    fi

    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        start_new_flow
        return 0
    fi

    poll_remote_flow
}

status() {
    state_load
    cat <<EOF
Flow: ${WATCHDOG_FLOW_ID:-none}
Phase: ${WATCHDOG_PHASE:-idle}
Server: ${WATCHDOG_SERVER_NAME:-none}
Server ID: ${WATCHDOG_SERVER_ID:-none}
Server IP: ${WATCHDOG_SERVER_IP:-none}
Repo SHA: ${WATCHDOG_REPO_SHA:-none}
Remote phase: ${WATCHDOG_LAST_REMOTE_PHASE:-none}
Last failure: ${WATCHDOG_LAST_FAILURE_SUMMARY:-none}
Repair count: ${WATCHDOG_REPAIR_COUNT:-0}
Release: ${WATCHDOG_RELEASE_TAG:-none}
Last check: ${WATCHDOG_LAST_CHECK_AT:-none}
EOF
    if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        remote_tail 40 || true
    fi
}

cleanup_command() {
    state_load
    cleanup_server
    state_clear
    uninstall_cron >/dev/null 2>&1 || true
    audit_log "manual cleanup invoked"
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
}

install_cron() {
    ensure_state_dir
    local repo_root current_crontab tmp_crontab cron_line marker
    repo_root="${PROJECT_DIR}"
    marker="# ABP watchdog deployment"
    cron_line="*/15 * * * * cd ${repo_root} && zsh -lc 'PATH=/var/lib/asdf/installs/nodejs/24.8.0/bin:/var/lib/asdf/shims:/usr/local/bin:/usr/bin:/bin WATCHDOG_STATE_DIR=${STATE_DIR} WATCHDOG_RUN_CODEX=1 WATCHDOG_CODEX_BIN=${WATCHDOG_CODEX_BIN} WATCHDOG_CODEX_SEARCH=1 WATCHDOG_CODEX_TIMEOUT_SECONDS=600 ./scripts/watchdog-hetzner.sh cycle >> ${CRON_LOG_FILE} 2>&1' ${marker}"
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
        cycle|start) start_cycle ;;
        status) status ;;
        prompt) render_prompt ;;
        cleanup) cleanup_command ;;
        install-cron) install_cron ;;
        uninstall-cron) uninstall_cron ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
