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

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install minimal shared libraries Chromium needs at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
    libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 \
    libxrender1 libxtst6 libxkbcommon0 libxshmfence1 \
    libdrm2 libgbm1 libegl1 libgl1 \
    libgtk-3-0 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
    libpango-1.0-0 libpangocairo-1.0-0 libcairo2 \
    libnss3 libnspr4 \
    libfontconfig1 libfreetype6 fonts-liberation \
    libasound2 libdbus-1-3 libcups2 \
    socat \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/lintian \
    && rm -rf /usr/share/locale /usr/share/i18n \
    && rm -rf /var/log/* /tmp/*

COPY --from=downloader /opt/abp /opt/abp
COPY --from=downloader /usr/local/bin/gost /usr/local/bin/gost

RUN mkdir -p /tmp/abp-data /tmp/abp-sessions

COPY wrapper.sh /wrapper.sh
RUN chmod +x /wrapper.sh

EXPOSE 15678
EXPOSE 1080
CMD ["/wrapper.sh"]
