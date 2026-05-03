# ── Stage 1: download Paper JAR ───────────────────────────────────────────────
FROM alpine:3.21 AS downloader

RUN apk add --no-cache curl jq

# Fill v3 API returns versions as a grouped object: {"26.1":["26.1.2",...],...}
# Flatten to a list newest-first, check the first 5 for a STABLE build.
# Normally resolves in 2 HTTP calls: project info + first version's builds.
RUN set -eux; \
    FILL="https://fill.papermc.io/v3/projects/paper"; \
    UA="User-Agent: mc-panel/1.0 (dockerfile)"; \
    URL=""; VERSION=""; \
    for V in $(curl -fsSL -H "$UA" "$FILL" \
        | jq -r '[.versions | to_entries[] | .value[]] | .[0:5] | .[]'); do \
        URL=$(curl -fsSL -H "$UA" "$FILL/versions/$V/builds" \
            | jq -r 'map(select(.channel == "STABLE")) | .[0] | .downloads."server:default".url // empty'); \
        if [ -n "$URL" ] && [ "$URL" != "null" ]; then VERSION="$V"; break; fi; \
    done; \
    [ -n "$URL" ] || { echo "ERROR: no STABLE Paper build found"; exit 1; }; \
    echo ">>> Downloading Paper $VERSION"; \
    curl -fsSL -H "$UA" -o /server.jar "$URL"; \
    echo ">>> Done"

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
# Minecraft 26.1+ requires Java 25. eclipse-temurin:25-jre-alpine is the
# official lightweight JRE image for Java 25.
FROM eclipse-temurin:25-jre-alpine

# nodejs/npm from Alpine's packages
RUN apk add --no-cache nodejs npm

COPY --from=downloader /server.jar /server.jar

# Install panel dependencies in a separate layer for Docker cache efficiency
COPY panel/package.json /panel/package.json
RUN cd /panel && npm install --omit=dev && npm cache clean --force

# Copy panel source
COPY panel/ /panel/

# ── Runtime configuration ──────────────────────────────────────────────────────
# EULA           – must be "true" for the server to start
# MAX_MEMORY     – JVM heap ceiling   (e.g. 2G)
# MIN_MEMORY     – JVM heap floor     (e.g. 512M)
# JVM_OPTS       – extra JVM flags
# AUTO_START     – start MC on boot when EULA=true (default: true)
# PANEL_PASSWORD – set via Railway's Variables tab (never bake into the image)
ENV EULA=false \
    MAX_MEMORY=1G \
    MIN_MEMORY=512M \
    JVM_OPTS="" \
    AUTO_START=true

WORKDIR /

# 25565 – Minecraft Java Edition TCP (configure TCP proxy in Railway networking)
# HTTP panel runs on Railway's injected PORT (always 8080)
EXPOSE 25565

ENTRYPOINT ["node", "/panel/server.js"]
