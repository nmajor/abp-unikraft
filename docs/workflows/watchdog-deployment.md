# Watchdog Deployment Workflow

Use this when a Chromium build on Hetzner will take hours and you want a small cron heartbeat to keep one build flow moving without babysitting it continuously.

## Architecture

The watchdog now has two deterministic parts:

1. Local watchdog: `scripts/watchdog-hetzner.sh`
   - owns one build flow
   - owns one authoritative Hetzner VM for that flow
   - owns cron, timeouts, audit logs, and cleanup
   - never tries to infer workflow state from random shell output

2. Remote supervisor: `scripts/watchdog-remote.sh`
   - copied to the Hetzner VM at `/root/abp-watchdog/watchdog-remote.sh`
   - owns the remote build PID, commit SHA, phase, exit code, failure summary, and log file
   - exposes deterministic commands: `status`, `start`, `restart`, `stop`, `tail`, `heartbeat`, `artifact-path`

The prompt is intentionally narrow now:
- only used for repo-side repair work
- does not create or destroy VMs
- does not decide retries
- does not decide workflow state

## Design Rules

- One build flow uses one VM.
- Do not destroy the VM on ordinary build failure.
- Keep the VM alive across repair cycles.
- Only destroy the VM when:
  - the build completes successfully
  - the flow exceeds 24 hours
  - cleanup is explicitly requested
- If the tracked VM truly disappears, abort the flow instead of silently creating more VMs.

## Commands

```bash
# Start or poll the current flow
./scripts/watchdog-hetzner.sh cycle

# Show current local state and remote tail
./scripts/watchdog-hetzner.sh status

# Render the repair prompt that would be sent to Codex
./scripts/watchdog-hetzner.sh prompt

# Install the 15-minute cron heartbeat
./scripts/watchdog-hetzner.sh install-cron

# Remove the cron heartbeat
./scripts/watchdog-hetzner.sh uninstall-cron

# Destroy the tracked VM and clear local state
./scripts/watchdog-hetzner.sh cleanup
```

## Cron Pattern

The cron job is intentionally small:

```cron
*/5 * * * * cd /home/coder/app/abp-unikraft && zsh -lc 'PATH=/var/lib/asdf/installs/nodejs/24.8.0/bin:/var/lib/asdf/shims:/usr/local/bin:/usr/bin:/bin WATCHDOG_STATE_DIR=$HOME/.cache/abp-watchdog WATCHDOG_RUN_CODEX=1 WATCHDOG_CODEX_BIN=/var/lib/asdf/installs/nodejs/24.8.0/bin/codex WATCHDOG_CODEX_SEARCH=1 WATCHDOG_CODEX_TIMEOUT_SECONDS=600 ./scripts/watchdog-hetzner.sh cycle >> $HOME/.cache/abp-watchdog/cron.log 2>&1'
```

Each cron tick does one thing:
- call `watchdog-hetzner.sh cycle`

If another cycle is already running:
- skip cleanly
- log the skip
- only warn if the lock survives for roughly an hour across multiple skipped cycles
- with the 5-minute cadence, the default warning threshold is 12 skipped cycles

This means a 20-40 minute repair loop is treated as normal, not as a failure.

## State Ownership

Local state:
- `~/.cache/abp-watchdog/state.env`
- authoritative local view of the flow, VM, commit, and last known remote phase

Remote state:
- `/root/abp-watchdog/state.env`
- authoritative remote view of build PID, commit SHA, remote phase, exit code, release tag, and artifact path

Remote log:
- `/root/abp-watchdog/build.log`

The local watchdog should trust the remote supervisor for build status instead of guessing from raw logs.

## Audit Trail

The watchdog writes:

- `~/.cache/abp-watchdog/audit.log`
  - high-level flow events
- `~/.cache/abp-watchdog/cron.log`
  - cron stdout/stderr
- `~/.cache/abp-watchdog/watchdog.log`
  - Codex repair output
- `~/.cache/abp-watchdog/checks/<timestamp>.log`
  - per-cycle snapshot of local state plus remote tail
- `~/.cache/abp-watchdog/remote-build-<timestamp>.log`
  - saved remote failure logs when a build fails

## Flow Semantics

Healthy build:
- cron polls
- local watchdog asks remote supervisor for `status`
- if remote phase is `building`, watchdog just records the check and exits
- no Codex prompt is needed

Failed build:
- remote supervisor reports `failed`
- local watchdog moves the flow to `repair_pending`
- same VM stays alive
- failure log is saved locally
- Codex is prompted only to fix repo code, commit, and push

Repair restart:
- next cycle checks if local `HEAD` is clean and pushed
- if the pushed commit is newer than the failed commit, watchdog calls remote `restart <sha>`
- restart happens on the same VM

Completed build:
- remote supervisor reports `completed`
- watchdog records the release tag
- watchdog destroys the VM
- watchdog removes its cron entry

Timed-out flow:
- if the flow age exceeds `WATCHDOG_FLOW_TIMEOUT_HOURS` (default `24`)
- watchdog saves logs, destroys the VM, and aborts the flow

## Deterministic Responsibilities

These should stay in code, not in the prompt:

- creating and deleting the VM
- checking whether the VM still exists
- checking SSH reachability
- copying the remote supervisor
- pinning an exact repo commit SHA
- starting and restarting the build
- tracking the remote PID and exit code
- saving failure logs
- enforcing the 24-hour timeout
- cron skip/lock accounting

The prompt should only handle:
- repo-side root cause analysis
- code changes
- commit and push

## Current Build Goals

- build against the latest source-available validated `fingerprint-chromium`
- preserve ABP protocol behavior
- preserve bandwidth metering and full-page screenshot support
- keep the active runtime contract on native `fingerprint-chromium` switches
- keep the watchdog minimal and deterministic

## Durable Fix Log

- 2026-04-04: Switched GN bootstrap to prefer a prebuilt GN binary from CIPD in `scripts/build-on-fp-chromium.sh`.
- 2026-04-04: Re-architected the watchdog around a deterministic remote supervisor instead of having the prompt participate in infrastructure control.
- 2026-04-05: Made the remote supervisor hard-reset and clean its ephemeral repo checkout before every restart so stale modified files cannot block `git checkout --detach`.
- 2026-04-05: Hardened `scripts/ensure-node-esbuild.sh` so version discovery fallbacks survive `set -euo pipefail` when `grep` finds no matches, and so failed Node/esbuild downloads emit explicit errors instead of a vague step header.
- 2026-04-05: Fixed Node version parsing in `scripts/ensure-node-esbuild.sh` to preserve multi-digit majors like `v22.11.0`; the old greedy extraction was truncating this to `v2.11.0` and causing false download failures.
- 2026-04-05: Disabled VAAPI in `scripts/build-on-fp-chromium.sh` for the Ubuntu 22.04 build path because the host `libva-dev` headers do not expose the AV1 `refresh_frame_flags` fields Chromium 142 expects. Treat this as an environment compatibility workaround, not a browser feature regression in the stealth layer.
