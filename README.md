# 🔄 Roblox Auto Reconnect + Auto Relog
**by Wardz** — Auto reconnect, crash recovery, error code detection via OCR, Discord webhook notification.

---

## 📋 Requirements

- Android (rooted)
- Termux
- Roblox terinstall (official atau clone app)

---

## ⚡ Install

### 1. Install Termux dependency

Buka Termux, jalankan:

```bash
pkg update -y && pkg upgrade -y && pkg install -y curl wget bash coreutils procps termux-tools python android-tools tsu && pip install pillow
```

### 2. Download script

```bash
curl -o ~/roblox_reconnect.sh https://raw.githubusercontent.com/wardz25/reconnect-rblx/main/roblox_reconnect.sh
```

### 3. Jalankan

```bash
bash ~/roblox_reconnect.sh
```

> Script otomatis minta root saat pertama kali dijalankan.

---

## 📦 Dependency Detail

| Package | Fungsi |
|---|---|
| `curl` | Kirim Discord webhook notification |
| `wget` | Download fallback |
| `bash` | Shell eksplisit (bukan sh default Termux) |
| `coreutils` | `date`, `sleep`, `awk`, `grep` versi GNU |
| `procps` | `ps` untuk filter PID dengan reliable |
| `termux-tools` | `termux-wake-lock` agar Termux tidak di-kill Android |
| `python` | Runtime untuk screen detection |
| `android-tools` | `screencap`, `input`, `dumpsys` |
| `tsu` | Root helper — `su` tanpa terminal terpisah |
| `pillow` (pip) | Pixel analysis dialog disconnect — ganti tesseract, tidak SIGFPE |

---

## 🔍 Fitur

- **Auto reconnect** — deteksi disconnect & rejoin otomatis
- **Crash recovery** — deteksi Roblox force-close & relaunch
- **OCR error monitor** — baca dialog error code langsung dari layar via `screencap + tesseract`
- **Discord webhook** — notifikasi status dengan Discord native timestamp
- **Multi-package** — support clone app (2 package sekaligus via floating window)
- **Private server support** — mode URL private server

---

## 📸 Screen Monitor

Script pakai `screencap` + Python Pillow untuk deteksi dialog disconnect Roblox. Pillow di-install otomatis. Tidak ada tesseract, tidak ada SIGFPE.

> **Catatan:** Layar device harus tetap nyala saat monitoring agar OCR bisa baca layar.

---

## 🔔 Discord Webhook (Opsional)

Setup saat pertama kali jalankan script — akan ada prompt untuk masukkan webhook URL.

Notifikasi yang dikirim:
- Disconnect / reconnect
- Crash & relaunch
- Error code terdeteksi (via OCR)
- Status device (CPU, RAM, suhu)

---

## ⚠️ Catatan

- Script harus dijalankan sebagai root (`su` otomatis via Termux)
- Layar harus nyala untuk OCR error monitor aktif
- Tested di Android 12+ dengan Termux dari F-Droid
