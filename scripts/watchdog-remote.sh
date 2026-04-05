#!/bin/bash
set -euo pipefail

STATE_DIR="${WATCHDOG_REMOTE_STATE_DIR:-/root/abp-watchdog}"
STATE_FILE="${STATE_DIR}/state.env"
LOG_FILE="${STATE_DIR}/build.log"
RUNNER_FILE="${STATE_DIR}/run-build.sh"
REPO_DIR="${WATCHDOG_REMOTE_REPO_DIR:-/root/abp-unikraft}"
PID_FILE="${STATE_DIR}/build.pid"
DEFAULT_REPO_URL="${WATCHDOG_REMOTE_REPO_URL:-https://github.com/nmajor/abp-unikraft.git}"
DEFAULT_REPO_REF="${WATCHDOG_REMOTE_REPO_REF:-main}"

mkdir -p "${STATE_DIR}"

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
            mv "${STATE_FILE}" "${STATE_FILE}.corrupt.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
            REMOTE_PHASE="failed"
            REMOTE_COMMIT_SHA="${REMOTE_COMMIT_SHA:-}"
            REMOTE_PID=""
            REMOTE_STARTED_AT="${REMOTE_STARTED_AT:-}"
            REMOTE_STARTED_AT_EPOCH="${REMOTE_STARTED_AT_EPOCH:-}"
            REMOTE_LAST_HEARTBEAT_AT="$(timestamp)"
            REMOTE_LAST_HEARTBEAT_EPOCH="$(timestamp_epoch)"
            REMOTE_EXIT_CODE="${REMOTE_EXIT_CODE:-1}"
            REMOTE_FAILURE_SUMMARY="remote watchdog state file was corrupt"
            REMOTE_ARTIFACT_PATH="${REMOTE_ARTIFACT_PATH:-}"
            REMOTE_RELEASE_TAG="${REMOTE_RELEASE_TAG:-}"
            return 0
        fi
    fi
    return 0
}

state_write() {
    cat > "${STATE_FILE}" <<EOF
REMOTE_PHASE=$(shell_escape "${REMOTE_PHASE:-idle}")
REMOTE_COMMIT_SHA=$(shell_escape "${REMOTE_COMMIT_SHA:-}")
REMOTE_PID=$(shell_escape "${REMOTE_PID:-}")
REMOTE_STARTED_AT=$(shell_escape "${REMOTE_STARTED_AT:-}")
REMOTE_STARTED_AT_EPOCH=$(shell_escape "${REMOTE_STARTED_AT_EPOCH:-}")
REMOTE_LAST_HEARTBEAT_AT=$(shell_escape "${REMOTE_LAST_HEARTBEAT_AT:-}")
REMOTE_LAST_HEARTBEAT_EPOCH=$(shell_escape "${REMOTE_LAST_HEARTBEAT_EPOCH:-}")
REMOTE_EXIT_CODE=$(shell_escape "${REMOTE_EXIT_CODE:-}")
REMOTE_FAILURE_SUMMARY=$(shell_escape "${REMOTE_FAILURE_SUMMARY:-}")
REMOTE_ARTIFACT_PATH=$(shell_escape "${REMOTE_ARTIFACT_PATH:-}")
REMOTE_RELEASE_TAG=$(shell_escape "${REMOTE_RELEASE_TAG:-}")
EOF
}

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

timestamp_epoch() {
    date -u +%s
}

touch_heartbeat() {
    REMOTE_LAST_HEARTBEAT_AT="$(timestamp)"
    REMOTE_LAST_HEARTBEAT_EPOCH="$(timestamp_epoch)"
}

update_release_metadata_from_log() {
    if [ ! -f "${LOG_FILE}" ]; then
        return 0
    fi

    REMOTE_RELEASE_TAG="$(
        sed -n 's#.*Release: https://github.com/.*/releases/tag/\([^ ]*\).*#\1#p' "${LOG_FILE}" | tail -n1
    )"

    if [ -z "${REMOTE_ARTIFACT_PATH:-}" ] && [ -f /root/abp-stealth-linux-x64.tar.gz ]; then
        REMOTE_ARTIFACT_PATH="/root/abp-stealth-linux-x64.tar.gz"
    fi
}

