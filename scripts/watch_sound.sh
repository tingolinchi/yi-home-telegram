#!/bin/sh

# =============================================================
# watch_sound.sh — Sound detection for Yi Home 1080p
# Firmware: yi-hack-allwinner v5
# Reads PCM 16-bit little-endian from /tmp/audio_fifo,
# calculates average volume and alerts via Telegram if it exceeds
# the configured threshold. Sends snapshot + 15s audio.
# Audio: PCM 16-bit LE, mono, 8000Hz
# =============================================================

# PATH completo
export PATH=/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base

# --- CONFIGURACIÓN ---
CONFIG_FILE="/tmp/sd/yi-hack/script/config.env"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "ERROR: Cannot find $CONFIG_FILE" >&2
    exit 1
fi

AUDIO_FIFO="/tmp/audio_fifo"
AUDIO_FIFO_REQ="/tmp/audio_fifo.requested"
LOG_FILE="/tmp/watch_sound.log"
SNAPSHOT_PATH="/tmp/sound_snapshot.jpg"
AUDIO_PATH="/tmp/sound_alert.ogg"

# Threshold de volumen (0-32767). Adjust according to environment:
# Quiet environment: 300-500
# Environment with background noise: 800-1500
THRESHOLD=500

# Seconds between alerts (cooldown) para no saturar Telegram
COOLDOWN=30

# Confirmed audio parameters: PCM 16-bit LE, mono, 8000Hz
AUDIO_RATE=8000
# count=235 produces ~15 seconds at 8000Hz mono 16-bit
AUDIO_COUNT=235
AUDIO_BS=2048

# Detection parameters (small blocks for fast response)
BLOCK_SIZE=2048
BLOCK_COUNT=4

# --- FUNCIONES ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

capture_audio() {
    # Capture 15 seconds of audio and convert to OGG/Opus
    log "Capturing 15s audio..."
    dd if="$AUDIO_FIFO" bs=$AUDIO_BS count=$AUDIO_COUNT 2>/dev/null | \
        ffmpeg -y \
            -f s16le -ar $AUDIO_RATE -ac 1 \
            -i pipe:0 \
            -c:a libopus -b:a 32k \
            "$AUDIO_PATH" > /dev/null 2>&1

    if [ -f "$AUDIO_PATH" ] && [ -s "$AUDIO_PATH" ]; then
        log "Audio captured: $(ls -la $AUDIO_PATH | awk '{print $5}') bytes"
        return 0
    else
        log "Error: could not capture audio"
        return 1
    fi
}

send_alert() {
    VOLUME="$1"
    TIMESTAMP=$(date '+%d/%m/%Y %H:%M:%S')

    # 1. Send immediate alert message
    curl -k -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=🔊 Sound detected (volumen: $VOLUME) - $TIMESTAMP. Capturing audio..." \
        > /dev/null 2>&1

    # 2. Capture snapshot
    imggrabber > "$SNAPSHOT_PATH" 2>/dev/null
    if [ -f "$SNAPSHOT_PATH" ] && [ -s "$SNAPSHOT_PATH" ]; then
        curl -k -s \
            -F "chat_id=$CHAT_ID" \
            -F "photo=@$SNAPSHOT_PATH" \
            -F "caption=📷 Image at the moment of sound - $TIMESTAMP" \
            "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" > /dev/null 2>&1
        rm -f "$SNAPSHOT_PATH"
        log "Snapshot sent"
    else
        log "Could not capture snapshot"
    fi

    # 3. Capture and send 15-second audio
    if capture_audio; then
        curl -k -s \
            -F "chat_id=$CHAT_ID" \
            -F "voice=@$AUDIO_PATH" \
            -F "caption=🎙️ Audio 15s from detection - $TIMESTAMP" \
            "https://api.telegram.org/bot$BOT_TOKEN/sendVoice" > /dev/null 2>&1
        rm -f "$AUDIO_PATH"
        log "Audio sent successfully"
    else
        curl -k -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            --data-urlencode "chat_id=$CHAT_ID" \
            --data-urlencode "text=❌ Could not capture audio" \
            > /dev/null 2>&1
    fi

    log "Full alert sent - volume: $VOLUME"
}

calculate_volume_hex() {
    dd if="$AUDIO_FIFO" bs=$BLOCK_SIZE count=$BLOCK_COUNT 2>/dev/null | \
    hexdump -v -e '1/2 "%d\n"' 2>/dev/null | \
    awk '
    BEGIN { sum = 0; count = 0 }
    {
        val = $1
        if (val > 32767) val = val - 65536
        if (val < 0) val = -val
        sum += val
        count++
    }
    END {
        if (count > 0) print int(sum / count)
        else print 0
    }
    '
}

# --- INICIO ---

log "=== watch_sound.sh started ==="
log "Threshold: $THRESHOLD | Cooldown: ${COOLDOWN}s | Audio: ${AUDIO_RATE}Hz 15s"

# Activate audio fifo if not active
touch "$AUDIO_FIFO_REQ"

# Wait for fifo to have data
sleep 2

# Verify fifo exists
if [ ! -p "$AUDIO_FIFO" ]; then
    log "ERROR: $AUDIO_FIFO does not exist or is not a pipe"
    exit 1
fi

log "Audio fifo available, starting monitoring..."

LAST_ALERT=0

while true; do
    # Calculate current block volume
    VOLUME=$(calculate_volume_hex)

    # Verify we got a valid number
    if echo "$VOLUME" | grep -qE '^[0-9]+$'; then

        if [ "$VOLUME" -gt "$THRESHOLD" ]; then

            # Check cooldown
            NOW=$(date '+%s')
            ELAPSED=$((NOW - LAST_ALERT))

            if [ "$ELAPSED" -gt "$COOLDOWN" ]; then
                log "Sound detected - volumen: $VOLUME (threshold: $THRESHOLD)"
                send_alert "$VOLUME"
                LAST_ALERT=$(date '+%s')
            else
                log "Sound in cooldown (${ELAPSED}s/${COOLDOWN}s) - volumen: $VOLUME"
            fi
        fi
    fi

    sleep 1
done
