# Migration: ABP Stealth → fingerprint-chromium Base

## Overview

This documents the rebase of ABP's stealth browser from a custom-patched Chromium 129
to **fingerprint-chromium** (currently Chrome 144+) as the stealth base.

## Why

| Problem | Impact | Solution |
|---------|--------|----------|
| Chrome 129 is 18 months old | TLS fingerprint doesn't match current Chrome; suspicious version age | fingerprint-chromium tracks upstream (144+) |
| `Sec-Ch-Ua-Platform: "Linux"` | Cross-check failure against Windows UA claim | fingerprint-chromium patches Client Hints natively |
| 22 C++ patches to maintain | Every Chromium bump requires rebasing all 22 | Reduced to 6 stealth-extra patches |
| TLS/HTTP2 fingerprint unverified | May not match stock Chrome | Current Chromium base = matching fingerprints |

## Architecture

```
┌─────────────────────────────────────────────────┐
│  fingerprint-chromium (upstream, BSD-3)          │
│  └── ~20 stealth patches (canvas, WebGL, audio, │
│      fonts, Client Hints, CDP, UA, GPU, etc.)   │
├─────────────────────────────────────────────────┤
│  ABP protocol (our code, overlaid)              │
│  └── chrome/browser/abp/ (REST API, sessions)   │
├─────────────────────────────────────────────────┤
│  Stealth-extra patches (6, ours)                │
│  └── Surfaces fingerprint-chromium doesn't cover │
├─────────────────────────────────────────────────┤
│  Feature edits (ours)                           │
│  └── Bandwidth metering + full page screenshot  │
├─────────────────────────────────────────────────┤
│  wrapper.sh + gost + Dockerfile + KraftCloud    │
└─────────────────────────────────────────────────┘
```

## Flag Mapping (Old → New)

| Old Flag (ABP custom) | New Flag (fingerprint-chromium) | Notes |
|-----------------------|-------------------------------|-------|
| `--abp-fingerprint=SEED` | `--fingerprint=SEED` | Master stealth switch |
| `--abp-fingerprint-platform=windows` | `--fingerprint-platform=windows` | Also sets Client Hints |
| `--abp-timezone=America/New_York` | `--timezone=America/New_York` | Same IANA format |
| `--user-agent=...` | *(not needed)* | Handled by `--fingerprint-platform` + `--fingerprint-brand` |
| `--disable-features=UserAgentClientHint` | *(not needed)* | Client Hints patched at C++ level |
| `--abp-fingerprint-gpu-vendor=...` | *(not needed)* | Auto-selected from seed (removed in Chrome 144) |
| `--abp-fingerprint-gpu-renderer=...` | *(not needed)* | Auto-selected from seed (removed in Chrome 144) |
| *(new)* | `--fingerprint-brand=Chrome` | Sets brand in UA + Client Hints |
| *(new)* | `--disable-non-proxied-udp` | WebRTC IP leak protection |
| *(new)* | `--disable-spoofing=font,gpu` | Granular kill switch (Chrome 144+) |

The modern runtime contract is now native to fingerprint-chromium. The ABP
overlay must not reintroduce legacy `--abp-fingerprint*` stealth switches or
launch-time overrides that fight fp-chromium. The build pipeline enforces this
with `scripts/verify-abp-overlay-contract.sh` after the ABP source overlay step.

## Patch Inventory

### Dropped (covered by fingerprint-chromium upstream)

| # | Patch | fp-chromium equivalent |
|---|-------|-----------------------|
| 000 | Build integration | `000-add-fingerprint-switches.patch` |
| 001 | Propagate switches | Part of `000-add-fingerprint-switches.patch` |
| 002 | navigator.webdriver | `009-webdriver.patch` |
| 003 | Runtime.enable | `001-disable-runtime.enable.patch` |
| 004 | User-Agent spoof | `002-user-agent-fingerprint.patch` + `010-headless.patch` |
| 005 | navigator.plugins | Auto in Chrome 133+ |
| 006 | WebGL vendor/renderer | `011-gpu-info.patch` |
| 007 | Canvas getImageData | `012-canvas-get-image-data.patch` |
| 008 | Canvas toDataURL | `013-canvas-toDataURL.patch` |
| 009 | WebGL readPixels | `016-webgl-readPixels.patch` |
| 010 | Audio fingerprint | `003-audio-fingerprint.patch` |
| 011 | Font enumeration | `006-font-fingerprint.patch` |
| 013 | Client rects | `014-client-rects.patch` |
| 014 | measureText | `015-canvas-measure-text.patch` |
| 015 | Timezone | `018-timezone.patch` |
| 019 | Hardware concurrency | `005-hardware-concurrency-fingerprint.patch` |

### Kept (stealth-extra — NOT covered upstream)

| # | Patch | Why fingerprint-chromium doesn't cover it |
|---|-------|------------------------------------------|
| 012 | Window outer dimensions | Headless outerHeight=0 not addressed upstream |
| 016 | Permissions consistency | Notification.permission mismatch not addressed |
| 017 | Remove automation flags | More comprehensive flag removal (11 flags) |
| 018 | Pointer/hover media query | **Explicitly noted as gap** in fp-chromium docs |
| 020 | Device memory spoof | No explicit override (only seed-derived) |
| 021 | Screen properties spoof | Screen dimensions not addressed upstream |

