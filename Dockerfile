FROM debian:bookworm-slim AS downloader

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

# Download gost — lightweight proxy forwarder for authenticated proxy support.
# Chrome cannot handle proxy credentials in --proxy-server; gost bridges the gap.
ARG GOST_VERSION=3.2.6
RUN wget -q "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz" \
    -O /tmp/gost.tar.gz \
    && tar -xzf /tmp/gost.tar.gz -C /usr/local/bin gost \
    && chmod +x /usr/local/bin/gost \
    && rm /tmp/gost.tar.gz

# Download our stealth-patched ABP binary from GitHub Releases.
# Built on fingerprint-chromium base with ABP protocol + stealth-extra patches.
# To build a new version: scripts/build-on-fp-chromium.sh on a Hetzner CCX33.
ARG ABP_STEALTH_VERSION=stealth-fp-20260405-154019
RUN wget -q "https://github.com/nmajor/abp-unikraft/releases/download/${ABP_STEALTH_VERSION}/abp-stealth-linux-x64.tar.gz" \
    -O /tmp/abp.tar.gz \
    && mkdir -p /opt/abp \
    && tar -xzf /tmp/abp.tar.gz -C /opt/abp \
    && rm /tmp/abp.tar.gz \
    && chmod +x /opt/abp/abp-chrome/abp \
    # Strip large ELF executables from the release bundle. The Hetzner-built
    # artifacts are functionally correct but not fully stripped, and leaving
    # them untouched bloats the KraftCloud rootfs enough to fail unikernel boot.
    && find /opt/abp/abp-chrome -maxdepth 1 -type f -perm -111 -exec strip --strip-unneeded {} + 2>/dev/null || true \
    # Drop large non-startup payloads that are not part of the browser's loader
    # dependency graph in our runtime profile. These are safe wins for the
    # unikernel rootfs budget.
    && rm -f /opt/abp/abp-chrome/chromedriver \
    && rm -f /opt/abp/abp-chrome/chrome_crashpad_handler \
    && rm -f /opt/abp/abp-chrome/libVkLayer_khronos_validation.so \
    && rm -f /opt/abp/abp-chrome/libdevice_vr.so \
    && rm -f /opt/abp/abp-chrome/libcomponents_feed_feature_list.so \
    && rm -f /opt/abp/abp-chrome/libthird_party_icu_icui18n_hidden_visibility.so \
    && rm -f /opt/abp/abp-chrome/libicuuc_hidden_visibility.so \
    # Headless ABP does not use these subsystems — safe to remove in a
    # component build without breaking the browser startup path.
    # Tier 1: Hardware/device subsystems (no physical devices in unikernel)
    && rm -f /opt/abp/abp-chrome/libcomponents_mirroring_service_mirroring_service.so \
    && rm -f /opt/abp/abp-chrome/libdevice_fido.so \
    && rm -f /opt/abp/abp-chrome/libdevice_gamepad.so \
    && rm -f /opt/abp/abp-chrome/libgamepad_mojom.so \
    && rm -f /opt/abp/abp-chrome/libgamepad_mojom_blink.so \
    && rm -f /opt/abp/abp-chrome/libvr_public_cpp.so \
    && rm -f /opt/abp/abp-chrome/libdevice_vr_isolated_xr_service_mojo_bindings.so \
    # Tier 2: ML/AI services not used by ABP
    && rm -f /opt/abp/abp-chrome/libservices_on_device_model_ml_ml_no_internal.so \
    && rm -f /opt/abp/abp-chrome/libservices_webnn_webnn_service.so \
    && rm -f /opt/abp/abp-chrome/libcomponents_language_detection_core.so \
    # Tier 3: GPU/WebGPU (headless swiftshader doesn't need dawn)
    && rm -f /opt/abp/abp-chrome/libdawn_native.so \
    # Tier 4: Services not relevant to headless browsing
    && rm -f /opt/abp/abp-chrome/libcomponents_drive.so \
    && rm -f /opt/abp/abp-chrome/libpolicy_component.so \
    && find /opt/abp/abp-chrome -name '*.TOC' -delete 2>/dev/null || true \
    # Remove optional/unnecessary components
    && rm -rf /opt/abp/abp-chrome/MEIPreload \
    && rm -rf /opt/abp/abp-chrome/WidevineCdm \
    && rm -rf /opt/abp/abp-chrome/PrivacySandboxAttestationsPreloaded \
    && rm -rf /opt/abp/abp-chrome/default_apps \
    && rm -rf /opt/abp/abp-chrome/resources \
    && rm -f /opt/abp/abp-chrome/chrome_management_service \
    && rm -f /opt/abp/abp-chrome/chrome_sandbox \
    # Keep only en-US locale
    && find /opt/abp/abp-chrome/locales -type f ! -name 'en-US.pak' -delete 2>/dev/null || true \
    # Strip shared libraries
    && find /opt/abp/abp-chrome -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true \
    && find /opt/abp/abp-chrome -name '*.so.*' -exec strip --strip-unneeded {} + 2>/dev/null || true

FROM debian:bookworm-slim AS runtime-packager

ENV DEBIAN_FRONTEND=noninteractive

# Install only the packages needed to assemble a minimal runtime rootfs. The
# final image is built from scratch so KraftCloud does not have to unpack an
# entire Debian filesystem into guest memory.
RUN apt-get update && apt-get install -y --no-install-recommends \
    busybox-static \
    ca-certificates \
    fontconfig-config \
    fonts-liberation \
    libasound2 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libatspi2.0-0 \
    libgbm1 \
    libnspr4 \
    libnss3 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    libxtst6 \
    socat \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

