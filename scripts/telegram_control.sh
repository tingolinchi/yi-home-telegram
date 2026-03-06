#!/bin/sh

# =============================================================
# Yi Home 1080p camera control script via Telegram
# Firmware: yi-hack-allwinner v2
# =============================================================

# --- CONFIGURACIÓN ---
CONFIG_FILE="/tmp/sd/yi-hack/script/config.env"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    echo "ERROR: Cannot find $CONFIG_FILE" >&2
    exit 1
fi
OFFSET_FILE="/tmp/tg_offset"
LOG_FILE="/tmp/telegram_control.log"
VIDEO_DURATION=15   # Video duration in seconds
WATCH_SCRIPT="/tmp/sd/yi-hack/script/watch_motion.sh"
SOUND_SCRIPT="/tmp/sd/yi-hack/script/watch_sound.sh"
INTERCOM_SCRIPT="/tmp/sd/yi-hack/script/intercom.sh"
SILENT_FILE="/tmp/tg_silent"  # If it exists, alerts are silenced


# PATH completo
export PATH=/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base

# --- FUNCIONES AUXILIARES ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_message() {
    TEXT="$1"
    curl -k -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$TEXT" \
        > /dev/null 2>&1
}

get_motion_status() {
    if ps | grep -q "[m]otion\|[m]d"; then
        echo "enabled"
    else
        echo "desenabled"
    fi
}

# --- COMANDOS ---

cmd_snapshot() {
    log "Executing /snapshot"
    send_message "📷 Capturing snapshot..."

    imggrabber > /tmp/snapshot_now.jpg 2>/dev/null

    if [ -f "/tmp/snapshot_now.jpg" ] && [ -s "/tmp/snapshot_now.jpg" ]; then
        curl -k -s \
            -F "chat_id=$CHAT_ID" \
            -F "photo=@/tmp/snapshot_now.jpg" \
            -F "caption=📷 Snapshot - $(date '+%d/%m/%Y %H:%M:%S')" \
            "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" > /dev/null 2>&1
        log "Snapshot sent successfully"
        rm -f /tmp/snapshot_now.jpg
    else
        send_message "❌ Error capturing snapshot with imggrabber"
        log "Error: imggrabber did not generate image"
    fi
}

cmd_video() {
    log "Executing /video"
    VIDEO_FILE="/tmp/video.mp4"
    send_message "🎥 Recording ${VIDEO_DURATION}s video..."

    # Record video capturing h264 raw and packaging into mp4
    h264grabber | ffmpeg -y \
        -f h264 -i pipe:0 \
        -t $VIDEO_DURATION \
        -vcodec copy \
        "$VIDEO_FILE" > /tmp/ffmpeg.log 2>&1

    if [ -f "$VIDEO_FILE" ] && [ -s "$VIDEO_FILE" ]; then
        send_message "📤 Sending video..."
        curl -k -s \
            -F "chat_id=$CHAT_ID" \
            -F "video=@$VIDEO_FILE" \
            -F "caption=🎥 Video ${VIDEO_DURATION}s - $(date '+%d/%m/%Y %H:%M:%S')" \
            -F "supports_streaming=true" \
            "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" > /dev/null 2>&1
        log "Video sent successfully"
        rm -f "$VIDEO_FILE"
    else
        send_message "❌ Error recording video"
        log "Error ffmpeg: $(cat /tmp/ffmpeg.log | tail -1)"
    fi
}


cmd_reboot() {
    log "Executing /reboot"
    send_message "🔄 Rebooting camera... Back in a few seconds."
    sleep 2
    reboot
}

cmd_status() {
    log "Executing /status"
    HORA=$(date '+%d/%m/%Y %H:%M:%S')
    UPTIME=$(uptime | sed 's/^ *//')
    MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
    MEM_USADA=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
    IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | cut -d':' -f2 | awk '{print $1}')
    MOTION=$(get_motion_status)

    # Estado vigilante de movimiento
    WATCH_PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    if [ -n "$WATCH_PID" ]; then
        WATCH_STATUS="✅ active (PID $WATCH_PID)"
    else
        WATCH_STATUS="🔴 inactive"
    fi

    # Estado intercomunicador
    INTERCOM_PID=$(ps | grep "[i]ntercom" | awk '{print $1}' | sed -n '1p')
    if [ -n "$INTERCOM_PID" ]; then
        INTERCOM_STATUS="✅ active (PID $INTERCOM_PID)"
    else
        INTERCOM_STATUS="🔴 inactive"
    fi

    # Estado vigilante de sonido
    SOUND_PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
    if [ -n "$SOUND_PID" ]; then
        SOUND_STATUS="✅ active (PID $SOUND_PID)"
    else
        SOUND_STATUS="🔴 inactive"
    fi

    TEMP=""
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        T=$(cat /sys/class/thermal/thermal_zone0/temp)
        TEMP="
🌡️ Temperature: $((T / 1000))°C"
    fi

    send_message "📊 Camera status
