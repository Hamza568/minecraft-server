# ── Stage 1: download assets ──────────────────────────────────────────────────
# Uses a plain Alpine image to fetch the Minecraft server JAR and Filebrowser
# binary so the runtime image stays minimal.
FROM alpine:3.21 AS downloader

RUN apk add --no-cache curl jq

# Resolve the latest stable Paper build dynamically via the PaperMC API.
# Step 1 – latest supported MC version; Step 2 – latest "default" (stable) build;
# Step 3 – download the JAR from the canonical URL.
RUN set -eux; \
    PAPER_API="https://api.papermc.io/v2/projects/paper"; \
    VERSION=$(curl -fsSL "$PAPER_API" | jq -r '.versions[-1]'); \
    echo ">>> Paper version: $VERSION"; \
    BUILD=$(curl -fsSL "$PAPER_API/versions/$VERSION/builds" \
        | jq -r '[.builds[] | select(.channel == "default")] | last | .build'); \
    echo ">>> Paper build: $BUILD"; \
    JAR="paper-${VERSION}-${BUILD}.jar"; \
    curl -fsSL -o /server.jar \
        "$PAPER_API/versions/$VERSION/builds/$BUILD/downloads/$JAR"; \
    echo ">>> Downloaded $JAR"

# Install Filebrowser from the official install script (resolves latest release)
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre-alpine

# bash is required by the entrypoint script
RUN apk add --no-cache bash

# Copy assets from the downloader stage — nothing else carries over
COPY --from=downloader /server.jar          /server.jar
COPY --from=downloader /usr/local/bin/filebrowser /usr/local/bin/filebrowser

# Entrypoint manages both services
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Runtime configuration ──────────────────────────────────────────────────────
# EULA        – must be set to "true" to start the server
# MAX_MEMORY  – JVM heap ceiling  (e.g. 2G, 4G)
# MIN_MEMORY  – JVM heap floor    (e.g. 512M, 1G)
# JVM_OPTS    – additional JVM flags (e.g. -XX:+UseG1GC)
ENV EULA=false \
    MAX_MEMORY=1G \
    MIN_MEMORY=512M \
    JVM_OPTS=""

# All server files, world data, and Filebrowser's database live here.
# Mount a persistent volume at /data on Railway (or any Docker host).
VOLUME ["/data"]
WORKDIR /data

# 25565 – Minecraft Java Edition
# 80    – Filebrowser web UI
EXPOSE 25565 80

ENTRYPOINT ["/entrypoint.sh"]
