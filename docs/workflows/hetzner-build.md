# Hetzner Build Workflow

Step-by-step guide for agents to build ABP Stealth Chromium on a temporary Hetzner VM.

For long-running or retryable builds, prefer the watchdog workflow in `docs/workflows/watchdog-deployment.md`.

## Quick Reference

```
Trigger: User says "build on hetzner" or "new build"
Time: 4-6 hours total
Cost: ~€0.25-0.50
Server: CPX51 (16 shared cores, 32GB) in ash (Ashburn)
API Token: $HETZNER_API_TOKEN (in ~/.zshrc)
SSH Key: abp-build-key (ID: 110221547), uses ~/.ssh/id_ed25519
```

## Known Issues & Solutions (CRITICAL — Read Before Building)

These were discovered during builds and will save hours of debugging.

### 1. Hetzner API Token Not in Shell

The Bash tool starts a fresh shell each time. `~/.zshrc` exports are NOT inherited.

**Fix**: Always set the token explicitly in each command:
```bash
export HETZNER_API_TOKEN="..." && curl -H "Authorization: Bearer ${HETZNER_API_TOKEN}" ...
```

### 2. Server Type Quota Limits

Dedicated CPU servers (CCX33, CCX43, etc.) hit "dedicated core limit exceeded" on this account.

**Fix**: Use **shared CPU** types: `cpx51` (16 cores, 32GB). Location `ash` works; EU locations may not support CPX51.

### 3. SSH Variables in Zsh

Do NOT assign ssh/scp to variables in zsh — `SCP="scp -o ..."` then `${SCP} file root@ip:` breaks.

**Fix**: Use the commands directly:
```bash
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR file root@IP:/path
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@IP "command"
```

### 4. GH_TOKEN + `gh auth login` Conflict

When `GH_TOKEN` env var is set, `gh auth login --with-token` fails with a non-zero exit.
Combined with `set -euo pipefail`, this kills the entire build script.

**Fix**: Do NOT call `gh auth login`. Just export `GH_TOKEN` — the `gh` CLI uses it automatically:
```bash
export GH_TOKEN=$(cat /root/.gh_token)
# gh commands will work without gh auth login
```

### 5. Domain Substitution Breaks Download URLs

ungoogled-chromium's domain substitution replaces `googleapis.com` with `9oo91eapis.qjz9zk` in ALL source files, including download scripts for clang, rust, and node.

**Fix**: Restore real domains in the download scripts BEFORE running them:
```bash
cd /root/build/src
sed -i 's|commondatastorage.9oo91eapis.qjz9zk|commondatastorage.googleapis.com|g' \
    tools/clang/scripts/update.py \
    tools/rust/update_rust.py \
    tools/clang/scripts/sync_deps.py
```

### 6. Missing Toolchain Components (Clang, Rust, Node, esbuild)

The lite tarball + ungoogled patches do NOT include prebuilt toolchains. You must download them manually after domain substitution fix.

**Download order** (dependencies exist):
```bash
cd /root/build/src

# 1. GN (build system) — download prebuilt binary
mkdir -p out/Release
wget -q -O /tmp/gn.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-amd64/+/latest"
cd out/Release && unzip -oq /tmp/gn.zip && chmod +x gn && cd /root/build/src

# 2. Clang (C++ compiler) — use Chromium's bundled version
# Fix domain substitution first (see #5), then:
python3 tools/clang/scripts/update.py

# 3. Rust toolchain — required since modern Chromium releases
# Fix domain substitution first (see #5), then:
python3 tools/rust/update_rust.py

# 4. Node.js — must be EXACT version Chromium expects
# Check required version from the unpacked source tree and substitute it below:
grep -r 'NODE_VERSION\|Expected version' third_party/node/ 2>/dev/null
NODE_VER="22.11.0"  # replace with the required version for your Chromium tag
wget -q "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.xz" -O /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /tmp/
mkdir -p third_party/node/linux/node-linux-x64/bin
cp "/tmp/node-v${NODE_VER}-linux-x64/bin/node" third_party/node/linux/node-linux-x64/bin/node
chmod +x third_party/node/linux/node-linux-x64/bin/node

# 5. esbuild — must match version in devtools-frontend
# Check the required version from package.json or the first build error:
ESBUILD_VER="0.25.1"  # replace with the required version for your Chromium tag
wget -q -O /tmp/esbuild.tgz "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ESBUILD_VER}.tgz"
mkdir -p /tmp/esb && tar -xzf /tmp/esbuild.tgz -C /tmp/esb/
mkdir -p third_party/devtools-frontend/src/third_party/esbuild
cp /tmp/esb/package/bin/esbuild third_party/devtools-frontend/src/third_party/esbuild/esbuild
chmod +x third_party/devtools-frontend/src/third_party/esbuild/esbuild
```

