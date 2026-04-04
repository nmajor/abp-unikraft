# Watchdog Deployment Workflow

Use this when you want a long Hetzner build to keep moving while Codex checks it in 15-minute cycles.

## What It Does

`scripts/watchdog-hetzner.sh` is the entrypoint. It:

- creates a temporary Hetzner VM
- clones the ABP repo on the VM
- starts `scripts/build-on-fp-chromium.sh` remotely
- polls the remote log on each cycle
- generates a Codex-ready prompt file
- invokes `codex exec` itself on each cron/manual cycle by default
- retries on crash if allowed
- destroys the VM on success or after cleanup
- removes its own cron entry on terminal success or failure

The watchdog is intentionally separate from the core build/runtime files. It supervises the build, but it does not change Chromium or ABP behavior itself.

## Prerequisites

- `HETZNER_API_TOKEN` exported in `~/.zshrc` and present in the shell environment
- `GH_TOKEN` exported or `gh auth token` working locally
- `abp-build-key` present in Hetzner
- `ssh`, `scp`, `curl`, `gh`, and `zsh` available locally
- the repo committed and pushed on `main` before starting the watchdog

## Commands

```bash
# Start or poll the build
./scripts/watchdog-hetzner.sh cycle

# Print the current state only
./scripts/watchdog-hetzner.sh status

# Render the next Codex prompt
./scripts/watchdog-hetzner.sh prompt

# Tear down the remote VM and clear local state
./scripts/watchdog-hetzner.sh cleanup

# Install a 15-minute cron entry
./scripts/watchdog-hetzner.sh install-cron

# Remove the watchdog cron entry manually
./scripts/watchdog-hetzner.sh uninstall-cron
```

## Cron Pattern

The cron entry runs every 15 minutes and uses `zsh -lc` so `~/.zshrc` exports are visible:

```cron
*/15 * * * * cd /home/coder/app/abp-unikraft && zsh -lc 'WATCHDOG_STATE_DIR=$HOME/.cache/abp-watchdog WATCHDOG_AUTO_RETRY=1 WATCHDOG_RUN_CODEX=1 WATCHDOG_CODEX_TIMEOUT_SECONDS=600 ./scripts/watchdog-hetzner.sh cycle >> $HOME/.cache/abp-watchdog/cron.log 2>&1'
```

The watchdog always writes a human-readable prompt file in the state directory, but the intended pattern is cron -> `watchdog-hetzner.sh cycle` -> `codex exec`.

## Audit Trail

Every cycle writes:

- `~/.cache/abp-watchdog/audit.log` — append-only high-level events
- `~/.cache/abp-watchdog/cron.log` — cron stdout/stderr
- `~/.cache/abp-watchdog/watchdog.log` — Codex cycle output
- `~/.cache/abp-watchdog/checks/<timestamp>.log` — per-cycle state snapshot with repo SHA and remote log tail

The watchdog refuses to start from a dirty or unpushed repo and records the exact source commit in state.

## Runtime Knobs

- `WATCHDOG_SERVER_TYPE` defaults to `cpx51`
- `WATCHDOG_SERVER_LOCATION` defaults to `ash`
- `WATCHDOG_FP_CHROMIUM_TAG` defaults to `144.0.7559.132`
- `WATCHDOG_ABP_BRANCH` defaults to `dev`
- `WATCHDOG_REPO_REF` defaults to `main`
- `WATCHDOG_BUILD_TIMEOUT_HOURS` defaults to `8`
- `WATCHDOG_SSH_TIMEOUT` defaults to `10`
- `WATCHDOG_MAX_RETRIES` defaults to `2`
- `WATCHDOG_AUTO_RETRY=1` retries a failed run up to `WATCHDOG_MAX_RETRIES`
- `WATCHDOG_RUN_CODEX=1` makes each cycle invoke `codex exec`
- `WATCHDOG_CODEX_TIMEOUT_SECONDS` bounds each Codex cycle and should stay comfortably below 15 minutes; default is `600`
- `WATCHDOG_CODEX_SEARCH=1` enables Codex web search during each cycle
- `WATCHDOG_POST_BUILD_SMOKE_URLS` sets the post-release smoke-test targets

## Current Build Goals

The watchdog prompt always carries the current implementation goals:

- rebase to the latest validated `fingerprint-chromium`
- keep ABP protocol behavior intact
- keep bandwidth metering and full-page screenshot support
- remove the old ABP stealth namespace from the active runtime contract
- keep cleanup strict so the Hetzner VM never lingers after success or failure
- encode durable improvements back into the repo so each future watchdog run gets smoother

## Recommended Use

1. Start a cycle manually with `./scripts/watchdog-hetzner.sh cycle`.
2. Let cron call the same command every 15 minutes.
3. Each cycle will invoke Codex, which should either keep watching, fix and restart, or finish the deploy/test path.
4. If the build fails terminally or succeeds completely, the watchdog removes its own cron entry so it does not run forever.
5. Durable fixes discovered during a cycle should be committed back into the repo or docs instead of being left as one-off operator knowledge.

## Cleanup

The watchdog is designed to delete the Hetzner server itself on completion. If you interrupt the workflow, run:

```bash
./scripts/watchdog-hetzner.sh cleanup
```

That clears the remote VM and the local state files.
