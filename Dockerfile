# ── Stage 1: download Paper JAR ───────────────────────────────────────────────
FROM alpine:3.21 AS downloader

RUN apk add --no-cache curl jq

# Resolve the latest stable Paper build via the PaperMC API in 2 calls:
#   1. Get the latest version group (e.g. "1.21")
#   2. Get all builds for that group, filter channel == "STABLE", take newest
# The version_group endpoint covers all 1.21.x sub-versions at once, so we
# never need to loop over individual versions.
RUN set -eux; \
    PAPER_API="https://api.papermc.io/v2/projects/paper"; \
    GROUP=$(curl -fsSL "$PAPER_API" | jq -r '.version_groups[-1]'); \
    echo ">>> Version group: $GROUP"; \
    STABLE=$(curl -fsSL "$PAPER_API/version_group/$GROUP/builds" \
        | jq -r '[.builds[] | select(.channel == "STABLE")] | last | "\(.version) \(.build)"'); \
    VERSION=$(echo "$STABLE" | cut -d' ' -f1); \
    BUILD=$(echo "$STABLE" | cut -d' ' -f2); \
    [ -n "$BUILD" ] && [ "$BUILD" != "null" ] || { echo "ERROR: no STABLE Paper build found"; exit 1; }; \
    echo ">>> Paper $VERSION build $BUILD"; \
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
    AUTO_START=true
# PANEL_PASSWORD is intentionally not set here — provide it via Railway's
# environment variable panel so it never bakes into the image.

WORKDIR /data

# 25565 – Minecraft Java Edition (TCP)
# 80    – Web panel (HTTP)
EXPOSE 25565 80

ENTRYPOINT ["node", "/panel/server.js"]