━━━━━━━━━━━━━━━━
🕐 Date/time: $HORA
🌐 IP: ${IP:-Not available}
⏱️ Uptime: $UPTIME
💾 Memory used: ${MEM_USADA}%
👁️ Motion detection: $MOTION
👀 Motion watcher: $WATCH_STATUS
🔊 Sound watcher: $SOUND_STATUS
🎙️ Intercomunicador: $INTERCOM_STATUS${TEMP}"

    log "Status sent"
}

cmd_motion_on() {
    log "Executing /motion_on"

    # Check if already running
    PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        send_message "⚠️ Motion watcher is already running (PID $PID)"
        log "watch_motion.sh was already running (PID $PID)"
        return
    fi

    sh "$WATCH_SCRIPT" &
    sleep 1

    PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        send_message "✅ Motion watcher activated (PID $PID)"
        log "watch_motion.sh started with PID $PID"
    else
        send_message "❌ Error starting motion watcher"
        log "Error: could not start watch_motion.sh"
    fi
}

cmd_motion_off() {
    log "Executing /motion_off"

    PID=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    if [ -z "$PID" ]; then
        send_message "⚠️ Motion watcher is not running"
        log "watch_motion.sh was not running"
        return
    fi

    kill "$PID" 2>/dev/null
    sleep 1

    # Verificar que se ha detenido
    STILL=$(ps | grep "[w]atch_motion" | awk '{print $1}' | sed -n '1p')
    if [ -z "$STILL" ]; then
        send_message "🔴 Motion watcher stopped"
        log "watch_motion.sh stopped (PID $PID)"
    else
        kill -9 "$STILL" 2>/dev/null
        send_message "🔴 Motion watcher stopped forzosamente"
        log "watch_motion.sh stopped con kill -9 (PID $STILL)"
    fi
}

cmd_sound_on() {
    log "Executing /sound_on"

    # Check if already running
    PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        send_message "⚠️ Sound watcher is already running (PID $PID)"
        log "watch_sound.sh was already running (PID $PID)"
        return
    fi

    sh "$SOUND_SCRIPT" &
    sleep 2

    PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        send_message "✅ Sound watcher activated (PID $PID)"
        log "watch_sound.sh started with PID $PID"
    else
        send_message "❌ Error starting sound watcher"
        log "Error: could not start watch_sound.sh"
    fi
}

cmd_sound_off() {
    log "Executing /sound_off"

    PID=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
    if [ -z "$PID" ]; then
        send_message "⚠️ Sound watcher is not running"
        log "watch_sound.sh was not running"
        return
    fi

    kill "$PID" 2>/dev/null
    sleep 1

    STILL=$(ps | grep "[w]atch_sound" | awk '{print $1}' | sed -n '1p')
    if [ -z "$STILL" ]; then
        send_message "🔇 Sound watcher stopped"
        log "watch_sound.sh stopped (PID $PID)"
    else
        kill -9 "$STILL" 2>/dev/null
        send_message "🔇 Sound watcher stopped forzosamente"
        log "watch_sound.sh stopped con kill -9 (PID $STILL)"
    fi
}

cmd_log() {
    log "Executing /log"

    if [ ! -f "$LOG_FILE" ]; then
        send_message "📋 Log file is empty or does not exist"
        return
    fi

    # Send the last 30 lines of the log
    LOG_CONTENT=$(tail -30 "$LOG_FILE" 2>/dev/null)

    if [ -z "$LOG_CONTENT" ]; then
        send_message "📋 Log is empty"
        return
    fi

    curl -k -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=📋 Last 30 lines of the log:
━━━━━━━━━━━━━━━━
$LOG_CONTENT" \
        > /dev/null 2>&1

    log "Log sent"
}

