# 🎥 Yi Home 1080p — Telegram Control System

A complete remote surveillance and control system for the **Yi Home 1080p** camera running **yi-hack-allwinner v2** firmware by [roleoroleo](https://github.com/roleoroleo/yi-hack-Allwinner-v2?tab=readme-ov-file). Control your camera, receive automatic alerts, and communicate bidirectionally — all through a Telegram bot.

---

## ✨ Features

- 📷 **On-demand snapshot and video** recording via Telegram commands
- 🚨 **Automatic motion alerts** with photo
- 🔊 **Automatic sound alerts** with snapshot + 15s audio clip
- 🎙️ **Bidirectional voice intercom** — speak through Telegram, hear through the camera speaker
- 💡 **Blue LED control** — turn on/off remotely
- 🔆 **Infrared control** — turn on/off remotely
- 🔕 **Silent mode** — suppress notifications without stopping the watchers
- 📊 **System status** — IP, uptime, memory, process PIDs
- 🔄 **Remote reboot**

---

## 📁 Project structure

```
├── config.env              # Bot credentials (NOT included — create manually)
├── lower_half_init.sh      # System startup and process launcher
├── telegram_control.sh     # Telegram bot: command reception and processing
├── watch_motion.sh         # Motion detection watcher
├── watch_sound.sh          # Sound detection watcher
└── intercom.sh             # Bidirectional voice intercom
```

---

## 🤖 Telegram commands

| Command | Description |
|---|---|
| `/snapshot` | Capture and send a photo |
| `/video` | Record and send a 15s video |
| `/motion_on` / `/motion_off` | Start / stop motion watcher |
| `/sound_on` / `/sound_off` | Start / stop sound watcher |
| `/intercom_on` / `/intercom_off` | Start / stop voice intercom |
| `/silent_on` / `/silent_off` | Silence / re-enable alerts |
| `/led_on` / `/led_off` | Turn blue LED on / off |
| `/ir_on` / `/ir_off` | Turn infrared on / off |
| `/estado` | Show system status |
| `/log` | Show last 30 lines of the log |
| `/reboot` | Reboot the camera |
| `/help` | Show all available commands |

---

## ⚙️ Prerequisites

The following ARM-precompiled binaries must be present on the camera:

| Binary | Purpose |
|---|---|
| `curl` | Telegram API communication |
| `ffmpeg` | Audio/video conversion (requires libopus) |
| `imggrabber` | Snapshot capture |
| `h264grabber` | H.264 video capture |
| `speaker` | Speaker hardware control |
| `ipc_cmd` | Hardware control (LED, IR, motion) |

All binaries should be placed in `/tmp/sd/yi-hack/bin/`.

---

## 🚀 Installation

### 1. Access the camera

```sh
ssh root@<camera-ip>
```

### 2. Copy scripts

```sh
# Copy all .sh files to the scripts directory
chmod +x /tmp/sd/yi-hack/script/*.sh
mkdir -p /tmp/sd/yi-hack/motion
```

### 3. Create config.env

```sh
cat > /tmp/sd/yi-hack/script/config.env << 'EOF'
#!/bin/sh
BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
CHAT_ID="YOUR_CHAT_ID_HERE"
EOF
```

> ⚠️ **Never commit `config.env` to version control.** It is listed in `.gitignore`.

### 4. Create your Telegram bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the instructions
3. Copy the token to `BOT_TOKEN` in `config.env`
4. Get your `CHAT_ID` by sending a message to your bot and visiting:
   `https://api.telegram.org/bot<TOKEN>/getUpdates`

### 5. Test manually (without rebooting)

```sh
sh /tmp/sd/yi-hack/script/watch_motion.sh &
sleep 5
sh /tmp/sd/yi-hack/script/watch_sound.sh &
sleep 5
sh /tmp/sd/yi-hack/script/telegram_control.sh &
```

The scripts start automatically on boot via `lower_half_init.sh`.

---

## 🔊 Audio technical details

The camera uses different audio formats per direction:

| Direction | Format | Pipe |
|---|---|---|
| Microphone → Script | PCM 16-bit LE, mono, 8000 Hz | `/tmp/audio_fifo` |
| Script → Speaker | PCM 16-bit LE, mono, 16000 Hz | `/tmp/audio_in_fifo` |

The intercom uses a **30-block circular buffer** (~15s of prior audio) to ensure the beginning of sentences is not lost when voice detection triggers.

---

## 📋 Log files

Each script writes its own log to `/tmp/`:

```sh
tail -f /tmp/telegram_control.log
tail -f /tmp/watch_motion.log
tail -f /tmp/watch_sound.log
tail -f /tmp/intercom.log
```

> Logs are stored in `/tmp/` and are lost on reboot.

---

## 📄 Documentation

Full technical documentation is available in [`yi_telegram_documentation.docx`](./yi_telegram_documentation.docx), covering architecture, script internals, audio format discovery, installation steps, and troubleshooting.

---

## ⚠️ Disclaimer

> **Use this software at your own risk.**

- This project is **unofficial** and is not affiliated with, endorsed by, or supported by Yi Technology Co., Ltd.
- Installing this software **may void your device warranty**.
- This software enables **audio and video recording and remote monitoring**. You are solely responsible for complying with all applicable laws regarding surveillance and privacy in your jurisdiction, and for obtaining any necessary consent from individuals who may be recorded.
- You are solely responsible for **securing access** to your Telegram bot and camera credentials. The authors accept no liability for unauthorised access or data breaches resulting from insecure configuration.
- The authors accept **no liability** for any damage, data loss, legal issues, or any other consequence arising from the use of this software.

See the [LICENSE](./LICENSE) file for the full legal text.

---

## 📜 License

This project is licensed under the **MIT License** — see the [LICENSE](./LICENSE) file for details.

The license includes an additional disclaimer covering device warranty, privacy compliance, security responsibilities, and limitation of liability.

---

## 💰 Donation

If you enjoy this project, please consider supporting its maintenance with a donation. Thanks!!

Click [here](https://www.paypal.com/donate/?hosted_button_id=UUDC75BZZK2Q8) or use the below QR code or push the button to donate via PayPal

<img width="128" height="128" alt="QRcode" src="https://github.com/user-attachments/assets/5e08ec5c-8d72-4cc9-9c28-e6b8da8e5345" />

[![Donate with PayPal](https://www.paypalobjects.com/en_US/ES/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/donate/?hosted_button_id=UUDC75BZZK2Q8)