reconcile_state() {
    state_load

    if [ "${REMOTE_PHASE:-idle}" = "building" ] && [ -n "${REMOTE_PID:-}" ]; then
        if kill -0 "${REMOTE_PID}" >/dev/null 2>&1; then
            touch_heartbeat
            state_write
            return 0
        fi

        REMOTE_EXIT_CODE="${REMOTE_EXIT_CODE:-1}"
        update_release_metadata_from_log
        if [ "${REMOTE_EXIT_CODE}" = "0" ] || grep -q "ALL DONE!" "${LOG_FILE}" 2>/dev/null; then
            REMOTE_PHASE="completed"
        else
            REMOTE_PHASE="failed"
            REMOTE_FAILURE_SUMMARY="$(tail -n 25 "${LOG_FILE}" 2>/dev/null | tail -n 1)"
        fi
        touch_heartbeat
        state_write
    fi
}

ensure_repo() {
    local repo_url="$1"
    local repo_ref="$2"
    local commit_sha="$3"

    if ! command -v git >/dev/null 2>&1; then
        apt-get update
        apt-get install -y git curl
    fi

    if [ ! -d "${REPO_DIR}/.git" ]; then
        git clone --branch "${repo_ref}" "${repo_url}" "${REPO_DIR}"
    else
        git -C "${REPO_DIR}" fetch origin "${repo_ref}"
    fi

    git -C "${REPO_DIR}" checkout --detach "${commit_sha}"
}

write_runner() {
    local commit_sha="$1"
    local fp_tag="$2"
    local abp_branch="$3"

    cat > "${RUNNER_FILE}" <<EOF
#!/bin/bash
set -euo pipefail

STATE_FILE="${STATE_FILE}"
LOG_FILE="${LOG_FILE}"
PID_FILE="${PID_FILE}"
REPO_DIR="${REPO_DIR}"
COMMIT_SHA="${commit_sha}"
FP_TAG="${fp_tag}"
ABP_BRANCH="${abp_branch}"

write_state() {
    cat > "\${STATE_FILE}" <<STATEEOF
REMOTE_PHASE=\$(printf '%q' "\${REMOTE_PHASE:-idle}")
REMOTE_COMMIT_SHA=\$(printf '%q' "\${REMOTE_COMMIT_SHA:-}")
REMOTE_PID=\$(printf '%q' "\${REMOTE_PID:-}")
REMOTE_STARTED_AT=\$(printf '%q' "\${REMOTE_STARTED_AT:-}")
REMOTE_STARTED_AT_EPOCH=\$(printf '%q' "\${REMOTE_STARTED_AT_EPOCH:-}")
REMOTE_LAST_HEARTBEAT_AT=\$(printf '%q' "\${REMOTE_LAST_HEARTBEAT_AT:-}")
REMOTE_LAST_HEARTBEAT_EPOCH=\$(printf '%q' "\${REMOTE_LAST_HEARTBEAT_EPOCH:-}")
REMOTE_EXIT_CODE=\$(printf '%q' "\${REMOTE_EXIT_CODE:-}")
REMOTE_FAILURE_SUMMARY=\$(printf '%q' "\${REMOTE_FAILURE_SUMMARY:-}")
REMOTE_ARTIFACT_PATH=\$(printf '%q' "\${REMOTE_ARTIFACT_PATH:-}")
REMOTE_RELEASE_TAG=\$(printf '%q' "\${REMOTE_RELEASE_TAG:-}")
STATEEOF
}

heartbeat() {
    REMOTE_LAST_HEARTBEAT_AT="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    REMOTE_LAST_HEARTBEAT_EPOCH="\$(date -u +%s)"
}

REMOTE_PHASE="building"
REMOTE_COMMIT_SHA="\${COMMIT_SHA}"
REMOTE_PID="\$\$"
REMOTE_STARTED_AT="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REMOTE_STARTED_AT_EPOCH="\$(date -u +%s)"
REMOTE_EXIT_CODE=""
REMOTE_FAILURE_SUMMARY=""
REMOTE_ARTIFACT_PATH=""
REMOTE_RELEASE_TAG=""
heartbeat
write_state

cd "\${REPO_DIR}"
export SKIP_POWEROFF=1
export ABP_REPO_SHA="\${COMMIT_SHA}"
export FP_CHROMIUM_TAG="\${FP_TAG}"
export ABP_BRANCH="\${ABP_BRANCH}"
if [ -f /root/.gh_token ]; then
    export GH_TOKEN="\$(cat /root/.gh_token)"
fi

set +e
bash ./scripts/build-on-fp-chromium.sh >> "\${LOG_FILE}" 2>&1
exit_code="\$?"
set -e

REMOTE_PHASE="failed"
REMOTE_EXIT_CODE="\${exit_code}"
heartbeat

if [ "\${exit_code}" = "0" ] || grep -q "ALL DONE!" "\${LOG_FILE}" 2>/dev/null; then
    REMOTE_PHASE="completed"
else
    REMOTE_FAILURE_SUMMARY="\$(tail -n 25 "\${LOG_FILE}" 2>/dev/null | tail -n 1)"
fi

release_tag="\$(sed -n 's#.*Release: https://github.com/.*/releases/tag/\\([^ ]*\\).*#\\1#p' "\${LOG_FILE}" | tail -n1)"
if [ -n "\${release_tag}" ]; then
    REMOTE_RELEASE_TAG="\${release_tag}"
fi
if [ -f /root/abp-stealth-linux-x64.tar.gz ]; then
    REMOTE_ARTIFACT_PATH="/root/abp-stealth-linux-x64.tar.gz"
fi

write_state
rm -f "\${PID_FILE}"
EOF
    chmod +x "${RUNNER_FILE}"
}

