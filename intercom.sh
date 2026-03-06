#!/bin/sh

# =============================================================
# intercom.sh — Intercomunicador bidireccional via Telegram
# Firmware: yi-hack-allwinner v5
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

WATCH_MOTION_SCRIPT="/tmp/sd/yi-hack/script/watch_motion.sh"
WATCH_SOUND_SCRIPT="/tmp/sd/yi-hack/script/watch_sound.sh"
LOG_FILE="/tmp/intercom.log"
OFFSET_FILE="/tmp/intercom_offset"
AUDIO_FIFO="/tmp/audio_fifo"
AUDIO_IN_FIFO="/tmp/audio_in_fifo"

VOICE_THRESHOLD=90
VOICE_COOLDOWN=15
INACTIVITY_TIMEOUT=300
BLOCK_SIZE=2048
BLOCK_COUNT=4

BUFFER_DIR="/tmp/intercom_buffer"
BUFFER_BLOCKS=30        # ~15s of previous audio
BUFFER_INDEX=0

# --- FUNCIONES ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_message() {
    curl -k -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$1" \
        > /dev/null 2>&1
}

send_voice() {
    curl -k -s \
        -F "chat_id=$CHAT_ID" \
        -F "voice=@$1" \
        -F "caption=$2" \
        "https://api.telegram.org/bot$BOT_TOKEN/sendVoice" > /dev/null 2>&1
}

play_audio() {
    OGG_FILE="$1"
    PCM_FILE="/tmp/intercom_play.pcm"

    ffmpeg -y -i "$OGG_FILE" \
        -f s16le -ar 16000 -ac 1 \
        "$PCM_FILE" > /dev/null 2>&1

    if [ -f "$PCM_FILE" ] && [ -s "$PCM_FILE" ]; then
        DURATION=$(ffmpeg -i "$OGG_FILE" 2>&1 | grep Duration | awk '{print $2}' | cut -d'.' -f1 | awk -F: '{print ($1*3600)+($2*60)+$3+1}')
        speaker on > /dev/null 2>&1
        sleep 1
        cat "$PCM_FILE" > "$AUDIO_IN_FIFO"
        sleep ${DURATION:-3}
        speaker off > /dev/null 2>&1
        rm -f "$PCM_FILE"
        log "Audio played on speaker (${DURATION}s)"
        return 0
    else
        log "Error: could not convert audio for playback"
        return 1
    fi
}

