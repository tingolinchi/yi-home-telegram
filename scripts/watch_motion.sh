#!/bin/sh

# =============================================================
# watch_motion.sh — Motion detection watcher
# Firmware: yi-hack-allwinner v5
#
# Monitors /tmp/motion.jpg and when it detects a new image
# sends it as a Telegram alert (photo + message).
# Respects the silence flag /tmp/tg_silent.
# =============================================================

export PATH=/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base

# --- CONFIGURACIÓN ---
CONFIG_FILE="/tmp/sd/yi-hack/script/config.env"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "ERROR: Cannot find $CONFIG_FILE" >&2
    exit 1
fi

IMAGE="/tmp/motion.jpg"
MOTION_DIR="/tmp/sd/yi-hack/motion"
SILENT_FILE="/tmp/tg_silent"
LOG_FILE="/tmp/watch_motion.log"

# --- FUNCIONES ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_alert() {
    # Check if alerts are silenced
    if [ -f "$SILENT_FILE" ]; then
        log "Alert silenced - motion detected but notification skipped"
        return
    fi

    PHOTO="$1"

    curl -k -s \
        -F "chat_id=$CHAT_ID" \
        -F "photo=@$PHOTO" \
        -F "caption=🚨 Motion detected! - $(date '+%d/%m/%Y %H:%M:%S')" \
        "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" > /dev/null 2>&1

    log "Alert sent to Telegram"
}

# --- INICIO ---

log "=== Motion watcher started ==="

mkdir -p "$MOTION_DIR"

LAST_MOD=""

# --- BUCLE PRINCIPAL ---
while true; do
    if [ -f "$IMAGE" ]; then
        # Get modification timestamp
        MOD=$(ls -l "$IMAGE" | awk '{print $6$7$8}' 2>/dev/null)

        if [ "$MOD" != "$LAST_MOD" ]; then
            log "New motion image detected"

            # Copy image to motion directory
            cp "$IMAGE" "$MOTION_DIR/motion.jpg"

            # Send alert (respects silence flag)
            send_alert "$MOTION_DIR/motion.jpg"

            # Clean up image from motion directory
            rm -f "$MOTION_DIR/motion.jpg"

            LAST_MOD="$MOD"
        fi
    else
        # Image does not exist, reset timestamp
        LAST_MOD=""
    fi

    sleep 1
done