COPY --from=downloader /opt/abp /opt/abp
COPY --from=downloader /usr/local/bin/gost /usr/local/bin/gost
COPY wrapper.sh /wrapper.sh

RUN set -eux; \
    mkdir -p \
      /rootfs/opt \
      /rootfs/usr/local/bin \
      /rootfs/usr/bin \
      /rootfs/usr/share/fonts \
      /rootfs/bin \
      /rootfs/etc \
      /rootfs/lib64 \
      /rootfs/tmp/abp-data \
      /rootfs/tmp/abp-sessions \
      /rootfs/var/cache; \
    cp -a /opt/abp /rootfs/opt/; \
    install -Dm755 /usr/local/bin/gost /rootfs/usr/local/bin/gost; \
    install -Dm755 /usr/bin/socat /rootfs/usr/bin/socat; \
    install -Dm755 /bin/busybox /rootfs/bin/busybox; \
    ln -s busybox /rootfs/bin/sh; \
    ln -s busybox /rootfs/bin/sleep; \
    install -Dm755 /wrapper.sh /rootfs/wrapper.sh; \
    cp -a /etc/ssl /rootfs/etc/; \
    cp -a /etc/fonts /rootfs/etc/; \
    cp -a /etc/nsswitch.conf /rootfs/etc/; \
    cp -a /etc/hosts /rootfs/etc/; \
    cp -a /etc/resolv.conf /rootfs/etc/; \
    cp -a /usr/share/fontconfig /rootfs/usr/share/; \
    # Copy only Liberation font files (the only family we install), not the
    # entire truetype tree which may pull in fallback/default fonts.
    mkdir -p /rootfs/usr/share/fonts/truetype/liberation; \
    cp -a /usr/share/fonts/truetype/liberation/* /rootfs/usr/share/fonts/truetype/liberation/ 2>/dev/null || true; \
    # Keep only a curated set of timezones instead of the full zoneinfo tree
    # (~4 MB savings). The default is America/New_York; add zones as needed.
    mkdir -p /rootfs/usr/share/zoneinfo/America \
             /rootfs/usr/share/zoneinfo/Europe \
             /rootfs/usr/share/zoneinfo/Asia \
             /rootfs/usr/share/zoneinfo/Pacific \
             /rootfs/usr/share/zoneinfo/Etc; \
    for tz in \
      UTC \
      America/New_York America/Chicago America/Denver America/Los_Angeles \
      America/Sao_Paulo America/Toronto America/Mexico_City \
      Europe/London Europe/Paris Europe/Berlin Europe/Moscow \
      Asia/Tokyo Asia/Shanghai Asia/Kolkata Asia/Dubai Asia/Singapore \
      Pacific/Auckland Pacific/Honolulu \
      Etc/UTC Etc/GMT; do \
      src="/usr/share/zoneinfo/${tz}"; \
      if [ -f "$src" ]; then \
        install -Dm644 "$src" "/rootfs/usr/share/zoneinfo/${tz}"; \
      fi; \
    done; \
    # Copy the zone.tab and leap-seconds files that some libs expect
    for f in zone.tab zone1970.tab leap-seconds.list tzdata.zi; do \
      [ -f "/usr/share/zoneinfo/$f" ] && cp "/usr/share/zoneinfo/$f" /rootfs/usr/share/zoneinfo/ 2>/dev/null || true; \
    done; \
    if [ -d /var/cache/fontconfig ]; then cp -a /var/cache/fontconfig /rootfs/var/cache/; fi; \
    printf 'root:x:0:0:root:/root:/bin/sh\n' > /rootfs/etc/passwd; \
    printf 'root:x:0:\n' > /rootfs/etc/group; \
    deps="$(ldd /opt/abp/abp-chrome/abp /usr/bin/socat 2>/dev/null \
      | sed -n -e 's/.*=> \\(\\/[^ ]*\\).*/\\1/p' -e 's#^\\(/[^ ]*\\) .*#\\1#p' \
      | grep -v '^/opt/abp/' \
      | sort -u)"; \
    for lib in ${deps}; do \
      install -Dm755 "$(readlink -f "$lib")" "/rootfs${lib}"; \
    done

# --- Rootfs size audit (visible in build logs) ---
# This runs at build time and prints the unpacked rootfs budget so we can
# track size regressions without waiting for a KraftCloud boot failure.
RUN set -eux; \
    echo "=== ROOTFS SIZE AUDIT ==="; \
    echo "--- Total rootfs size ---"; \
    du -sh /rootfs; \
    echo "--- Top-level breakdown ---"; \
    du -sh /rootfs/*/ 2>/dev/null | sort -rh; \
    echo "--- Top 50 largest files in rootfs ---"; \
    find /rootfs -type f -exec du -k {} + | sort -rn | head -50; \
    echo "--- Top 20 largest files in abp-chrome ---"; \
    find /rootfs/opt/abp/abp-chrome -type f -exec du -k {} + 2>/dev/null | sort -rn | head -20; \
    echo "--- Shared lib count and size ---"; \
    find /rootfs -name '*.so*' -type f | wc -l; \
    du -shc /rootfs/lib/ /rootfs/lib64/ /rootfs/usr/lib/ 2>/dev/null || true; \
    echo "=== END ROOTFS SIZE AUDIT ==="

FROM scratch

COPY --from=runtime-packager /rootfs /

EXPOSE 15678
EXPOSE 1080
CMD ["/wrapper.sh"]