cmd_status() {
    reconcile_state
    state_load
    touch_heartbeat
    state_write
    cat "${STATE_FILE}"
}

cmd_start() {
    local commit_sha="${1:?commit sha required}"
    local fp_tag="${2:?fp tag required}"
    local abp_branch="${3:-dev}"
    local repo_url="${4:-${DEFAULT_REPO_URL}}"
    local repo_ref="${5:-${DEFAULT_REPO_REF}}"

    reconcile_state
    state_load
    if [ "${REMOTE_PHASE:-idle}" = "building" ] && [ -n "${REMOTE_PID:-}" ] && kill -0 "${REMOTE_PID}" >/dev/null 2>&1; then
        echo "build already running" >&2
        exit 1
    fi

    : > "${LOG_FILE}"
    ensure_repo "${repo_url}" "${repo_ref}" "${commit_sha}"
    write_runner "${commit_sha}" "${fp_tag}" "${abp_branch}"
    nohup setsid "${RUNNER_FILE}" >/dev/null 2>&1 &
    echo $! > "${PID_FILE}"

    REMOTE_PHASE="building"
    REMOTE_COMMIT_SHA="${commit_sha}"
    REMOTE_PID="$(cat "${PID_FILE}")"
    REMOTE_STARTED_AT="$(timestamp)"
    REMOTE_STARTED_AT_EPOCH="$(timestamp_epoch)"
    REMOTE_EXIT_CODE=""
    REMOTE_FAILURE_SUMMARY=""
    REMOTE_ARTIFACT_PATH=""
    REMOTE_RELEASE_TAG=""
    touch_heartbeat
    state_write
    echo "started"
}

cmd_stop() {
    reconcile_state
    state_load
    if [ -n "${REMOTE_PID:-}" ]; then
        kill -- "-${REMOTE_PID}" >/dev/null 2>&1 || kill "${REMOTE_PID}" >/dev/null 2>&1 || true
    fi
    rm -f "${PID_FILE}"
    REMOTE_PHASE="stopped"
    REMOTE_EXIT_CODE="${REMOTE_EXIT_CODE:-130}"
    touch_heartbeat
    state_write
}

cmd_restart() {
    local commit_sha="${1:?commit sha required}"
    local fp_tag="${2:?fp tag required}"
    local abp_branch="${3:-dev}"
    local repo_url="${4:-${DEFAULT_REPO_URL}}"
    local repo_ref="${5:-${DEFAULT_REPO_REF}}"
    cmd_stop || true
    cmd_start "${commit_sha}" "${fp_tag}" "${abp_branch}" "${repo_url}" "${repo_ref}"
}

cmd_tail() {
    local lines="${1:-80}"
    tail -n "${lines}" "${LOG_FILE}" 2>/dev/null || true
}

cmd_heartbeat() {
    reconcile_state
    state_load
    touch_heartbeat
    state_write
    cat "${STATE_FILE}"
}

cmd_artifact_path() {
    reconcile_state
    state_load
    update_release_metadata_from_log
    state_write
    printf '%s\n' "${REMOTE_ARTIFACT_PATH:-}"
}

main() {
    local cmd="${1:-status}"
    shift || true
    case "${cmd}" in
        status) cmd_status "$@" ;;
        start) cmd_start "$@" ;;
        restart) cmd_restart "$@" ;;
        stop) cmd_stop "$@" ;;
        tail) cmd_tail "$@" ;;
        heartbeat) cmd_heartbeat "$@" ;;
        artifact-path) cmd_artifact_path "$@" ;;
        *)
            echo "usage: $0 [status|start|restart|stop|tail|heartbeat|artifact-path]" >&2
            exit 1
            ;;
    esac
}

main "$@"