### 7. Missing Dev Headers (use_sysroot=false)

Without the Debian sysroot, the system headers are used directly. Many are missing on a fresh Ubuntu 22.04.

**Fix**: Install ALL of these BEFORE starting ninja:
```bash
apt-get install -y libx11-xcb-dev libxcb1-dev libx11-dev \
    libxkbcommon-dev libegl-dev libgles-dev mesa-common-dev libvulkan-dev \
    libxkbfile-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
    libxext-dev libxfixes-dev libxdamage-dev libxcomposite-dev libxtst-dev \
    libxshmfence-dev libwayland-dev wayland-protocols libpci-dev \
    libspeechd-dev libflac-dev libjpeg-dev libpng-dev libwebp-dev \
    libopus-dev libevent-dev libminizip-dev libsnappy-dev libre2-dev \
    libharfbuzz-dev
```

Without this, Dawn/Vulkan/OpenGL targets fail with `X11/Xlib-xcb.h not found` and similar.

### 8. GN Gen: Sysroot and Rust

The build needs `use_sysroot=false` and `use_cups=false` since we don't have the Debian sysroot.
Do NOT set `enable_rust=false` — modern Chromium releases require Rust for core components.

**args.gn should contain:**
```
# Copy from fingerprint-chromium/flags.gn, then append:
use_sysroot=false
use_cups=false
```

### 8. nohup Processes and Environment

When starting long builds via SSH + nohup, environment variables are lost.

**Fix**: Always pass env vars explicitly:
```bash
ssh root@IP "export GH_TOKEN='...'; nohup /root/build.sh > /dev/null 2>&1 &"
```
Or save to a file and read it in the script:
```bash
# On server:
echo "${GH_TOKEN}" > /root/.gh_token && chmod 600 /root/.gh_token
# In build script:
export GH_TOKEN=$(cat /root/.gh_token)
```

### 9. fingerprint-chromium Build Link/Export Fixes

Recent fp-chromium source states can fail late in the build with unresolved fingerprint
symbols after the source overlay is complete.

Observed failures:
- `components/webui/flags/flags_state.cc` directly calls `flags::IsFlagExpired`
  from `chrome/browser/unexpire_flags.h`, which breaks component layering.
- `third_party/blink/common/user_agent/user_agent_metadata.cc` references
  `components/ungoogled` switches without linking
  `//components/ungoogled:ungoogled_switches`.
- `third_party/blink/renderer/core/*` also references fingerprint switches
  without that dep.
- `third_party/blink/renderer/modules/webgl/gpu_fingerprint.cc` and
  `webgl_rendering_context_base.cc` also reference those switches, so
  `//third_party/blink/renderer/modules/webgl` needs the same dep.
- `components/embedder_support/user_agent_utils.cc` also reads fingerprint
  switches, so `//components/embedder_support:user_agent` needs that dep too.
- `UpdateUserAgentMetadataFingerprint` and
  `GetUserAgentFingerprintBrandInfo` are declared in a public Blink header but
  need `BLINK_COMMON_EXPORT` for `libblink_core.so` to resolve them from
  `libblink_common.so`.

