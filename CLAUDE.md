# ABP Unikraft — Agent Browser Protocol with Stealth Chromium

## Project Overview

A stealth-patched Chromium browser (ABP) deployed on KraftCloud/Unikraft.
Built on **fingerprint-chromium** (open-source, BSD-3) as the stealth base,
with ABP protocol overlaid for browser-as-a-service REST API.

## Architecture

```
fingerprint-chromium (stealth base, ~20 patches)
  + ABP protocol (REST API, sessions, chrome/browser/abp/)
  + stealth-extra patches (6 patches we maintain, gaps in fp-chromium)
  + feature edits (bandwidth metering, full page screenshot)
  + wrapper.sh (gost proxy chain, stealth flags, socat)
  + Dockerfile → KraftCloud deployment
```

## Key Directories

| Path | Purpose |
|------|---------|
| `patches/stealth-extra/` | Our 6 patches (surfaces fp-chromium doesn't cover) |
| `patches/legacy/` | Old patches (reference only, replaced by fp-chromium) |
| `scripts/` | Build, deploy, and patch application scripts |
| `docs/workflows/` | Step-by-step workflow docs for agents |

## Workflows

### "Build on Hetzner" / "New Build"

**Read `docs/workflows/hetzner-build.md` FIRST.** It contains the complete procedure
and — critically — a "Known Issues & Solutions" section that will save hours of debugging.

Summary: Create a temporary Hetzner CPX51 VM, build Chromium (~4-6 hours), upload
the release to GitHub, destroy the VM. The workflow doc covers every gotcha
(domain substitution, toolchain versions, GH_TOKEN handling, etc.).

Key files:
- `scripts/hetzner-build.sh` — automated orchestrator (create VM → build → destroy)
- `scripts/build-on-fp-chromium.sh` — the build script that runs ON the VM
- `scripts/verify-abp-overlay-contract.sh` — fail-fast guard against legacy ABP stealth remapping
- `scripts/apply-stealth-extra-edits.sh` — our stealth gap patches
- `scripts/apply-feature-edits.sh` — bandwidth metering + screenshot features

### Deploy to KraftCloud

**Read `docs/workflows/deploy-to-kraftcloud.md` FIRST.** It covers CI-based deployment,
quota issues, and verification steps.

Summary: Deployment runs via GitHub Actions on every push to `main`. To deploy manually:

```bash
gh workflow run deploy.yml --repo nmajor/abp-unikraft --ref main
```

To deploy a new Chromium release, update `ABP_STEALTH_VERSION` in `Dockerfile` and push.

Key files:
- `.github/workflows/deploy.yml` — CI workflow (build Docker image + deploy)
- `Dockerfile` — image definition, references the GitHub Release tag
- `scripts/deploy.sh` — local deploy script (requires Docker, won't work in dev env)

### Test a Deployment

```bash
./scripts/test-deployment.sh
```

## Environment

- **Hetzner API Token**: `$HETZNER_API_TOKEN` (stored in `~/.zshrc`)
- **SSH Key**: `abp-build-key` (Hetzner ID: 110221547), key at `~/.ssh/id_ed25519`
- **GitHub**: `gh` CLI authenticated as `nmajor`

## Flag Reference (wrapper.sh)

These are **fingerprint-chromium flags**, not the legacy `--abp-*` flags:

| Env Var | Flag | Default |
|---------|------|---------|
| `ABP_FINGERPRINT_SEED` | `--fingerprint=` | `$RANDOM` |
| `ABP_FINGERPRINT_PLATFORM` | `--fingerprint-platform=` | `windows` |
| `ABP_FINGERPRINT_BRAND` | `--fingerprint-brand=` | `Chrome` |
| `ABP_FINGERPRINT_HARDWARE_CONCURRENCY` | `--fingerprint-hardware-concurrency=` | `8` |
| `ABP_TIMEZONE` | `--timezone=` | `America/New_York` |
| `ABP_DISABLE_SPOOFING` | `--disable-spoofing=` | *(none)* |
| `ABP_WINDOW_SIZE` | `--abp-window-size=` | `1280,800` |
| `ABP_PROXY_SERVER` | `--proxy-server=` (via gost) | *(none)* |

## Stealth-Extra Patches (What We Maintain)

These 6 patches cover surfaces fingerprint-chromium does NOT patch:

1. **012** — `window.outerWidth/outerHeight` (headless returns 0)
2. **016** — Permissions.query() consistency
3. **017** — Remove automation flags (11 telltale flags)
4. **018** — `(pointer: fine)` / `(hover: hover)` media queries (**CRITICAL for DataDome**)
5. **020** — `navigator.deviceMemory` (hide server RAM)
6. **021** — `screen.width/height/colorDepth` (realistic values)

## Key Documentation

| Doc | Purpose |
|-----|---------|
| `README.md` | Project overview, API usage, stealth details |
| `MIGRATION.md` | Full migration story: custom 22-patch Chromium 129 → fingerprint-chromium 144 |
| `docs/workflows/hetzner-build.md` | Step-by-step Chromium build procedure + known issues |
| `docs/workflows/deploy-to-kraftcloud.md` | Docker image build + KraftCloud deployment via CI |

## Continuous Improvement

IMPORTANT:
- Every new Chromium build/release must record the exact `fingerprint-chromium` tag, the GitHub release tag, and a short release note describing what changed.
- Update this file, `README.md`, `MIGRATION.md`, and the GitHub release notes when a new build is cut.
- If a watchdog or Hetzner build uncovers a recurring failure mode, encode the fix in scripts/docs so the next build is smoother.
- Never ship a new binary without an auditable paper trail of version, release tag, and notable changes.

When doing builds or making changes, update:
- `docs/workflows/hetzner-build.md` — with any new issues/solutions
- `docs/workflows/deploy-to-kraftcloud.md` — with any deploy issues/solutions
- `MIGRATION.md` — if architecture changes
- `README.md` — if stealth capabilities or API changes
- This file — if new workflows or key info emerges
