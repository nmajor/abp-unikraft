# Deploy to KraftCloud

Build the Docker image and deploy ABP to KraftCloud (Unikraft).

## Quick Reference

```
Trigger: User says "deploy", "build the image", or "push to kraftcloud"
Time: ~2-3 minutes
CI: GitHub Actions workflow (`.github/workflows/deploy.yml`)
Metro: fra (Frankfurt)
Instance: abp-unikraft
FQDN: check `kraft cloud instance get abp-unikraft --metro fra`
```

## How It Works

The GitHub Actions workflow:
1. Checks out the repo
2. Installs the `kraft` CLI (v0.12.7 deb package)
3. Authenticates with KraftCloud using `UKC_TOKEN` secret
4. Runs `kraft cloud deploy` which builds the Dockerfile and deploys

The Dockerfile downloads the pre-built Chromium binary from a GitHub Release
(specified by `ABP_STEALTH_VERSION` in Dockerfile), bundles it with gost proxy
and runtime deps, and deploys as a unikernel.

## Standard Deploy (via CI)

The workflow runs automatically on every push to `main`. To trigger manually:

```bash
gh workflow run deploy.yml --repo nmajor/abp-unikraft --ref main
```

Monitor the run:

```bash
# Check status
gh run list --repo nmajor/abp-unikraft --limit 1

# Watch a specific run
gh run view <RUN_ID> --repo nmajor/abp-unikraft

# View failure logs
gh run view <RUN_ID> --repo nmajor/abp-unikraft --log-failed
```

## Deploying a New Chromium Release

After building a new Chromium binary on Hetzner (see `hetzner-build.md`):

1. Update `ABP_STEALTH_VERSION` in `Dockerfile` to the new release tag
2. Commit and push to `main` — CI will deploy automatically
3. Or trigger manually: `gh workflow run deploy.yml --repo nmajor/abp-unikraft --ref main`

## Verify Deployment

```bash
# Check instance status
env -u UKC_TOKEN kraft cloud instance get abp-unikraft --metro fra

# Hit the health endpoint
curl -s "https://<FQDN>/api/v1/browser/status"
# Expected: {"data":{"components":{"browser_window":true,"devtools":true,"http_server":true},...},"success":true}
```

## Known Issues

### 1. Memory Quota Exceeded

```
Quota exceeded. Increasing the amount of allocated instance memory by 4096
would exceed the current limit of 4096. Current value: 4096
```

An existing instance is using the full quota. Remove it first:

```bash
env -u UKC_TOKEN kraft cloud instance remove abp-unikraft --metro fra
```

Then re-trigger the workflow.

### 2. `kraft` CLI Auth Fails Locally

The `UKC_TOKEN` env var (set in `~/.zshrc`) can interfere with kraft's own
credential handling. Always unset it when using kraft directly:

```bash
env -u UKC_TOKEN kraft cloud instance list --metro fra
```

The deploy script (`scripts/deploy.sh`) handles this, but Docker builds don't
work in the dev environment (no bridge network / VFS storage driver). Use the
GitHub Actions workflow instead.

### 3. Metro Name

The workflow uses metro `fra` (not `fra0`). The old `fra0` API host returns 401.

### 4. Scale-to-Zero

The instance uses scale-to-zero with a 5s cooldown. It will be in `standby`
state when idle. First request after idle takes ~3s (boot time) to respond.

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/deploy.yml` | CI workflow (build + deploy) |
| `Dockerfile` | Image definition, references `ABP_STEALTH_VERSION` |
| `scripts/deploy.sh` | Local deploy script (needs Docker, won't work in dev env) |
| `wrapper.sh` | Entrypoint: launches gost, socat, and Chromium |

## Secrets

| Secret | Location | Purpose |
|--------|----------|---------|
| `UKC_TOKEN` | GitHub repo secret + `~/.zshrc` | Base64-encoded `user:token` for KraftCloud |