**Fix**: Apply these source/GN edits before `gn gen`:
```bash
cd /root/build/src

python3 - <<'PY'
from pathlib import Path

path = Path("components/webui/flags/flags_state.cc")
text = path.read_text()
text = text.replace('#include "chrome/browser/unexpire_flags.h"\n', "")
text = text.replace(
    """    if (skip_feature_entry.Run(entry)) {
      if (flags::IsFlagExpired(flags_storage, entry.internal_name)) {
        desc.insert(0, "!!! NOTE: THIS FLAG IS EXPIRED AND MAY STOP FUNCTIONING OR BE REMOVED SOON !!! ");
      } else {
        continue;
      }
    }
""",
    """    if (skip_feature_entry.Run(entry)) {
      if (delegate_ && delegate_->ShouldExcludeFlag(flags_storage, entry)) {
        desc.insert(0, "!!! NOTE: THIS FLAG IS EXPIRED AND MAY STOP FUNCTIONING OR BE REMOVED SOON !!! ");
      } else {
        continue;
      }
    }
""",
)
text = text.replace(
    """    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {
      if (!flags::IsFlagExpired(storage, entry.internal_name)) {
        continue;
      }
    }
""",
    """    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {
      continue;
    }
""",
)
path.write_text(text)
PY

perl -0pi -e 's|deps = \[\n    "//base",|deps = [\n    "//base",\n    "//components/ungoogled:ungoogled_switches",|s' \
  third_party/blink/common/BUILD.gn
perl -0pi -e 's|void UpdateUserAgentMetadataFingerprint\(UserAgentMetadata\* metadata\);|BLINK_COMMON_EXPORT void UpdateUserAgentMetadataFingerprint(UserAgentMetadata* metadata);|g; s|std::string GetUserAgentFingerprintBrandInfo\(\);|BLINK_COMMON_EXPORT std::string GetUserAgentFingerprintBrandInfo();|g' \
  third_party/blink/public/common/user_agent/user_agent_metadata.h
perl -0pi -e 's|deps = \[\n    ":generate_eventhandler_names",\n    ":make_deprecation_info",\n    "//base",|deps = [\n    ":generate_eventhandler_names",\n    ":make_deprecation_info",\n    "//base",\n    "//components/ungoogled:ungoogled_switches",|s' \
  third_party/blink/renderer/core/BUILD.gn
perl -0pi -e 's|deps = \[\n    "//device/vr/buildflags",|deps = [\n    "//device/vr/buildflags",\n    "//components/ungoogled:ungoogled_switches",|s' \
  third_party/blink/renderer/modules/webgl/BUILD.gn
perl -0pi -e 's|deps = \[\n    ":embedder_support",|deps = [\n    ":embedder_support",\n    "//components/ungoogled:ungoogled_switches",|s' \
  components/embedder_support/BUILD.gn
```

## Step-by-Step Procedure

### Phase 1: Create Server (~2 min)

```bash
export HETZNER_API_TOKEN="..."  # from ~/.zshrc

# Create CPX51 in Ashburn
curl -s -X POST \
    -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "abp-build-TIMESTAMP",
        "server_type": "cpx51",
        "image": "ubuntu-22.04",
        "location": "ash",
        "ssh_keys": [110221547],
        "start_after_create": true
    }' \
    "https://api.hetzner.cloud/v1/servers"

# Save SERVER_ID and SERVER_IP from response
# Wait for SSH (try every 5s for ~2 min)
```

### Phase 2: Setup & Upload (~5 min)

```bash
# Upload scripts
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    scripts/verify-abp-overlay-contract.sh scripts/apply-stealth-extra-edits.sh scripts/apply-feature-edits.sh \
    root@SERVER_IP:/root/

# SSH in and install deps
ssh root@SERVER_IP "apt-get update && apt-get install -y build-essential clang cmake curl git gperf lld \
    libcups2-dev libdrm-dev libgbm-dev libgtk-3-dev libkrb5-dev \
    libnss3-dev libpango1.0-dev libpulse-dev libudev-dev libva-dev \
    libxcomposite-dev libxdamage-dev libxrandr-dev libxshmfence-dev \
    lsb-release ninja-build pkg-config python3 python3-pip sudo wget xz-utils file unzip"
```

### Phase 3: Fetch Source (~20 min)

```bash
# Clone fingerprint-chromium
git clone --depth 1 --branch 142.0.7444.175 \
    https://github.com/adryfish/fingerprint-chromium.git /root/fingerprint-chromium

# Download + unpack + patch Chromium source
cd /root/fingerprint-chromium
mkdir -p build/download_cache
python3 utils/downloads.py retrieve -c build/download_cache -i downloads.ini
mkdir -p /root/build/src
python3 utils/downloads.py unpack -c build/download_cache -i downloads.ini -- /root/build/src
python3 utils/prune_binaries.py /root/build/src pruning.list
python3 utils/patches.py apply /root/build/src patches
python3 utils/domain_substitution.py apply \
    -r domain_regex.list -f domain_substitution.list \
    -c build/domsubcache.tar.gz /root/build/src
```

### Phase 4: Install Toolchains (~10 min)

See "Known Issues #5 and #6" above — fix domain substitution, then download clang, rust, node, esbuild.

### Phase 5: Overlay ABP + Patches (~5 min)