cmd_intercom_on() {
    log "Executing /intercom_on"

    # Check if already running
    PID=$(ps | grep "[i]ntercom" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        send_message "⚠️ Intercom is already active (PID $PID)"
        log "intercom.sh was already running (PID $PID)"
        return
    fi

    sh "$INTERCOM_SCRIPT" &
    sleep 2

    PID=$(ps | grep "[i]ntercom" | awk '{print $1}' | sed -n '1p')
    if [ -n "$PID" ]; then
        log "intercom.sh started with PID $PID"
    else
        send_message "❌ Error starting intercom"
        log "Error: could not start intercom.sh"
    fi
}

cmd_intercom_off() {
    log "Executing /intercom_off"

    PID=$(ps | grep "[i]ntercom" | awk '{print $1}' | sed -n '1p')
    if [ -z "$PID" ]; then
        if [ -f /tmp/intercom_active ]; then
            # Process died unexpectedly, clean up the flag
            rm -f /tmp/intercom_active
            send_message "⚠️ Intercom is not active"
            log "intercom.sh was not running"
        else
            # Already closed cleanly by itself, send nothing
            log "intercom.sh already closed by itself, ignoring /intercom_off"
        fi
        return
    fi

    # Send SIGTERM so intercom.sh runs its cleanup()
    kill "$PID" 2>/dev/null
    sleep 2

    STILL=$(ps | grep "[i]ntercom" | awk '{print $1}' | sed -n '1p')
    if [ -n "$STILL" ]; then
        kill -9 "$STILL" 2>/dev/null
        log "intercom.sh force-killed (PID $STILL)"
    else
        log "intercom.sh stopped successfully (PID $PID)"
    fi
}

cmd_silent_on() {
    log "Executing /silent_on"
    touch "$SILENT_FILE"
    send_message "🔕 Alerts silenced. Watchers remain active but will not send notifications. Use /silent_off to re-enable."
}

cmd_silent_off() {
    log "Executing /silent_off"
    rm -f "$SILENT_FILE"
    send_message "🔔 Alerts re-enabled. You will receive motion and sound notifications."
}

cmd_led_on() {
    log "Executing /led_on"
    ipc_cmd -l ON > /dev/null 2>&1
    send_message "💡 Blue LED activated"
}

cmd_led_off() {
    log "Executing /led_off"
    ipc_cmd -l OFF > /dev/null 2>&1
    send_message "💡 Blue LED deactivated"
}

cmd_ir_on() {
    log "Executing /ir_on"
    ipc_cmd -i ON > /dev/null 2>&1
    send_message "🔆 Infrared activated"
}

cmd_ir_off() {
    log "Executing /ir_off"
    ipc_cmd -i OFF > /dev/null 2>&1
    send_message "🔅 Infrared deactivated"
}

cmd_help() {
    send_message "🤖 Available commands:
━━━━━━━━━━━━━━━━
📷 /snapshot — Capture a photo
🎥 /video — Record a ${VIDEO_DURATION}s
👀 /motion_on — Activate motion watcher
⛔ /motion_off — Deactivate motion watcher
🔊 /sound_on — Activate sound watcher
🔇 /sound_off — Deactivate sound watcher
🎙️ /intercom_on — Activate intercom
📴 /intercom_off — Deactivate intercom
🔕 /silent_on — Silence motion and sound alerts
🔔 /silent_off — Re-enable alerts
💡 /led_on — Turn on blue LED
💡 /led_off — Turn off blue LED
🔆 /ir_on — Turn on infrared
🔅 /ir_off — Turn off infrared
📊 /stat — Show system status
📋 /log — Show last log lines
🔄 /reboot — Reboot camera
❓ /help — Show this message"
}

# --- BUCLE PRINCIPAL ---

log "=== Telegram control service started ==="
send_message "✅ Camera online and ready. Type /help to see available commands."

# Recuperar offset guardado o iniciar en 0
if [ -f "$OFFSET_FILE" ]; then
    OFFSET=$(cat "$OFFSET_FILE")
else
    OFFSET=0
fi

while true; do
    # Obtener actualizaciones de Telegram
    RESPONSE=$(curl -k -s --max-time 35 \
        "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$OFFSET&timeout=30")

    # Procesar cada update_id
    UPDATE_IDS=$(echo "$RESPONSE" | grep -o '"update_id":[0-9]*' | cut -d':' -f2)

    for UPDATE_ID in $UPDATE_IDS; do

        RECV_CHAT_ID=$(echo "$RESPONSE" | grep -o '"chat":{"id":[^,]*' | sed -n '1p' | grep -o '[0-9-]*$')
        MENSAJE=$(echo "$RESPONSE" | grep -o '"text":"[^"]*"' | sed -n '1p' | cut -d'"' -f4)

        # Actualizar offset
        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        # Validar que el mensaje viene del chat autorizado
        if [ "$RECV_CHAT_ID" != "$CHAT_ID" ]; then
            log "Message ignored from unauthorized chat: $RECV_CHAT_ID"
            continue
        fi

        # Ignorar updates sin texto (fotos, audios, stickers, etc.)
        if [ -z "$MENSAJE" ]; then
            continue
        fi

        log "Command received: $MENSAJE"

        case "$MENSAJE" in
            /snapshot)   cmd_snapshot  ;;
            /video)      cmd_video     ;;
            /reboot)     cmd_reboot    ;;
            /status)     cmd_status    ;;
            /motion_on)  cmd_motion_on ;;
            /motion_off) cmd_motion_off;;
            /sound_on)   cmd_sound_on  ;;
            /sound_off)  cmd_sound_off ;;
            /log)        cmd_log       ;;
            /intercom_on)  cmd_intercom_on  ;;
            /intercom_off) cmd_intercom_off ;;
            /silent_on)    cmd_silent_on    ;;
            /silent_off)   cmd_silent_off   ;;
            /led_on)       cmd_led_on       ;;
            /led_off)      cmd_led_off      ;;
            /ir_on)        cmd_ir_on        ;;
            /ir_off)       cmd_ir_off       ;;
            /help|/start) cmd_help  ;;
            *)
                send_message "❓ Unknown command: $MENSAJE. Type /help to see available commands."
                ;;
        esac
    done

    sleep 2
done