### ABP-specific (always kept)

| Component | Files |
|-----------|-------|
| ABP REST API + protocol | `chrome/browser/abp/` (entire directory) |
| Bandwidth metering | `apply-feature-edits.sh` → abp_network_capture, abp_action_context |
| Full page screenshot | `apply-feature-edits.sh` → abp_controller |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ABP_FINGERPRINT_SEED` | `$RANDOM` | Fingerprint seed (deterministic per session) |
| `ABP_FINGERPRINT_PLATFORM` | `windows` | Platform to spoof (`windows`, `macos`, `linux`) |
| `ABP_FINGERPRINT_BRAND` | `Chrome` | Browser brand (`Chrome`, `Edge`, `Opera`, `Vivaldi`) |
| `ABP_FINGERPRINT_HARDWARE_CONCURRENCY` | `8` | Native fp-chromium hardware concurrency override |
| `ABP_TIMEZONE` | `America/New_York` | IANA timezone (should match proxy geo) |
| `ABP_DISABLE_SPOOFING` | *(none)* | Comma-separated spoofing categories to disable (`144+`) |
| `ABP_WINDOW_SIZE` | `1280,800` | ABP viewport/window size (runtime only) |
| `ABP_PROXY_SERVER` | *(none)* | Proxy URL with optional credentials |
| `ABP_PROXY_BYPASS` | *(none)* | Semicolon-separated bypass list |
| `ABP_GOST_PUBLIC_PORT` | `1080` | Public proxy port for CapSolver |
| `ABP_GOST_PUBLIC_USER` | `capsolver` | Public proxy username |
| `ABP_GOST_PUBLIC_PASS` | *(none)* | Public proxy password (enables public proxy) |

## Build Process

### Quick Start (Hetzner)

```bash
# On a fresh Hetzner CCX33 (16 cores, 64GB RAM, ~€0.30/hr):
export FP_CHROMIUM_TAG="142.0.7444.175"  # latest source-available tag validated here
curl -sL https://raw.githubusercontent.com/nmajor/abp-unikraft/main/scripts/build-on-fp-chromium.sh | bash
```

### Build Steps

1. Fetch fingerprint-chromium source (tagged release)
2. Download + unpack Chromium source via fp-chromium's build system
3. Apply ungoogled-chromium + fingerprint-chromium patches
4. Overlay ABP protocol code (`chrome/browser/abp/`)
5. Verify the overlay does not reintroduce legacy `abp-fingerprint*` remapping (`scripts/verify-abp-overlay-contract.sh`)
6. Apply stealth-extra edits (`scripts/apply-stealth-extra-edits.sh`)
7. Apply feature edits (`scripts/apply-feature-edits.sh`)
8. Build with ninja (~4 hours on CCX33, ~2 hours on CCX63)
9. Package + upload to GitHub Release

### Upgrading fingerprint-chromium

When a new fingerprint-chromium source tag is released:

1. Update `FP_CHROMIUM_TAG` in `build-on-fp-chromium.sh`
2. Run the build script on a fresh Hetzner server
3. If stealth-extra edits fail (anchor strings changed):
   - Check the failing edit in `apply-stealth-extra-edits.sh`
   - Update the anchor string for the new Chromium version
   - Re-run
4. Update `ABP_STEALTH_VERSION` in `Dockerfile`
5. Push to trigger KraftCloud rebuild

## Directory Structure

```
abp-unikraft/
├── patches/
│   ├── stealth-extra/          # Our 6 patches (surfaces fp-chromium misses)
│   │   ├── series              # Application order
│   │   ├── 012-window-outer-dimensions.patch
│   │   ├── 016-permissions-consistency.patch
│   │   ├── 017-remove-automation-flags.patch
│   │   ├── 018-pointer-media-query-fine.patch
│   │   ├── 020-device-memory-spoof.patch
│   │   └── 021-screen-properties-spoof.patch
│   └── legacy/                 # Old patches (reference only, not applied)
│       ├── 000-stealth-build-integration.patch
│       ├── ... (16 patches replaced by fingerprint-chromium)
│       └── 019-hardware-concurrency-spoof.patch
├── scripts/
│   ├── build-on-fp-chromium.sh     # NEW: main build script
│   ├── apply-stealth-extra-edits.sh # NEW: stealth gaps not in fp-chromium
│   ├── apply-feature-edits.sh      # KEPT: bandwidth metering + screenshot
│   ├── build-on-hetzner.sh         # LEGACY: old build script (reference)
│   ├── apply-stealth-edits.sh      # LEGACY: old stealth edits (reference)
│   ├── deploy.sh                   # KEPT: KraftCloud deployment
│   └── test-deployment.sh          # KEPT: deployment verification
├── wrapper.sh                      # UPDATED: fingerprint-chromium flags
├── Dockerfile                      # UPDATED: comment about fp-chromium base
├── MIGRATION.md                    # THIS FILE
└── README.md
```
