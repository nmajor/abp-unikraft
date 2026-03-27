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

# Get page text (full body or CSS selector)
curl -s -X POST "$ABP/api/v1/tabs/{id}/text" \
    -H "Content-Type: application/json" -d '{}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/text" \
    -H "Content-Type: application/json" \
    -d '{"selector": "#firstHeading"}'

# Scroll (requires x/y position + scrolls array with delta_px and direction)
curl -s -X POST "$ABP/api/v1/tabs/{id}/scroll" \
    -H "Content-Type: application/json" \
    -d '{"x":640,"y":400,"scrolls":[{"delta_px":300,"direction":"y"}]}'

# Click at coordinates
curl -s -X POST "$ABP/api/v1/tabs/{id}/click" \
    -H "Content-Type: application/json" \
    -d '{"x": 300, "y": 200}'

# Type text (click input first to focus)
curl -s -X POST "$ABP/api/v1/tabs/{id}/type" \
    -H "Content-Type: application/json" \
    -d '{"text": "hello world"}'

# Keyboard press
curl -s -X POST "$ABP/api/v1/tabs/{id}/keyboard/press" \
    -H "Content-Type: application/json" \
    -d '{"key": "Enter"}'

# Back / Forward / Reload
curl -s -X POST "$ABP/api/v1/tabs/{id}/back" -H "Content-Type: application/json" -d '{}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/forward" -H "Content-Type: application/json" -d '{}'
curl -s -X POST "$ABP/api/v1/tabs/{id}/reload" -H "Content-Type: application/json" -d '{}'

# Wait (pause for specified ms)
curl -s -X POST "$ABP/api/v1/tabs/{id}/wait" \
    -H "Content-Type: application/json" -d '{"ms": 1000}'

# Create / Close tabs
curl -s -X POST "$ABP/api/v1/tabs" \
    -H "Content-Type: application/json" -d '{"url":"about:blank"}'
curl -s -X DELETE "$ABP/api/v1/tabs/{id}"
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

## Verified Test Results

All tests performed on the live KraftCloud deployment (fra metro, 4GB, stealth-v0.1.0 binary).

### Scale-to-Zero Performance (5 trials)

The instance was confirmed in `standby` state before each request.
Start count incremented on every request, confirming full power-down/resume cycle.

| Trial | Unikraft Boot | Total Round-Trip | Instance State Before |
|---|---|---|---|
| 1 | 9.36ms | 205ms | standby |
| 2 | 9.51ms | 194ms | standby |
| 3 | 9.57ms | 195ms | standby |
| 4 | 10.17ms | 193ms | standby |
| 5 | 10.32ms | 197ms | standby |

Round-trip includes network latency to Frankfurt + TLS handshake + Unikraft wake + ABP response.

### Agent Action Cycle (wake from standby → action → sleep between each)

Each action was sent after waiting for the instance to scale to zero (confirmed `standby` state).

| Action | Total (wake+action) | ABP Internal Profiling | Unikraft Boot |
|---|---|---|---|
| Get tabs | 201ms | n/a | 8.60ms |
| Navigate to example.com | 960ms | 716ms | 9.85ms |
| Execute JavaScript | 899ms | 639ms | 9.98ms |
| Take screenshot | 833ms | 588ms | 9.69ms |
| Navigate to httpbin.org | 3,226ms | 2,970ms (network fetch) | 9.41ms |

### State Persistence Across Scale-to-Zero

Verified after multiple standby/resume cycles:
- Browser remembers last URL (`https://httpbin.org/headers`)
- Virtual time stays frozen (`paused: True`, `base_ticks_ms: 60837.058`)
- Tab IDs survive scale-to-zero (same ID across cycles)
- Start count reached 17 across all tests, confirming each request triggered a full resume

### Bot Detection Test (bot.sannysoft.com)

Full results from the stealth-v0.1.0 binary:

