# ── Stage 1: download Paper JAR ───────────────────────────────────────────────
FROM alpine:3.21 AS downloader

RUN apk add --no-cache curl jq

# Resolve the latest stable Paper build dynamically via the PaperMC API.
# Iterates versions newest-first so a newly released version with no stable
# builds yet (channel != "default") is skipped automatically.
RUN set -eux; \
    PAPER_API="https://api.papermc.io/v2/projects/paper"; \
    VERSION=""; BUILD=""; \
    for V in $(curl -fsSL "$PAPER_API" | jq -r '.versions | reverse | .[]'); do \
        B=$(curl -fsSL "$PAPER_API/versions/$V/builds" \
            | jq -r '[.builds[] | select(.channel == "default")] | last | .build // empty'); \
        if [ -n "$B" ] && [ "$B" != "null" ]; then \
            VERSION="$V"; BUILD="$B"; break; \
        fi; \
    done; \
    [ -n "$BUILD" ] || { echo "ERROR: no stable Paper build found"; exit 1; }; \
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
