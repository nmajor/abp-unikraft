# ABP Unikraft — Stealth Browser Service for LLM Agents

A stealth-patched [Agent Browser Protocol](https://github.com/theredsix/agent-browser-protocol) (ABP) running on [Unikraft](https://unikraft.com) unikernels with scale-to-zero. Browser only runs during active agent actions (~10ms wake from snapshot), sleeps between steps.

## Architecture

```
fingerprint-chromium (stealth base, ~20 patches, BSD-3)
  + ABP protocol (REST API, sessions, chrome/browser/abp/)
  + stealth-extra patches (6 patches we maintain, gaps in fp-chromium)
  + feature edits (bandwidth metering, full page screenshot)
  + wrapper.sh (gost proxy chain, stealth flags, socat)
  + Dockerfile → KraftCloud deployment
```

```
LLM Agent → HTTPS → KraftCloud LB → Unikraft VM → socat → ABP (Chromium 144)
                                          ↕
                              Scale-to-zero / Snapshot resume (~10ms)
```

**ABP** freezes JavaScript execution between agent steps (Debugger.pause + virtual time freeze).
**Unikraft** statefully snapshots the VM when idle and resumes from snapshot in ~10ms.
Combined: the browser costs zero compute while the LLM is thinking.

## Stealth Base: fingerprint-chromium

We build on [fingerprint-chromium](https://github.com/adryfish/fingerprint-chromium) (BSD-3),
an open-source Chromium fork with ~20 C++ stealth patches. This replaced our old approach
of maintaining 22 custom patches on Chromium 129. See [MIGRATION.md](MIGRATION.md) for the full migration story.

**What fingerprint-chromium provides:**
- Canvas/WebGL fingerprint noise
- Audio context manipulation
- Font enumeration filtering
- Client Hints patching (native C++ level)
- User-Agent spoofing (no "Headless")
- CDP (`Runtime.enable`) detection neutralization
- GPU info spoofing
- Hardware concurrency spoofing
- navigator.webdriver = false
- And ~10 more stealth surfaces

**What we add on top (stealth-extra patches):**
- `window.outerWidth/outerHeight` — headless returns 0 without this
- `Permissions.query()` consistency
- Remove 11 automation flags (CRITICAL for DataDome)
- `(pointer: fine)` / `(hover: hover)` media queries (CRITICAL for DataDome)
- `navigator.deviceMemory` spoofing (hide server RAM)
- `screen.width/height/colorDepth` spoofing

**Feature patches (ours):**
- Bandwidth metering — per-action and per-session byte counters in API responses
- Full page screenshot — `POST /api/v1/tabs/{id}/screenshot/full` captures entire scrollable page

All stealth is controlled via native `fingerprint-chromium` flags. ABP-specific
flags remain only for protocol/runtime concerns such as the HTTP port, session
directory, and viewport sizing.

## Performance (measured on KraftCloud)

| Metric | Value |
|---|---|
| First cold boot (Chromium init) | ~2,900ms |
| Wake from snapshot | **~10ms** |
| Total request round-trip (network + TLS + wake) | ~200ms |
| Scale-to-zero cooldown | 5 seconds |
| Memory | 4 GB |

## Project Structure

```
├── Dockerfile                         # Runtime image (downloads stealth binary from GH Release)
├── wrapper.sh                         # Entrypoint: gost proxy + ABP with fingerprint-chromium flags
├── MIGRATION.md                       # Full migration docs (old patches → fingerprint-chromium)
├── patches/
│   ├── stealth-extra/                 # 6 patches we maintain (fp-chromium gaps)
│   └── legacy/                        # Old 22 patches (reference only, replaced by fp-chromium)
├── scripts/
│   ├── build-on-fp-chromium.sh        # Main build script (runs on Hetzner VM)
│   ├── verify-abp-overlay-contract.sh # Guard ABP overlay against legacy stealth remapping
│   ├── apply-stealth-extra-edits.sh   # Apply our 6 stealth gap patches
│   ├── apply-feature-edits.sh         # Bandwidth metering + full page screenshot
│   ├── hetzner-build.sh               # Orchestrator: create VM → build → upload → destroy
│   ├── deploy.sh                      # Local deploy to KraftCloud (needs Docker)
│   └── test-deployment.sh             # Verify a deployment
├── docs/workflows/
│   ├── hetzner-build.md               # Step-by-step Chromium build procedure + known issues
│   └── deploy-to-kraftcloud.md        # Docker image build + KraftCloud deployment
└── .github/workflows/deploy.yml       # CI: build Docker image → deploy to KraftCloud on push
```

## Building the Stealth Binary

The binary is a full Chromium build with fingerprint-chromium patches + ABP protocol + our extras.
First build takes ~4-6 hours on a Hetzner CPX51.

**Read [docs/workflows/hetzner-build.md](docs/workflows/hetzner-build.md) for the complete procedure and known issues.**

```bash
# Quick version: automated orchestrator
./scripts/hetzner-build.sh
```

Key steps:
1. Create temporary Hetzner CPX51 VM (~€0.25-0.50 total)
2. Clone fingerprint-chromium (latest source-available tagged release, currently 142.0.7444.175; newer upstream binary-only tags may not be buildable yet)
3. Download + unpack + patch Chromium source
4. Overlay ABP protocol code and fail the build if the overlay reintroduces legacy ABP stealth remapping
5. Apply stealth-extra edits + feature edits
6. Build with ninja (~4-6 hours)
7. Package and upload to GitHub Releases
8. Destroy the VM

## Deploying to KraftCloud

**Read [docs/workflows/deploy-to-kraftcloud.md](docs/workflows/deploy-to-kraftcloud.md) for full details.**

Deployment runs automatically via GitHub Actions on every push to `main`.

```bash
# To deploy a new Chromium release:
# 1. Update ABP_STEALTH_VERSION in Dockerfile to the new release tag
# 2. Commit and push to main — CI deploys automatically

# Or trigger manually:
gh workflow run deploy.yml --repo nmajor/abp-unikraft --ref main
```

Verify:
```bash
curl -s "https://<fqdn>/api/v1/browser/status"
# {"data":{"components":{"browser_window":true,"devtools":true,"http_server":true},...},"success":true}
```

## Stealth Configuration (Environment Variables)

| Variable | Default | Description |
|---|---|---|
| `ABP_FINGERPRINT_SEED` | random | Deterministic seed for all fingerprint values |
| `ABP_FINGERPRINT_PLATFORM` | `windows` | Spoofed platform (`windows`, `macos`, `linux`) |
| `ABP_FINGERPRINT_BRAND` | `Chrome` | Browser brand (`Chrome`, `Edge`, `Opera`, `Vivaldi`) |
| `ABP_FINGERPRINT_HARDWARE_CONCURRENCY` | `8` | Native fp-chromium hardware concurrency override |
| `ABP_TIMEZONE` | `America/New_York` | Spoofed timezone (IANA identifier) |
| `ABP_DISABLE_SPOOFING` | *(none)* | Comma-separated fp-chromium spoofing categories to disable (`144+`) |
| `ABP_WINDOW_SIZE` | `1280,800` | ABP viewport/window size (runtime only, not fingerprint spoofing) |
| `ABP_PROXY_SERVER` | *(none)* | Proxy URL (e.g. `socks5://user:pass@host:port`) |
| `ABP_PROXY_BYPASS` | *(none)* | Semicolon-separated hosts to bypass proxy |
| `ABP_GOST_PUBLIC_PORT` | `1080` | Public proxy port for CapSolver |

## Using the API

```bash
ABP="https://<instance-fqdn>.fra.unikraft.app"

# Check status
curl -s "$ABP/api/v1/browser/status"

# List tabs
curl -s "$ABP/api/v1/tabs"

# Navigate
curl -s -X POST "$ABP/api/v1/tabs/{id}/navigate" \
    -H "Content-Type: application/json" \
    -d '{"url": "https://example.com"}'

# Execute JavaScript
curl -s -X POST "$ABP/api/v1/tabs/{id}/execute" \
    -H "Content-Type: application/json" \
    -d '{"script": "document.title"}'

# Take screenshot
curl -s -X POST "$ABP/api/v1/tabs/{id}/screenshot" \
    -H "Content-Type: application/json" -d '{}'

# Get page text (full body or CSS selector)
curl -s -X POST "$ABP/api/v1/tabs/{id}/text" \
    -H "Content-Type: application/json" -d '{}'

# Scroll
curl -s -X POST "$ABP/api/v1/tabs/{id}/scroll" \
    -H "Content-Type: application/json" \
    -d '{"x":640,"y":400,"scrolls":[{"delta_px":300,"direction":"y"}]}'

# Click / Type / Keyboard
curl -s -X POST "$ABP/api/v1/tabs/{id}/click" -H "Content-Type: application/json" -d '{"x": 300, "y": 200}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/type" -H "Content-Type: application/json" -d '{"text": "hello"}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/keyboard/press" -H "Content-Type: application/json" -d '{"key": "Enter"}'

# Navigation
curl -s -X POST "$ABP/api/v1/tabs/{id}/back" -H "Content-Type: application/json" -d '{}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/forward" -H "Content-Type: application/json" -d '{}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/reload" -H "Content-Type: application/json" -d '{}'

# Wait
curl -s -X POST "$ABP/api/v1/tabs/{id}/wait" -H "Content-Type: application/json" -d '{"ms": 1000}'

# Create / Close tabs
curl -s -X POST "$ABP/api/v1/tabs" -H "Content-Type: application/json" -d '{"url":"about:blank"}'
curl -s -X DELETE "$ABP/api/v1/tabs/{id}"
```

Full API docs: https://github.com/theredsix/agent-browser-protocol

## Known Limitations

- **Datacenter IP** — Google, Cloudflare, DuckDuckGo block KraftCloud IPs. Residential proxy required.
- **No GPU** — Running in a unikernel with no GPU. SwiftShader provides software rendering.
- **4GB memory limit** — KraftCloud quota. Heavy pages may be constrained.
- **Video codecs** — h264 not available (Chromium lacks proprietary codecs in open-source builds).