| Test | Result |
|---|---|
| User Agent | `Chrome/146.0.0.0` (no "Headless") — **passed** |
| WebDriver (New) | `missing` — **passed** |
| WebDriver Advanced | **passed** |
| Chrome Object | `present` — **passed** |
| Permissions | `prompt` — **passed** |
| Plugins Length | `5` — **passed** |
| Plugins Type | `PluginArray` — **passed** |
| Languages | `en-US` — **passed** |
| Broken Image | `16x16` — **passed** |
| PHANTOM_UA | **ok** |
| PHANTOM_PROPERTIES | **ok** |
| PHANTOM_ETSL | **ok** |
| PHANTOM_LANGUAGE | **ok** |
| PHANTOM_WEBSOCKET | **ok** |
| MQ_SCREEN | **ok** |
| PHANTOM_OVERFLOW | **ok** |
| PHANTOM_WINDOW_HEIGHT | **ok** |
| HEADCHR_UA | **ok** |
| HEADCHR_CHROME_OBJ | **ok** |
| HEADCHR_PERMISSIONS | **ok** |
| HEADCHR_PLUGINS | **ok** |
| HEADCHR_IFRAME | **ok** |
| CHR_DEBUG_TOOLS | **ok** |
| SELENIUM_DRIVER | **ok** |
| CHR_BATTERY | **ok** |
| CHR_MEMORY | **ok** |
| TRANSPARENT_PIXEL | **ok** |
| SEQUENTUM | **ok** |
| VIDEO_CODECS | WARN (h264 — expected, Chromium lacks proprietary codecs) |

### Stealth Signal Verification

Measured on `about:blank` via ABP's `/tabs/{id}/execute` endpoint:

| Signal | Value | Expected (real Chrome) | Match? |
|---|---|---|---|
| `navigator.webdriver` | `false` | `false` | Yes |
| `navigator.userAgent` | `Mozilla/5.0 (X11; Linux x86_64) ... Chrome/146.0.0.0 Safari/537.36` | No "Headless" | Yes |
| `navigator.plugins.length` | `5` | `5` | Yes |
| `typeof window.chrome` | `object` | `object` | Yes |
| `window.chrome` keys | `loadTimes,csi,app` | `loadTimes,csi,app` | Yes |
| `navigator.languages` | `["en-US"]` | `["en-US"]` | Yes |
| `window.outerWidth x outerHeight` | `1280x800` | nonzero | Yes |
| `navigator.platform` | `Linux x86_64` | `Win32` (if spoofing Windows) | No* |
| WebGL vendor | `Google Inc. (Google)` | Real GPU vendor | No* |
| WebGL renderer | `SwiftShader` | Real GPU name | No* |

*These patches are written but need insertion point adjustment for ABP's Chromium version. Fixable on next build.

### Scraping Tests

| Site | Anti-Bot | Status | Data Extracted |
|---|---|---|---|
| **Wikipedia** | None | **Works** | Full article content — Cascais municipality history, demographics, geography (3000+ chars) |
| **Hacker News** | None | **Works** | Top 10 headlines with links extracted via `.titleline a` selector |
| **GitHub Trending** | Rate limiting | **Works** | 9 trending repos with names (e.g., `bytedance/deer-flow`, `twentyhq/twenty`) |
| **Reuters** | Moderate | **Works** | 14 tech news headlines with dates extracted from article elements |
| **Zillow** | PerimeterX/HUMAN | **Works** | Full property data: Zestimate ($143,500), beds (--), baths (1), sqft (1,152), year built (1959), lot size, estimated rent ($1,647/mo) |
| **Amazon** | Advanced | **Partial** | Product title, 4.6-star rating, full description. Price not shown — geo-restriction (Frankfurt IP = "cannot ship to Germany"), not bot detection |
| **Reddit** (old.reddit) | Moderate | **Works** | Page loads with full subreddit listing, navigation, sidebar. Post selectors need tuning for old.reddit DOM structure |
| **Google Maps** | IP-based | **Blocked** | Consent wall with no interactive buttons — Google serves degraded page to datacenter IPs regardless of browser fingerprint |
| **DuckDuckGo** | IP-based | **Blocked** | Bot CAPTCHA — datacenter IP detection |
| **Bing** | IP-based | **Blocked** | CAPTCHA after initial query — datacenter IP |
| **bot.sannysoft.com** | Detection test | **All pass** | Every test passes (see table above) |
| **TimeOut Lisbon** | Cloudflare | **Partial** | Page loaded but specific bakery URL was 404. General Lisbon food/restaurant content extracted successfully |
