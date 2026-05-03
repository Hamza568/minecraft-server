# ── Stage 1: download Paper JAR ───────────────────────────────────────────────
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

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre-alpine

# nodejs/npm are available in Alpine's packages (Node 22 on Alpine 3.21)
RUN apk add --no-cache nodejs npm

COPY --from=downloader /server.jar /server.jar

# Install panel dependencies in a separate layer so Docker can cache it
# independently from source changes.
COPY panel/package.json /panel/package.json
RUN cd /panel && npm install --omit=dev && npm cache clean --force

# Copy panel source (only invalidates the layer above when source changes)
COPY panel/ /panel/

# ── Runtime configuration ──────────────────────────────────────────────────────
# EULA           – must be "true" for the server to start
# MAX_MEMORY     – JVM heap ceiling   (e.g. 2G)
# MIN_MEMORY     – JVM heap floor     (e.g. 512M)
# JVM_OPTS       – extra JVM flags    (e.g. -XX:+UseG1GC)
# PANEL_PASSWORD – web UI password    (default: admin — change this!)
# AUTO_START     – start MC on boot when EULA=true (default: true)
ENV EULA=false \
    MAX_MEMORY=1G \
    MIN_MEMORY=512M \
    JVM_OPTS="" \
    PANEL_PASSWORD=admin \
    AUTO_START=true

# All world saves, configs, plugins, and panel state live here.
# Mount a Railway volume at /data so nothing is lost on redeploy.
VOLUME ["/data"]
WORKDIR /data

# 25565 – Minecraft Java Edition (TCP)
# 80    – Web panel (HTTP)
EXPOSE 25565 80

ENTRYPOINT ["node", "/panel/server.js"]
