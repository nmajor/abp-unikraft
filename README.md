# ABP Unikraft — Stealth Browser Service for LLM Agents

A stealth-patched [Agent Browser Protocol](https://github.com/theredsix/agent-browser-protocol) (ABP) running on [Unikraft](https://unikraft.com) unikernels with scale-to-zero. Browser only runs during active agent actions (~10ms wake from snapshot), sleeps between steps.

## Architecture

```
LLM Agent → HTTPS → KraftCloud LB → Unikraft VM → socat → ABP (Chromium fork)
                                          ↕
                              Scale-to-zero / Snapshot resume (~10ms)
```

**ABP** freezes JavaScript execution between agent steps (Debugger.pause + virtual time freeze).
**Unikraft** statefully snapshots the VM when idle and resumes from snapshot in ~10ms.
Combined: the browser costs zero compute while the LLM is thinking.

## Performance (measured on KraftCloud)

| Metric | Value |
|---|---|
| First cold boot (Chromium init) | ~2,900ms |
| Wake from snapshot | **~10ms** |
| Total request round-trip (network + TLS + wake) | ~200ms |
| Scale-to-zero cooldown | 5 seconds |
| Image size | 356 MB |
| Memory | 4 GB |

## Stealth Patches

C++ source-level modifications to Chromium, applied during build. All gated behind `--abp-fingerprint=<seed>`.

**Currently applied (in the binary):**
- `navigator.webdriver` → always returns `false` (C++ level, undetectable)
- User-Agent → "HeadlessChrome" removed, reports as regular `Chrome/146.0.0.0`
- `navigator.plugins` → 5 PDF plugins populated even in headless mode
- `AutomationControlled` Blink feature disabled at startup
- Bot detection test (bot.sannysoft.com) → **all tests pass**

**Prepared patches (in `patches/` — need insertion point adjustment for ABP's Chromium version):**
- WebGL vendor/renderer spoofing (SwiftShader → NVIDIA RTX 3070)
- `navigator.platform` spoofing (Linux → Win32)
- Canvas/WebGL pixel readback noise (defeats fingerprinting)
- Audio context frame count/sample rate noise
- Font enumeration filtering by platform
- `window.outerWidth/outerHeight` realistic values
- Client rects / measureText sub-pixel noise
- Timezone override
- `Runtime.enable` CDP detection neutralization

**Not fixable via patches (infrastructure):**
- Datacenter IP detection — needs residential proxy

## Project Structure

```
├── Dockerfile                  # Runtime image (downloads stealth binary from GH Release)
├── wrapper.sh                  # Entrypoint: starts socat proxy + ABP with stealth flags
├── patches/                    # Chromium patch files (template-style .patch + series)
│   ├── series                  # Patch application order
│   └── 000-017-*.patch         # Individual patches with Description headers
├── scripts/
│   ├── apply-stealth-edits.sh  # Python/sed-based source edits (more robust than git apply)
│   ├── build-on-hetzner.sh     # One-script build on a rented Hetzner server (~€0.30)
│   ├── build-local-mac.sh      # Build on macOS (produces macOS binary)
│   ├── build-linux-via-docker.sh # Build Linux binary via Docker
│   └── deploy.sh               # Deploy to KraftCloud
├── src/chrome/browser/abp/stealth/  # New C++ source files (copied into Chromium tree)
│   ├── abp_stealth_switches.cc/.h   # --abp-fingerprint, --abp-fingerprint-platform, etc.
│   ├── abp_stealth_utils.cc/.h      # Seed hashing, ShuffleSubchannelColorData()
│   ├── abp_fingerprint_data.h       # GPU models, font lists, platform data
│   └── BUILD.gn                     # Build integration
└── .github/workflows/deploy.yml     # GH Actions: build Docker image → push to KraftCloud
```

## Building the Stealth Binary

The binary is a full Chromium build with ABP + our patches. First build takes ~4 hours, incremental rebuilds take minutes.

### Option 1: Hetzner Cloud (~€0.30, recommended)

```bash
# 1. Create a CCX33 server at console.hetzner.cloud (Ubuntu 22.04 or 24.04)
# 2. SSH in and run:
apt-get update && apt-get install -y screen
screen -S build
curl -sL https://raw.githubusercontent.com/nmajor/abp-unikraft/main/scripts/build-on-hetzner.sh | bash
# 3. Ctrl+A D to detach. Check back in ~4 hours.
# 4. Binary uploads to GitHub Releases automatically.
# 5. DELETE the server at Hetzner Console.
```

### Option 2: Local machine (needs 16GB+ RAM, 120GB disk)

```bash
git clone https://github.com/nmajor/abp-unikraft.git
cd abp-unikraft
./scripts/build-local-mac.sh    # macOS (for local testing)
./scripts/build-linux-via-docker.sh  # Linux binary via Docker
```

### Incremental Rebuild (after changing patches)

On a machine with an existing build tree at `/root/build/src`:

```bash
export PATH="/root/build/depot_tools:${PATH}"
export DEPOT_TOOLS_UPDATE=0
cd /root/build/src

# Revert old edits, pull new patches, re-apply
git checkout -- .
cd /root/abp-unikraft && git pull && cd /root/build/src
bash /root/abp-unikraft/scripts/apply-stealth-edits.sh /root/build/src

# Rebuild (only recompiles changed files — minutes, not hours)
autoninja -C out/Release chrome

# Package and upload
cd out/Release
mkdir -p /tmp/pkg/abp-chrome
cp -a abp chrome_crashpad_handler vk_swiftshader_icd.json icudtl.dat \
      v8_context_snapshot.bin snapshot_blob.bin /tmp/pkg/abp-chrome/ 2>/dev/null
cp -a *.so* *.pak /tmp/pkg/abp-chrome/ 2>/dev/null
cp -ra locales lib /tmp/pkg/abp-chrome/ 2>/dev/null
cd /tmp/pkg && tar -czf /root/abp-stealth-linux-x64.tar.gz abp-chrome/

gh release delete stealth-v0.1.0 --repo nmajor/abp-unikraft --yes
gh release create stealth-v0.1.0 --repo nmajor/abp-unikraft \
    --title "ABP Stealth Build v0.1.0" \
    --notes "description of changes" \
    /root/abp-stealth-linux-x64.tar.gz
```

## Deploying to Unikraft

After the binary is uploaded as a GitHub Release:

```bash
# 1. Push to trigger GH Actions Docker image build
git push

# 2. Wait for image to appear (~5 min)
kraft cloud image list

# 3. Create instance
kraft cloud instance create \
    --name abp-stealth \
    --scale-to-zero idle \
    --scale-to-zero-stateful \
    --scale-to-zero-cooldown 5s \
    --restart on-failure \
    -p 443:15678 \
    -M 4096 \
    -S \
    nmajor-studios/abp-unikraft:latest
```

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
```

Full API docs: https://github.com/theredsix/agent-browser-protocol

## Stealth Configuration (Environment Variables)

| Variable | Default | Description |
|---|---|---|
| `ABP_FINGERPRINT_SEED` | random | Deterministic seed for all fingerprint values |
| `ABP_FINGERPRINT_PLATFORM` | `windows` | Spoofed platform (`windows`, `macos`, `linux`) |
| `ABP_TIMEZONE` | `America/New_York` | Spoofed timezone (IANA identifier) |
| `ABP_PORT` | `15678` | External API port |

## Updating When ABP Releases a New Version

ABP is a Chromium fork that releases roughly weekly. Our stealth patches touch different files than ABP's core code, so updates are straightforward:

1. **Rent a Hetzner CCX33** (~€0.30)
2. **Pull the new ABP source:**
   ```bash
   cd /root/build && gclient sync --no-history
   ```
3. **Revert old edits and re-apply:**
   ```bash
   cd /root/build/src && git checkout -- .
   bash /root/abp-unikraft/scripts/apply-stealth-edits.sh /root/build/src
   ```
4. **Incremental rebuild** (only changed files recompile — minutes):
   ```bash
   autoninja -C out/Release chrome
   ```
5. **Package, upload, deploy** (same as above)
6. **Delete the server**

Our patches target stable web standard APIs (WebGL, Canvas, Navigator) that rarely change in Chromium, so they should apply cleanly across versions.

## Known Limitations

- **Datacenter IP** — Google, Cloudflare, DuckDuckGo block based on the KraftCloud Frankfurt IP. Residential proxy required for these sites.
- **WebGL reports SwiftShader** — The C++ spoofing patch needs its insertion point adjusted for ABP's specific Chromium version. Works for most detection tests but advanced fingerprinters can still see SwiftShader.
- **`navigator.platform` shows Linux** — Same insertion point issue. Fixable on next build.
- **No GPU** — Running in a unikernel with no GPU. SwiftShader provides software rendering.
- **4GB memory limit** — KraftCloud free tier cap. Heavy pages may be constrained.

## Scraping Test Results

| Site | Status | Notes |
|---|---|---|
| Wikipedia | Works | Full article extraction |
| Hacker News | Works | Headlines, links, metadata |
| GitHub Trending | Works | Repo names, stars |
| Reuters | Works | News headlines, dates |
| Zillow | Works | Full property data (Zestimate, beds/baths, sqft) — passes PerimeterX |
| Amazon | Partial | Product info works. Price hidden due to geo-restriction (Frankfurt IP), not bot detection |
| Reddit (old) | Works | Page loads, needs selector tuning |
| Google Maps | Blocked | Datacenter IP, not fingerprint. Needs residential proxy |
| bot.sannysoft.com | **All pass** | Every detection test passes except h264 codec (expected for Chromium) |
