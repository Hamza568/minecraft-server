#!/bin/bash
set -uo pipefail

# ─── EULA ─────────────────────────────────────────────────────────────────────
if [[ "${EULA,,}" != "true" ]]; then
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ERROR: Minecraft EULA has not been accepted.        ║"
    echo "║  Set the environment variable  EULA=true  to start.  ║"
    echo "║  https://www.minecraft.net/en-us/eula               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    exit 1
fi

mkdir -p /data
echo "eula=true" > /data/eula.txt
echo "[entrypoint] EULA accepted."

# ─── Filebrowser ──────────────────────────────────────────────────────────────
FB_DB="/data/.filebrowser.db"

# Auto-restart loop — keeps filebrowser alive if it crashes
(
    while true; do
        echo "[filebrowser] Starting on :80  (root: /data, db: ${FB_DB})"
        filebrowser \
            --database "${FB_DB}" \
            --address  0.0.0.0 \
            --port     80 \
            --root     /data || true
        echo "[filebrowser] Process ended — restarting in 3 s..."
        sleep 3
    done
) &

# ─── Minecraft ────────────────────────────────────────────────────────────────
echo "[minecraft] Starting on :25565"
echo "[minecraft] Memory: Xms=${MIN_MEMORY}  Xmx=${MAX_MEMORY}"
[[ -n "${JVM_OPTS:-}" ]] && echo "[minecraft] Extra JVM opts: ${JVM_OPTS}"

# exec replaces the shell so Java becomes the main process (PID 1).
# Docker's SIGTERM on shutdown will go directly to the JVM, enabling
# the server to save the world gracefully before the container exits.
exec java \
    -Xmx"${MAX_MEMORY}" \
    -Xms"${MIN_MEMORY}" \
    ${JVM_OPTS:-} \
    -jar /server.jar nogui