init_buffer() {
    mkdir -p "$BUFFER_DIR"
    rm -f "$BUFFER_DIR"/*.raw
    BUFFER_INDEX=0
}

record_buffer_block() {
    BFILE="$BUFFER_DIR/$(printf '%04d' $BUFFER_INDEX).raw"
    dd if="$AUDIO_FIFO" bs=$BLOCK_SIZE count=4 of="$BFILE" 2>/dev/null
    BUFFER_INDEX=$(( (BUFFER_INDEX + 1) % BUFFER_BLOCKS ))
}

capture_voice() {
    VOICE_FILE="/tmp/intercom_voice.ogg"
    COMBINED="/tmp/intercom_combined.raw"
    TAIL_FILE="/tmp/intercom_tail.raw"

    # 1. Copy current circular buffer (previous audio)
    rm -f "$COMBINED"
    I=$BUFFER_INDEX
    j=0
    while [ $j -lt $BUFFER_BLOCKS ]; do
        BFILE="$BUFFER_DIR/$(printf '%04d' $I).raw"
        if [ -f "$BFILE" ]; then
            cat "$BFILE" >> "$COMBINED"
        fi
        I=$(( (I + 1) % BUFFER_BLOCKS ))
        j=$(( j + 1 ))
    done

    # 2. Capture subsequent audio while continuing to record buffer
    #    in parallel while capturing the tail
    #    10 seconds = 10 * 8000 * 2 / 2048 = 78 blocks
    dd if="$AUDIO_FIFO" bs=$BLOCK_SIZE count=40 of="$TAIL_FILE" 2>/dev/null

    # 3. Concatenate previous + subsequent
    cat "$TAIL_FILE" >> "$COMBINED"
    rm -f "$TAIL_FILE"

    if [ -f "$COMBINED" ] && [ -s "$COMBINED" ]; then
        COMBINED_SIZE=$(ls -la "$COMBINED" | awk '{print $5}')
        COMBINED_SECS=$((COMBINED_SIZE / 16000))
        log "Combined buffer: ${COMBINED_SIZE} bytes (~${COMBINED_SECS}s)"
        ffmpeg -y -f s16le -ar 8000 -ac 1 -i "$COMBINED" \
            -c:a libopus -b:a 32k \
            "$VOICE_FILE" > /dev/null 2>&1
        rm -f "$COMBINED"
    fi

    if [ -f "$VOICE_FILE" ] && [ -s "$VOICE_FILE" ]; then
        send_voice "$VOICE_FILE" "🎙️ Voice from camera - $(date '+%H:%M:%S')"
        rm -f "$VOICE_FILE"
        log "Voice captured and sent"
        return 0
    else
        log "Error: could not capture voice"
        return 1
    fi
}

download_voice() {
    FILE_ID="$1"
    OGG_FILE="/tmp/intercom_recv.ogg"

    FILE_PATH=$(curl -k -s \
        "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$FILE_ID" | \
        grep -o '"file_path":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$FILE_PATH" ]; then
        log "Error: could not get voice file path"
        return 1
    fi

    curl -k -s \
        "https://api.telegram.org/file/bot$BOT_TOKEN/$FILE_PATH" \
        -o "$OGG_FILE" > /dev/null 2>&1

    if [ -f "$OGG_FILE" ] && [ -s "$OGG_FILE" ]; then
        log "Audio downloaded: $FILE_PATH"
        echo "$OGG_FILE"
        return 0
    else
        log "Error: could not download audio"
        return 1
    fi
}

stop_watchers() {
    WATCH_MOTION_PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    WATCH_SOUND_PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')

    if [ -n "$WATCH_MOTION_PID" ]; then
        echo "1" > /tmp/intercom_motion_was_active
        kill "$WATCH_MOTION_PID" 2>/dev/null
        sleep 1
        log "Motion watcher paused (PID $WATCH_MOTION_PID)"
    else
        echo "0" > /tmp/intercom_motion_was_active
    fi

    if [ -n "$WATCH_SOUND_PID" ]; then
        echo "1" > /tmp/intercom_sound_was_active
        kill "$WATCH_SOUND_PID" 2>/dev/null
        sleep 1
        log "Sound watcher paused (PID $WATCH_SOUND_PID)"
    else
        echo "0" > /tmp/intercom_sound_was_active
    fi
}

restore_watchers() {
    MOTION_WAS_ACTIVE=$(cat /tmp/intercom_motion_was_active 2>/dev/null)
    SOUND_WAS_ACTIVE=$(cat /tmp/intercom_sound_was_active 2>/dev/null)

    if [ "$MOTION_WAS_ACTIVE" = "1" ]; then
        sh "$WATCH_MOTION_SCRIPT" &
        sleep 1
        PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
        log "Motion watcher restored (PID $PID)"
        send_message "👀 Motion watcher restored"
    fi

    if [ "$SOUND_WAS_ACTIVE" = "1" ]; then
        sh "$WATCH_SOUND_SCRIPT" &
        sleep 1
        PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
        log "Sound watcher restored (PID $PID)"
        send_message "🔊 Sound watcher restored"
    fi

    rm -f /tmp/intercom_motion_was_active
    rm -f /tmp/intercom_sound_was_active
}

cleanup() {
    log "Closing intercom..."
    speaker off > /dev/null 2>&1
    rm -f /tmp/intercom_play.pcm /tmp/intercom_voice.ogg
    rm -f /tmp/intercom_recv.ogg /tmp/intercom_combined.raw
    rm -f /tmp/intercom_tail.raw
    restore_watchers
    send_message "📴 Intercom closed. Vigilantes restaurados."
    rm -f /tmp/intercom_active
    log "=== Intercom closed ==="
    exit 0
}

trap cleanup INT TERM

# --- INICIO ---
log "=== Intercom started ==="
touch /tmp/intercom_active
stop_watchers

if [ -f "$OFFSET_FILE" ]; then
    OFFSET=$(cat "$OFFSET_FILE")
else
    OFFSET=$(cat /tmp/tg_offset 2>/dev/null || echo "0")
fi

LAST_ACTIVITY=$(date '+%s')
LAST_VOICE_SENT=0
PLAYING=0
TG_CHECK=0

init_buffer

send_message "🎙️ Intercom activated.
━━━━━━━━━━━━━━━━
• Send voice notes to play them on the speaker
• I will automatically capture your voice if you speak near the camera
• Will close automatically after ${INACTIVITY_TIMEOUT}s of inactivity
• Use /intercom_off to close manually"

log "Listening for voice messages and microphone..."

# --- BUCLE PRINCIPAL ---
while true; do

    NOW=$(date '+%s')

    # Check inactivity timeout
    ELAPSED=$((NOW - LAST_ACTIVITY))
    if [ "$ELAPSED" -gt "$INACTIVITY_TIMEOUT" ]; then
        log "Inactivity timeout (${INACTIVITY_TIMEOUT}s)"
        send_message "⏱️ Intercom closed por inactividad."
        cleanup
    fi

    # --- ESCUCHAR MENSAJES DE TELEGRAM ---
    # Query Telegram every 5 iterations to avoid blocking buffer recording
    TG_CHECK=$(( (TG_CHECK + 1) % 5 ))
    if [ "$TG_CHECK" != "0" ]; then
        RESPONSE=""
    else
        RESPONSE=$(curl -k -s --max-time 3 \
            "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$OFFSET&timeout=0")
    fi

    UPDATE_IDS=$(echo "$RESPONSE" | grep -o '"update_id":[0-9]*' | cut -d':' -f2)

    for UPDATE_ID in $UPDATE_IDS; do
        RECV_CHAT_ID=$(echo "$RESPONSE" | grep -o '"chat":{"id":[^,]*' | sed -n '1p' | grep -o '[0-9-]*$')
        MENSAJE=$(echo "$RESPONSE" | grep -o '"text":"[^"]*"' | sed -n '1p' | cut -d'"' -f4)
        FILE_ID=$(echo "$RESPONSE" | grep -o '"file_id":"[^"]*"' | sed -n '1p' | cut -d'"' -f4)

        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"
        echo "$OFFSET" > /tmp/tg_offset

        if [ "$RECV_CHAT_ID" != "$CHAT_ID" ]; then
            continue
        fi

        if [ "$MENSAJE" = "/intercom_off" ]; then
            log "Manual close received"
            cleanup
        fi

        if [ -n "$FILE_ID" ]; then
            log "Voice note received (file_id: $FILE_ID)"
            send_message "🔊 Playing on speaker..."
            OGG_FILE=$(download_voice "$FILE_ID")
            if [ -n "$OGG_FILE" ]; then
                PLAYING=1
                play_audio "$OGG_FILE"
                rm -f "$OGG_FILE"
                # Flush fifo and reinit buffer after playback
                dd if="$AUDIO_FIFO" of=/dev/null bs=2048 count=80 2>/dev/null
                init_buffer
                PLAYING=0
                LAST_ACTIVITY=$(date '+%s')
            fi
        fi
    done

    # --- ESCUCHAR MICRÓFONO ---
    if [ "$PLAYING" = "0" ]; then
        # Record block in circular buffer
        record_buffer_block

        # Calculate volume of recently recorded block
        BFILE="$BUFFER_DIR/$(printf '%04d' $(( (BUFFER_INDEX - 1 + BUFFER_BLOCKS) % BUFFER_BLOCKS ))).raw"
        VOLUME=0
        if [ -f "$BFILE" ]; then
            VOLUME=$(hexdump -v -e '1/2 "%d\n"' "$BFILE" 2>/dev/null | awk '
            BEGIN { sum=0; count=0 }
            {
                val = $1
                if (val > 32767) val = val - 65536
                if (val < 0) val = -val
                sum += val
                count++
            }
            END { if (count > 0) print int(sum/count); else print 0 }
            ')
        fi

        if echo "$VOLUME" | grep -qE '^[0-9]+$'; then
            if [ "$VOLUME" -gt "$VOICE_THRESHOLD" ]; then
                ELAPSED_VOICE=$((NOW - LAST_VOICE_SENT))
                if [ "$ELAPSED_VOICE" -gt "$VOICE_COOLDOWN" ]; then
                    log "Voice detected - volume: $VOLUME"
                    capture_voice
                    LAST_VOICE_SENT=$(date '+%s')
                    LAST_ACTIVITY=$(date '+%s')
                fi
            fi
        fi
    fi

done
