# Context Dump: ABP on KraftCloud — April 6-7, 2026

## What We Were Doing

Deploying a stealth-patched Chromium browser (ABP protocol) on KraftCloud/Unikraft.
The browser was rebuilt from scratch on fingerprint-chromium 142.0.7444.175 base,
with ABP protocol overlaid for browser-as-a-service REST API.

## Where We Got To

### Phase 1: Build Size (SOLVED)

**Problem**: The original build was 1.8 GB unpacked (612 MB compressed), exceeding KraftCloud's
4 GiB memory limit for initramfs unpacking.

**Root cause found**: fingerprint-chromium's `flags.gn` doesn't set `is_component_build`,
`is_debug`, or `symbol_level`. Our build script only had these in a fallback branch that never ran.
Result: a debug component build with 529 .so files totaling 1.5 GB.

**Fix applied** (commit `af6dfc5`): Release build flags now always appended to `args.gn`:
```
is_debug = false
is_component_build = false  
symbol_level = 0
is_official_build = true
```

**Result**: Monolithic release build produces a single 282 MB `abp` binary.
Rootfs: 329 MB unpacked, 205 MB compressed. Boots on KraftCloud in ~1.3 seconds.

### Phase 2: Runtime Libraries (SOLVED)

**Problem**: "socat: not found" and "/opt/abp/abp-chrome/abp: not found" at runtime.

**Root cause**: The Dockerfile's `ldd` parsing wasn't copying shared libraries because
the monolithic binary has fewer dynamic deps and the dynamic linker `/lib64/ld-linux-x86-64.so.2`
wasn't being copied.

**Fix applied**: 
- Added explicit dynamic linker copy as fallback
- Added missing runtime libs to Dockerfile (libcairo2, libpango, libx11, libdbus, etc.)
- Added debug `ldd` output to build logs

### Phase 3: Chrome Startup (PARTIALLY SOLVED)

**Problem**: Chrome starts but ABP HTTP server (port 15679) never binds.

**What works**:
- Chrome process starts and initializes (profile setup, extensions, component registration all complete)
- dbus errors suppressed via `DBUS_SESSION_BUS_ADDRESS=disabled:`
- socat proxy runs correctly
- Wrapper flags: `--disable-gpu`, `--disable-breakpad`, `--disable-background-networking`, etc.

**What doesn't work**: The ABP port never opens. Chrome runs but the ABP HTTP server never starts.

**Root cause found**: The ABP protocol code was never compiled into the Chrome binary! The build
script copied ABP source to `chrome/browser/abp/` but never wired it into Chrome's build graph.
`chrome/BUILD.gn` needed a dep on `//chrome/browser/abp`.

**Fix applied** (commit `630ee79` and friends): Build script now injects ABP dep into `chrome/BUILD.gn`
using sed after copying the ABP source.

### Phase 4: ABP Chromium 142 Compatibility (IN PROGRESS — where we stopped)

**Problem**: ABP protocol source was written for an older Chromium version. Three categories
of compile errors against Chromium 142:

#### Error 1: `sql::Database::Tag("ABP")` — consteval whitelist

Chromium 142 made `sql::Database::Tag` consteval with a hardcoded whitelist of known tag strings.
"ABP" isn't in the whitelist.

**Current fix** (commit `22c9534`): Replace `Tag("ABP")` with `Tag("WebDatabase")` in the two
ABP database files. This works — the preflight passes.

**IMPORTANT**: Do NOT patch `sql/database.h`. Multiple attempts to add "ABP" to the whitelist
broke every file in the build that uses SQL. The parameter name in the consteval constructor
varies and injecting code there is fragile.

#### Error 2: `ui::mojom::CursorType` incomplete type

`abp_controller.h` includes `cursor_type.mojom-forward.h` (forward declaration only) but uses
`CursorType::kPointer` which needs the full enum.

**Fix** (working): `sed -i 's|cursor_type.mojom-forward.h|cursor_type.mojom-shared.h|'`

#### Error 3: Missing `kAbpHumanIcon`, `kAbpCdpIcon`, `kAbpRobotIcon`

These vector icons are referenced in `abp_input_mode_icon_view.cc` but not defined anywhere.
The file includes `chrome/app/vector_icons/vector_icons.h` but ABP's icons aren't registered there.

