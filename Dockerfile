FROM ubuntu:22.04 AS downloader

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG ABP_VERSION=0.1.9
RUN wget -q "https://github.com/theredsix/agent-browser-protocol/releases/download/v${ABP_VERSION}/abp-${ABP_VERSION}-linux-x64.tar.gz" \
    -O /tmp/abp.tar.gz \
    && mkdir -p /opt/abp \
    && tar -xzf /tmp/abp.tar.gz -C /opt/abp \
    && rm /tmp/abp.tar.gz \
    && chmod +x /opt/abp/abp-chrome/abp

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install only the shared libraries Chromium needs at runtime.
# Even in --headless=new mode, the dynamic linker requires X11/GTK stubs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libc6 libstdc++6 zlib1g libexpat1 \
    libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
    libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 \
    libxrender1 libxtst6 libxkbcommon0 libxshmfence1 \
    libdrm2 libgbm1 libegl1 libgl1 \
    libgtk-3-0 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
    libpango-1.0-0 libpangocairo-1.0-0 libcairo2 libglib2.0-0 \
    libnss3 libnspr4 \
    libfontconfig1 libfreetype6 fonts-liberation \
    libasound2 libdbus-1-3 libcups2 libxinerama1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# Copy ABP binary and resources from downloader stage
COPY --from=downloader /opt/abp /opt/abp

# Create working directories
RUN mkdir -p /tmp/abp-data /tmp/abp-sessions

COPY wrapper.sh /wrapper.sh
RUN chmod +x /wrapper.sh

EXPOSE 15678
CMD ["/wrapper.sh"]