```bash
# Clone ABP protocol source
git clone --depth 1 --branch dev --no-checkout \
    https://github.com/theredsix/agent-browser-protocol.git /root/abp-source
cd /root/abp-source && git sparse-checkout init --cone && git sparse-checkout set chrome/browser/abp && git checkout

# Copy into Chromium tree
cp -r /root/abp-source/chrome/browser/abp /root/build/src/chrome/browser/

# Validate that the overlaid ABP source still uses the native fp-chromium
# runtime contract and has not reintroduced legacy stealth remapping.
bash /root/verify-abp-overlay-contract.sh /root/build/src

# Apply stealth-extra edits
bash /root/apply-stealth-extra-edits.sh /root/build/src

# Apply feature edits (bandwidth metering + full page screenshot)
bash /root/apply-feature-edits.sh /root/build/src

# Re-check after our local edits as a final guard.
bash /root/verify-abp-overlay-contract.sh /root/build/src

# Install Chromium build deps
cd /root/build/src
sudo bash build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm --no-nacl || true
```

### Phase 6: Configure & Build (~3-6 hours)

```bash
cd /root/build/src

# GN gen
cp /root/fingerprint-chromium/flags.gn out/Release/args.gn
echo 'use_sysroot=false' >> out/Release/args.gn
echo 'use_cups=false' >> out/Release/args.gn
out/Release/gn gen out/Release --fail-on-unused-args

# Compile (use nohup for long build)
nohup ninja -C out/Release -j $(nproc) chrome chromedriver > /root/build.log 2>&1 &
```

### Phase 7: Package & Upload (~5 min)

```bash
# Package
PKG=$(mktemp -d) && mkdir -p "${PKG}/abp-chrome"
cd /root/build/src/out/Release
for f in chrome chromedriver chrome_crashpad_handler vk_swiftshader_icd.json icudtl.dat v8_context_snapshot.bin snapshot_blob.bin; do
    [ -f "$f" ] && cp -a "$f" "${PKG}/abp-chrome/"
done
cp -a *.so* *.pak "${PKG}/abp-chrome/" 2>/dev/null || true
cp -ra locales "${PKG}/abp-chrome/" 2>/dev/null || true
[ -f "${PKG}/abp-chrome/chrome" ] && mv "${PKG}/abp-chrome/chrome" "${PKG}/abp-chrome/abp"
cd "${PKG}" && tar -czf /root/abp-stealth-linux-x64.tar.gz abp-chrome/

# Upload release
VERSION="stealth-fp-$(date +%Y%m%d-%H%M%S)"
gh release create "${VERSION}" --repo nmajor/abp-unikraft \
    --title "ABP Stealth ${VERSION}" \
    --notes "Built on fingerprint-chromium 142.0.7444.175" \
    "/root/abp-stealth-linux-x64.tar.gz#abp-stealth-linux-x64.tar.gz"
```

### Phase 8: Cleanup (MANDATORY)

```bash
export HETZNER_API_TOKEN="..."
curl -s -X DELETE -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
    "https://api.hetzner.cloud/v1/servers/${SERVER_ID}"
```

## Monitoring Commands

```bash
# Check if build is alive
ssh root@IP "ps aux | grep ninja | grep -v grep"

# Tail the build log
ssh root@IP "tail -5 /root/build.log"

# Check progress (X/Y targets)
ssh root@IP "tail -3 /root/build.log"

# Check for failures
ssh root@IP "grep 'FAILED' /root/build.log"
```

## Version-Specific Notes

### Chromium 142 (fingerprint-chromium 142.0.7444.175)
- Re-check Clang/Rust/Node/esbuild versions from the unpacked source tree before building
- `enable_rust=false` does NOT work — Rust is required for core components

### Upstream Binary-Only Tags
- Upstream may publish a newer fp-chromium release before the matching source tree is available in the repo.
- If a tag is missing `downloads.ini` or `utils/downloads.py`, treat it as binary-only and keep the build pin on the latest source-available tag.

### When Upgrading to New fingerprint-chromium Version
1. Update the git tag in clone command
2. Check new Clang/Rust/Node/esbuild versions (they change each release)
3. Verify stealth-extra edits still apply (anchor strings may change)
4. Verify feature edits still apply (ABP source may change)

## Improving This Workflow

After each build, update this document with:
- Any new issues encountered and their solutions
- Updated version numbers for toolchains
- Timing improvements
- Any steps that could be automated better

The goal is that each successive build is smoother than the last.