**Current fix** (commit `c3ceaec`): Define stub VectorIcon constants after the includes:
```cpp
const gfx::PathElement kAbpStubPath[] = {{gfx::CommandType::CLOSE}};
const gfx::VectorIconRep kAbpStubRep[] = {{kAbpStubPath}};
constexpr gfx::VectorIcon kAbpHumanIcon(kAbpStubRep, 1u, "abp_human");
```
Note: `VectorIcon` API changed in Chromium 142 — default constructor is private,
`VectorIconRep` takes spans not explicit counts. The exact constructor signature
may need adjustment.

#### Error 4: Missing `content/public/browser/popup_interceptor.h`

This header was removed in Chromium 142. `AbpPopupInterceptor` inherits from
`content::PopupInterceptor`.

**Current fix** (commit `c3ceaec`): Create a minimal stub header.

#### Likely more errors

Only 3-4 ABP files have been tested. The full ABP source has ~40 .cc files.
More compat issues likely exist.

## What It Would Take To Finish

### Immediate (get ABP compiling)

1. **Start a Hetzner build** with the current code (`7fb6c7f`).
2. The ABP preflight step will compile only ABP files first (~2 min), catching errors fast.
3. Fix each error iteratively — the watchdog + sonnet repair agent can handle this.
4. Expect 2-5 more compat fixes based on Chromium 142 API changes.
5. Once preflight passes, the full build takes ~3.5 hours.

### After build succeeds

6. **Update `ABP_STEALTH_VERSION`** in Dockerfile with the new release tag.
   The watchdog does this automatically on success.
7. **Deploy to KraftCloud** — CI handles this on push to main.
8. **Test Chrome startup** — verify ABP port binds and responds to `/json/version`.
9. If port still doesn't bind, investigate `--single-process` vs multi-process.
   KraftCloud's `base-compat` runtime may or may not support `fork()`.

### Wrapper.sh flags to experiment with

Current flags that affect startup:
```
--headless=new --no-sandbox --disable-dev-shm-usage
--disable-gpu --disable-breakpad --disable-background-networking
--disable-component-update --disable-default-apps --disable-extensions
```

May need:
- `--single-process --no-zygote` if fork() doesn't work (but ABP port didn't bind in this mode either)
- `--remote-debugging-port=15679` as alternative to `--abp-port` if ABP's HTTP server has issues

### Known infrastructure issues

- **Hetzner `ash` location**: Out of CPX51 capacity. Use `hil` (Hillsboro).
- **Zombie VMs**: The watchdog's cleanup sometimes fails to destroy servers.
  Always check `hetzner_api GET /servers` before/after builds.
- **KraftCloud instance-exists error**: `kraft cloud deploy` fails if an instance
  with the same name already exists. Delete it first.
- **KraftCloud storage quota**: 1 GiB limit. Delete old images before pushing new ones.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/build-on-fp-chromium.sh` | Main build script, runs on Hetzner VM |
| `scripts/apply-abp-compat-edits.sh` | Chromium 142 compat patches for ABP source |
| `scripts/watchdog-hetzner.sh` | Local orchestrator with auto-repair, deploy, smoke test |
| `scripts/watchdog-remote.sh` | Remote supervisor on Hetzner VM |
| `Dockerfile` | Rootfs packaging, lib-copy, size audit |
| `wrapper.sh` | Chrome launch flags, proxy setup, dbus suppression |
| `.github/workflows/deploy.yml` | CI deploy to KraftCloud |

## Key Improvements Made to Watchdog

1. **Repair guardrails**: Max 10 repairs, abort if same failure repeats 5 times
2. **ABP preflight compile**: Catches ABP errors in ~2 min instead of 4 hours
3. **Better repair prompts**: Extracts error lines, includes file whitelist, build context
4. **Post-build automation**: Auto-updates Dockerfile, triggers deploy, runs smoke test
5. **Progress tracking**: Shows ninja [X/Y] in status output
6. **Configurable repair model**: Uses sonnet by default (`WATCHDOG_CLAUDE_REPAIR_MODEL`)
7. **Scale-to-zero cooldown**: 60s (was 5s, too short for Chrome startup)

## Build Stats (last successful build without ABP)

- Release tag: `stealth-fp-20260406-121255`
- Rootfs: 329 MB unpacked, 205 MB compressed
- Boot time: ~1.3 seconds on KraftCloud
- Chrome initializes fully (dbus errors are cosmetic)
- ABP port doesn't bind (because ABP wasn't compiled in that build)

## Cost

- Each Hetzner build: CPX51 (16 cores, 32GB), ~€0.085/hr, ~€0.35-0.50 per build
- Multiple zombie VMs ran overnight — check and kill any remaining
- KraftCloud: free tier with 1 GiB image storage limit
