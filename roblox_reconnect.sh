#!/data/data/com.termux/files/usr/bin/bash

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 2.3 (Clone Detection + Discord Webhook)
# ─────────────────────────────────────────

PKG=""
CHECK_INTERVAL=10

MODE_MAIN="main"
MODE_MARKET="market"
URL_MARKET="https://www.roblox.com/games/129954712878723/Grow-a-Garden-Trade-World"

# Folder dasar — nama package bakal ditambahin
# di belakangnya lewat set_pkg_paths()
CONFIG_BASE_DIR="/data/local/tmp"
STATE_BASE_DIR="/data/local/tmp"
LOG_BASE_DIR="/storage/emulated/0"
LAST_PKG_FILE="/data/local/tmp/rbx_last_pkg"

RECONNECT_COOLDOWN=45
MONITOR_PID=""
LAST_VERBOSE=0
VERBOSE_INTERVAL=600

# ────────────────���────────────────────────
#   DISCORD WEBHOOK SETTINGS
# ─────────────────────────────────────────

DISCORD_WEBHOOK=""
DISCORD_USER_ID=""
DISCORD_ENABLED=0

# ─────────────────────────────────────────
#   CLONE APP DETECTION CACHE
# ─────────────────────────────────────────

IS_CLONE_APP=""
DETECTED_USER_ID=""

# ─────────────────────────────────────────
#   PATH PER-PACKAGE
#   Tiap package com.roblox.* punya config,
#   state, dan log file masing-masing —
#   jadi server (private/public) bisa beda
#   per package/akun.
# ─────────────────────────────────────────

set_pkg_paths() {
    CONFIG_FILE="${CONFIG_BASE_DIR}/roblox_config_${PKG}.cfg"
    STATE_DIR="${STATE_BASE_DIR}/rbx_state_${PKG}"
    LOG_FILE="${LOG_BASE_DIR}/roblox_reconnect_${PKG}.log"

    FILE_LAST_RECONNECT="$STATE_DIR/last_reconnect"
    FILE_IN_BACKGROUND="$STATE_DIR/in_background"
    FILE_LAST_RELOG="$STATE_DIR/last_relog"
    FILE_RECONNECTING="$STATE_DIR/reconnecting"
}

# ─────────────────────────────────────────
#   FUNGSI DETEKSI CLONE APP
#   Deteksi: User ID storage, nested paths, package names
# ─────────────────────────────────────────

detect_clone_app_method() {
    local result="false"
    local reason=""
    
    # Method 1: Cek user ID dari external storage path
    local ext_dirs
    ext_dirs=$(ls -d /storage/emulated/* 2>/dev/null | grep -oE "[0-9]+$" | sort -u)
    
    for uid in $ext_dirs; do
        if [ "$uid" != "0" ]; then
            # User ID bukan 0 = kemungkinan clone app
            if [ -d "/storage/emulated/$uid/Android/data/$PKG" ]; then
                result="true"
                reason="User ID non-primary: /storage/emulated/$uid/"
                DETECTED_USER_ID="$uid"
                break
            fi
        fi
    done
    
    # Method 2: Cek package name mencurigakan
    if [ "$result" = "false" ]; then
        if echo "$PKG" | grep -qiE "(clone|parallel|dual|sandbox|secure|miui|samsung)"; then
            result="true"
            reason="Package name suspicious: $PKG"
        fi
    fi
    
    # Method 3: Cek nested path struktur di external storage
    if [ "$result" = "false" ]; then
        local app_storage_path
        app_storage_path=$(find /storage/emulated/0/Android/data/$PKG -type d -name "External" 2>/dev/null | head -1)
        if [ -n "$app_storage_path" ]; then
            result="true"
            reason="Nested External path detected: $app_storage_path"
        fi
    fi
    
    echo "$result|$reason"
}

check_clone_app() {
    local detection_result
    detection_result=$(detect_clone_app_method)
    IS_CLONE_APP=$(echo "$detection_result" | cut -d'|' -f1)
    
    if [ "$IS_CLONE_APP" = "true" ]; then
        local reason
        reason=$(echo "$detection_result" | cut -d'|' -f2)
        log "⚠️ CLONE APP TERDETEKSI! Reason: $reason"
        return 0
    else
        log "✅ Bukan clone app (direct install detected)"
        return 1
    fi
}

# ─────────────────────────────────────────
#   FUNGSI DISCORD WEBHOOK
# ─────────────────────────────────────────

send_discord_notification() {
    local event_type=$1  # "disconnect" atau "crash"
    local details=$2
    local timestamp
    
    if [ "$DISCORD_ENABLED" != "1" ] || [ -z "$DISCORD_WEBHOOK" ]; then
        return
    fi
    
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local embed_color="16711680"  # Red untuk error
    local embed_title="⚠️ Roblox Event"
    local embed_description=""
    
    case $event_type in
        "disconnect")
            embed_title="❌ Disconnected"
            embed_description="**DC Terdeteksi**\nAlasan: $details\nWaktu: $timestamp"
            embed_color="16711680"
            ;;
        "crash")
            embed_title="💥 App Crashed"
            embed_description="**Roblox Crash!**\nWaktu: $timestamp"
            embed_color="16711680"
            ;;
        "relog")
            embed_title="🔄 Relog"
            embed_description="**Auto Relog Triggered**\nWaktu: $timestamp"
            embed_color="16776960"
            ;;
        "reconnect_success")
            embed_title="✅ Reconnected"
            embed_description="**Berhasil Terhubung**\nWaktu: $timestamp"
            embed_color="65280"
            ;;
    esac
    
    local mention=""
    if [ -n "$DISCORD_USER_ID" ]; then
        mention="<@$DISCORD_USER_ID> "
    fi
    
    local payload=$(cat <<EOF
{
  "content": "$mention",
  "embeds": [{
    "title": "$embed_title",
    "description": "$embed_description",
    "color": $embed_color,
    "fields": [
      {
        "name": "Package",
        "value": "$PKG",
        "inline": true
      },
      {
        "name": "Clone App",
        "value": "$IS_CLONE_APP",
        "inline": true
      }
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
EOF
)
    
    curl -s -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 &
}

# ─────────────────────────────────────────
#   FUNGSI CONFIG
# ─────────────────────────────────────────

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# ─────────────────────────────────────────
#   CONFIG ROBLOX AUTO RECONNECT
#   Package : $PKG
#   Edit angka: 1 = ON, 0 = OFF
# ─────────────────────────────────────────

URL="$URL"
MODE="$MODE"

# Relog otomatis setiap X jam (0 = mati)
RELOG_SETIAP_JAM=$RELOG_SETIAP_JAM

# Reconnect otomatis saat disconnect (1=ON / 0=OFF)
RECONNECT_OTOMATIS=$RECONNECT_OTOMATIS

# Restart otomatis kalau Roblox crash (1=ON / 0=OFF)
RESTART_KALAU_CRASH=$RESTART_KALAU_CRASH

# Reconnect saat app di-home/background (1=ON / 0=OFF)
RECONNECT_SAAT_HOME=$RECONNECT_SAAT_HOME

# ─────────────────────────────────────────
#   DISCORD WEBHOOK SETTINGS
# ─────────────────────────────────────────

DISCORD_ENABLED=$DISCORD_ENABLED
DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
DISCORD_USER_ID="$DISCORD_USER_ID"
EOF
}

default_config() {
    URL=""
    MODE="$MODE_MAIN"
    RELOG_SETIAP_JAM=1
    RECONNECT_OTOMATIS=1
    RESTART_KALAU_CRASH=1
    RECONNECT_SAAT_HOME=0
    DISCORD_ENABLED=0
    DISCORD_WEBHOOK=""
    DISCORD_USER_ID=""
}

# ─────────────────────────────────────────
#   FUNGSI TAMPILAN
# ─────────────────────────────────────────

clr() { clear 2>/dev/null || printf '\033[2J\033[H'; }

header() {
    echo "========================================="
    echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
    if [ -n "$PKG" ]; then
        echo "   Akun/Package: $PKG"
    fi
    echo "========================================="
}

show_toggle() {
    local val=$1
    if [ "$val" = "1" ]; then echo "ON"; else echo "OFF"; fi
}

show_current_config() {
    local MODE_LABEL
    if [ "$MODE" = "$MODE_MARKET" ]; then
        MODE_LABEL="Market Grow a Garden (Public)"
    else
        MODE_LABEL="Game - Private Server"
    fi
    echo ""
    echo "  Mode aktif : $MODE_LABEL"
    echo "  URL Main   : ${URL:-[belum diisi]}"
    echo "  URL Market : [Trade World]"
    echo "  Relog  : ${RELOG_SETIAP_JAM} jam $([ "$RELOG_SETIAP_JAM" = "0" ] && echo '(OFF)' || echo '(ON)')"
    echo "  Reconnect otomatis : $(show_toggle $RECONNECT_OTOMATIS)"
    echo "  Restart kalau crash: $(show_toggle $RESTART_KALAU_CRASH)"
    echo "  Reconnect saat home: $(show_toggle $RECONNECT_SAAT_HOME)"
    echo "  Discord Webhook    : $(show_toggle $DISCORD_ENABLED)"
    if [ "$DISCORD_ENABLED" = "1" ] && [ -n "$DISCORD_WEBHOOK" ]; then
        echo "  Discord User Tag   : ${DISCORD_USER_ID:-[tidak ada]}"
    fi
    echo ""
}

# ─────────────────────────────────────────
#   FUNGSI DETEKSI PACKAGE ROBLOX
#   2 cara: 1. Running apps, 2. Regex pattern
# ─────────────────────────────────────────

detect_running_roblox_apps() {
    ps -A 2>/dev/null | grep -i roblox | awk '{print $NF}' | sort -u | grep "^com\.roblox"
}

detect_installed_roblox_packages() {
    pm list packages 2>/dev/null | sed -n 's/^package://p' | grep -E "^com\.roblox\.[a-zA-Z0-9]*$" | sort
}

detect_roblox_packages() {
    local RUNNING_APPS=()
    local INSTALLED_PKGS=()
    
    # Deteksi aplikasi yang sedang berjalan
    echo "  🔄 Deteksi aplikasi Roblox yang sedang berjalan..."
    while IFS= read -r line; do
        [ -n "$line" ] && RUNNING_APPS+=("$line")
    done < <(detect_running_roblox_apps)
    
    # Deteksi package terinstall dengan regex pattern
    echo "  🔄 Deteksi package Roblox yang terinstall..."
    while IFS= read -r line; do
        [ -n "$line" ] && INSTALLED_PKGS+=("$line")
    done < <(detect_installed_roblox_packages)
    
    # Gabung dan hilangkan duplikat
    local ALL_PKGS=()
    local SEEN=()
    
    for pkg in "${RUNNING_APPS[@]}" "${INSTALLED_PKGS[@]}"; do
        local found=0
        for seen_pkg in "${SEEN[@]}"; do
            if [ "$pkg" = "$seen_pkg" ]; then
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            ALL_PKGS+=("$pkg")
            SEEN+=("$pkg")
        fi
    done
    
    # Output hasil deteksi
    printf "%s\n" "${ALL_PKGS[@]}"
}

pilih_package() {
    clr
    header
    echo ""

    local PKGS=()
    while IFS= read -r line; do
        [ -n "$line" ] && PKGS+=("$line")
    done < <(detect_roblox_packages)

    # Tidak ada package roblox kebaca sama sekali
    if [ ${#PKGS[@]} -eq 0 ]; then
        echo "  ⚠ Tidak ada package 'roblox' terdeteksi."
        echo "  Pakai default: com.roblox.client"
        PKG="com.roblox.client"
        set_pkg_paths
        echo "$PKG" > "$LAST_PKG_FILE" 2>/dev/null
        sleep 2
        return
    fi

    # Cuma 1 package → langsung pakai, gak perlu nanya
    if [ ${#PKGS[@]} -eq 1 ]; then
        PKG="${PKGS[0]}"
        set_pkg_paths
        echo "$PKG" > "$LAST_PKG_FILE" 2>/dev/null
        echo "  ℹ️  Hanya 1 package Roblox terdeteksi: $PKG"
        sleep 1
        return
    fi

    # Lebih dari 1 package → user pilih
    local LAST_PKG=""
    [ -f "$LAST_PKG_FILE" ] && LAST_PKG=$(cat "$LAST_PKG_FILE" 2>/dev/null)

    local DEFAULT_IDX=1
    local i=1
    for p in "${PKGS[@]}"; do
        [ "$p" = "$LAST_PKG" ] && DEFAULT_IDX=$i
        i=$((i+1))
    done

    echo "  📦 Ditemukan beberapa package Roblox di HP ini:"
    echo "      (tiap package = akun & server sendiri)"
    echo ""
    i=1
    for p in "${PKGS[@]}"; do
        local mark=""
        [ "$i" -eq "$DEFAULT_IDX" ] && mark="   ← terakhir dipakai"
        echo "  $i) $p$mark"
        i=$((i+1))
    done
    echo ""
    echo "  Pilih package (Enter = pakai yang terakhir):"
    printf "  > "
    read -r PILIH_PKG

    if [ -z "$PILIH_PKG" ]; then
        PKG="${PKGS[$((DEFAULT_IDX-1))]}"
    elif [[ "$PILIH_PKG" =~ ^[0-9]+$ ]] && [ "$PILIH_PKG" -ge 1 ] && [ "$PILIH_PKG" -le "${#PKGS[@]}" ]; then
        PKG="${PKGS[$((PILIH_PKG-1))]}"
    else
        echo "  ⚠ Pilihan tidak valid, pakai: ${PKGS[$((DEFAULT_IDX-1))]}"
        PKG="${PKGS[$((DEFAULT_IDX-1))]}"
        sleep 1
    fi

    set_pkg_paths
    echo "$PKG" > "$LAST_PKG_FILE" 2>/dev/null

    echo ""
    echo "  ✅ Package aktif: $PKG"
    sleep 1
}

# ─────────────────────────────────────────
#   WIZARD SETUP PERTAMA KALI - VERSI BARU
#   Dengan menu 5 opsi untuk pilih settings
# ─────────────────────────────────────────

wizard_setup() {
    clr
    header
    echo ""
    echo "  🎯 SETUP AWAL - SELAMAT DATANG!"
    echo ""
    echo "  Silakan pilih opsi setup:"
    echo ""
    echo "  1️⃣  Setup Cepat (rekomendasi - default semua ON)"
    echo "  2️⃣  Setup Mode Saja (Private/Public)"
    echo "  3️⃣  Setup Lengkap (custom semua setting)"
    echo "  4️⃣  Setup Manual (input satu-satu)"
    echo "  5️⃣  Batal & Keluar"
    echo ""
    printf "  Pilih opsi (1-5): "
    read -r SETUP_OPTION

    case $SETUP_OPTION in
        1) wizard_setup_cepat ;;
        2) wizard_setup_mode ;;
        3) wizard_setup_lengkap ;;
        4) wizard_setup_manual ;;
        5) 
            echo ""
            echo "  ❌ Setup dibatalkan. Keluar."
            sleep 1
            exit 0
            ;;
        *)
            echo "  ⚠ Pilih 1-5"
            sleep 1
            wizard_setup
            ;;
    esac
}

# OPSI 1: Setup Cepat
wizard_setup_cepat() {
    clr
    header
    echo ""
    echo "  ⚡ SETUP CEPAT"
    echo ""
    echo "  Mau auto reconnect ke mana?"
    echo "  1) Game - Private Server"
    echo "  2) Market Grow a Garden - Public"
    printf "  > "
    read -r INPUT_MODE
    if [ "$INPUT_MODE" = "2" ]; then
        MODE="$MODE_MARKET"
    else
        MODE="$MODE_MAIN"
    fi

    if [ "$MODE" = "$MODE_MAIN" ]; then
        echo ""
        echo "  Paste link private server GAME:"
        echo "  Contoh: https://www.roblox.com/games/126884695634066/Grow-a-Garden?privateServerLinkCode=xxx"
        while true; do
            printf "  > "
            read -r URL
            if [ -z "$URL" ]; then
                echo "  ⚠ URL tidak boleh kosong!"
                continue
            fi
            if echo "$URL" | grep -qE "^https://www\.roblox\.com/games/[0-9]+/[^?]+\?privateServerLinkCode=.+$"; then
                break
            fi
            echo "  ⚠ Link tidak valid!"
        done
    fi

    # Default semua ON
    RELOG_SETIAP_JAM=1
    RECONNECT_OTOMATIS=1
    RESTART_KALAU_CRASH=1
    RECONNECT_SAAT_HOME=0

    save_config
    echo ""
    echo "  ✅ Config setup cepat tersimpan!"
    sleep 2
}

# OPSI 2: Setup Mode Saja
wizard_setup_mode() {
    clr
    header
    echo ""
    echo "  🎮 SETUP MODE"
    echo ""
    echo "  Mau auto reconnect ke mana?"
    echo "  1) Game - Private Server"
    echo "  2) Market Grow a Garden - Public"
    printf "  > "
    read -r INPUT_MODE

    if [ "$INPUT_MODE" = "2" ]; then
        MODE="$MODE_MARKET"
    else
        MODE="$MODE_MAIN"
    fi

    if [ "$MODE" = "$MODE_MAIN" ]; then
        echo ""
        echo "  Paste link private server:"
        while true; do
            printf "  > "
            read -r URL
            if [ -z "$URL" ]; then
                echo "  ⚠ URL tidak boleh kosong!"
                continue
            fi
            if echo "$URL" | grep -qE "^https://www\.roblox\.com/games/[0-9]+/[^?]+\?privateServerLinkCode=.+$"; then
                break
            fi
            echo "  ⚠ Link tidak valid!"
        done
    fi

    save_config
    echo ""
    echo "  ✅ Mode berhasil disimpan!"
    sleep 2
}

# OPSI 3: Setup Lengkap (interactive dengan konfirmasi)
wizard_setup_lengkap() {
    clr
    header
    echo ""
    echo "  ⚙️  SETUP LENGKAP"
    echo ""

    # Mode
    echo "  1. Pilih Mode:"
    echo "     1) Private Server"
    echo "     2) Market (Public)"
    printf "     > "
    read -r INPUT_MODE
    if [ "$INPUT_MODE" = "2" ]; then
        MODE="$MODE_MARKET"
    else
        MODE="$MODE_MAIN"
    fi

    # URL (jika mode main)
    if [ "$MODE" = "$MODE_MAIN" ]; then
        echo ""
        echo "  2. URL Private Server:"
        while true; do
            printf "     > "
            read -r URL
            if [ -n "$URL" ]; then break; fi
            echo "     ⚠ URL tidak boleh kosong!"
        done
    fi

    # Relog
    echo ""
    echo "  3. Relog otomatis:"
    echo "     Setiap berapa jam? (0=OFF, default: 1)"
    printf "     > "
    read -r INPUT_RELOG
    if [[ "$INPUT_RELOG" =~ ^[0-9]+$ ]]; then
        RELOG_SETIAP_JAM=$INPUT_RELOG
    else
        RELOG_SETIAP_JAM=1
    fi

    # Reconnect
    echo ""
    echo "  4. Reconnect otomatis saat DC?"
    echo "     1=ON, 0=OFF (default: 1)"
    printf "     > "
    read -r INPUT_RC
    if [ "$INPUT_RC" = "0" ]; then RECONNECT_OTOMATIS=0; else RECONNECT_OTOMATIS=1; fi

    # Crash restart
    echo ""
    echo "  5. Restart otomatis kalau crash?"
    echo "     1=ON, 0=OFF (default: 1)"
    printf "     > "
    read -r INPUT_CR
    if [ "$INPUT_CR" = "0" ]; then RESTART_KALAU_CRASH=0; else RESTART_KALAU_CRASH=1; fi

    # Reconnect on home
    echo ""
    echo "  6. Reconnect saat app di-home/minimize?"
    echo "     1=ON, 0=OFF (default: 0)"
    printf "     > "
    read -r INPUT_RH
    if [ "$INPUT_RH" = "1" ]; then RECONNECT_SAAT_HOME=1; else RECONNECT_SAAT_HOME=0; fi

    # Discord Webhook
    echo ""
    echo "  7. Enable Discord Webhook Notifications?"
    echo "     1=ON, 0=OFF (default: 0)"
    printf "     > "
    read -r INPUT_DISCORD
    if [ "$INPUT_DISCORD" = "1" ]; then
        DISCORD_ENABLED=1
        echo ""
        echo "     Paste Discord Webhook URL:"
        printf "     > "
        read -r DISCORD_WEBHOOK
        echo ""
        echo "     Discord User ID untuk tag (opsional, tekan Enter untuk skip):"
        printf "     > "
        read -r DISCORD_USER_ID
    else
        DISCORD_ENABLED=0
        DISCORD_WEBHOOK=""
        DISCORD_USER_ID=""
    fi

    save_config

    clr
    header
    echo ""
    echo "  📋 RINGKASAN CONFIG:"
    show_current_config
    echo ""
    echo "  ✅ Setup lengkap selesai!"
    sleep 2
}

# OPSI 4: Setup Manual (satu-satu detail)
wizard_setup_manual() {
    clr
    header
    echo ""
    echo "  🔧 SETUP MANUAL - INPUT DETAIL"
    echo ""
    
    # Mode
    echo "  ➤ Pilih Mode:"
    echo "    1) Game - Private Server"
    echo "    2) Market Grow a Garden - Public"
    printf "    > "
    read -r INPUT_MODE
    if [ "$INPUT_MODE" = "2" ]; then
        MODE="$MODE_MARKET"
        echo "    ✓ Mode: Market (Public)"
    else
        MODE="$MODE_MAIN"
        echo "    ✓ Mode: Private Server"
    fi

    # URL Private
    if [ "$MODE" = "$MODE_MAIN" ]; then
        echo ""
        echo "  ➤ Paste URL Private Server:"
        echo "    Format: https://www.roblox.com/games/[ID]/[Name]?privateServerLinkCode=[CODE]"
        while true; do
            printf "    > "
            read -r URL
            if [ -z "$URL" ]; then
                echo "    ⚠ Tidak boleh kosong!"
                continue
            fi
            if echo "$URL" | grep -qE "^https://www\.roblox\.com/games/[0-9]+/[^?]+\?privateServerLinkCode=.+$"; then
                echo "    ✓ URL valid!"
                break
            fi
            echo "    ⚠ Format URL tidak valid!"
        done
    fi

    # Relog Detail
    echo ""
    echo "  ➤ RELOG OTOMATIS"
    echo "    Relog setiap berapa jam?"
    echo "    • 0 = Tidak ada relog otomatis"
    echo "    • 1 = Relog setiap 1 jam"
    echo "    • 2 = Relog setiap 2 jam"
    echo "    • dst..."
    printf "    > "
    read -r INPUT_RELOG
    if [[ "$INPUT_RELOG" =~ ^[0-9]+$ ]]; then
        RELOG_SETIAP_JAM=$INPUT_RELOG
        if [ "$RELOG_SETIAP_JAM" = "0" ]; then
            echo "    ✓ Relog otomatis: MATIKAN"
        else
            echo "    ✓ Relog setiap $RELOG_SETIAP_JAM jam"
        fi
    else
        RELOG_SETIAP_JAM=1
        echo "    ✓ Default: 1 jam"
    fi

    # Reconnect Detail
    echo ""
    echo "  ➤ RECONNECT OTOMATIS (saat DC)"
    echo "    • 1 = Nyalakan (reconnect saat disconnected)"
    echo "    • 0 = Matikan (tidak auto reconnect)"
    printf "    > "
    read -r INPUT_RC
    if [ "$INPUT_RC" = "0" ]; then
        RECONNECT_OTOMATIS=0
        echo "    ✓ Reconnect otomatis: MATIKAN"
    else
        RECONNECT_OTOMATIS=1
        echo "    ✓ Reconnect otomatis: NYALAKAN"
    fi

    # Crash Restart Detail
    echo ""
    echo "  ➤ RESTART OTOMATIS (kalau crash)"
    echo "    • 1 = Nyalakan (restart otomatis jika Roblox crash)"
    echo "    • 0 = Matikan (tidak auto restart)"
    printf "    > "
    read -r INPUT_CR
    if [ "$INPUT_CR" = "0" ]; then
        RESTART_KALAU_CRASH=0
        echo "    ✓ Restart crash: MATIKAN"
    else
        RESTART_KALAU_CRASH=1
        echo "    ✓ Restart crash: NYALAKAN"
    fi

    # Home Reconnect Detail
    echo ""
    echo "  ➤ RECONNECT SAAT HOME (minimize)"
    echo "    • 1 = Nyalakan (reconnect meskipun app di background)"
    echo "    • 0 = Matikan (hanya reconnect saat app aktif)"
    printf "    > "
    read -r INPUT_RH
    if [ "$INPUT_RH" = "1" ]; then
        RECONNECT_SAAT_HOME=1
        echo "    ✓ Reconnect saat home: NYALAKAN"
    else
        RECONNECT_SAAT_HOME=0
        echo "    ✓ Reconnect saat home: MATIKAN"
    fi

    # Discord Webhook Detail
    echo ""
    echo "  ➤ DISCORD WEBHOOK NOTIFICATIONS"
    echo "    • 1 = Nyalakan (kirim notif ke Discord)"
    echo "    • 0 = Matikan (tidak ada notifikasi)"
    printf "    > "
    read -r INPUT_DISCORD
    if [ "$INPUT_DISCORD" = "1" ]; then
        DISCORD_ENABLED=1
        echo ""
        echo "    Paste Discord Webhook URL:"
        echo "    (Petunjuk: https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_TOKEN)"
        printf "    > "
        read -r DISCORD_WEBHOOK
        
        if [ -z "$DISCORD_WEBHOOK" ]; then
            echo "    ⚠ Webhook URL tidak boleh kosong!"
            DISCORD_ENABLED=0
        else
            echo "    ✓ Webhook berhasil diset!"
            echo ""
            echo "    Discord User ID untuk tag (opsional, tekan Enter untuk skip):"
            printf "    > "
            read -r DISCORD_USER_ID
            if [ -n "$DISCORD_USER_ID" ]; then
                echo "    ✓ User ID: $DISCORD_USER_ID"
            fi
        fi
    else
        DISCORD_ENABLED=0
        DISCORD_WEBHOOK=""
        DISCORD_USER_ID=""
        echo "    ✓ Discord Webhook: MATIKAN"
    fi

    save_config

    echo ""
    echo "  🎉 Setup manual selesai!"
    echo ""
    echo "  📋 Ringkasan:"
    show_current_config
    sleep 2
}

# ─────────────────────────────────────────
#   MENU UTAMA (kalau config sudah ada)
#   DENGAN TAMPILAN YANG LEBIH BAIK
# ─────────────────────────────────────────

menu_utama() {
    while true; do
        clr
        header
        show_current_config
        
        # Garis pemisah yang lebih bagus
        echo "  ╔════════════════════════════════════╗"
        echo "  ║       MENU UTAMA - PILIH OPSI      ║"
        echo "  ╠════════════════════════════════════╣"
        echo "  ║  1) 🚀 Jalanin Sekarang            ║"
        echo "  ║  2) 🎮 Ganti Mode (Private/Public)║"
        echo "  ║  3) 🔗 Ganti URL Private Server   ║"
        echo "  ║  4) ⚙️  Edit Setting               ║"
        echo "  ║  5) 📦 Ganti Package/Akun         ║"
        echo "  ║  6) 🔔 Setup Discord Webhook      ║"
        echo "  ║  7) 🚪 Keluar                      ║"
        echo "  ╚════════════════════════════════════╝"
        echo ""
        printf "  Pilih (1-7): "
        read -r PILIHAN

        case $PILIHAN in
            1) return 0 ;;
            2) menu_pilih_mode ;;
            3) menu_ganti_url ;;
            4) menu_edit_setting ;;
            5) menu_ganti_package ;;
            6) menu_setup_discord ;;
            7) 
                clr
                echo "========================================="
                echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
                echo "========================================="
                echo ""
                echo "  👋 Terima kasih telah menggunakan!"
                echo "  Sampai jumpa lagi!"
                echo ""
                exit 0 
                ;;
            *) echo "  ⚠ Pilih angka 1-7"; sleep 1 ;;
        esac
    done
}

menu_pilih_mode() {
    clr
    header
    echo ""
    echo "  Pilih server untuk package: $PKG"
    echo ""
    echo "  1) Game - Private Server"
    echo "  2) Market Grow a Garden - Public"
    echo "  3) Batal"
    echo ""
    printf "  Pilih (1-3): "
    read -r PILIHAN_MODE

    case $PILIHAN_MODE in
        1)
            MODE="$MODE_MAIN"
            save_config
            echo ""
            echo "  ✅ Mode: Game - Private Server"
            ;;
        2)
            MODE="$MODE_MARKET"
            save_config
            echo ""
            echo "  ✅ Mode: Market Grow a Garden - Public"
            ;;
        3)
            echo ""
            echo "  Dibatalkan."
            ;;
        *)
            echo "  ⚠ Pilih 1-3"
            ;;
    esac
    sleep 1
}

menu_ganti_url() {
    clr
    header
    echo ""
    echo "  URL saat ini:"
    echo "  ${URL:-[kosong]}"
    echo ""
    echo "  Paste URL baru (Enter untuk batal):"
    echo "  Contoh: https://www.roblox.com/games/126884695634066/Grow-a-Garden?privateServerLinkCode=xxx"
    while true; do
        printf "  > "
        read -r NEW_URL
        if [ -z "$NEW_URL" ]; then
            echo ""
            echo "  Dibatalkan."
            break
        fi
        if echo "$NEW_URL" | grep -qE "^https://www\.roblox\.com/games/[0-9]+/[^?]+\?privateServerLinkCode=.+$"; then
            URL="$NEW_URL"
            save_config
            echo ""
            echo "  ✅ URL diperbarui!"
            break
        fi
        echo "  ⚠ Link tidak valid! Harus private server Roblox."
        echo "  Contoh: https://www.roblox.com/games/126884695634066/Grow-a-Garden?privateServerLinkCode=xxx"
        echo ""
    done
    sleep 1
}

menu_edit_setting() {
    while true; do
        clr
        header
        echo ""
        echo "  ╔════════════════════════════════════╗"
        echo "  ║        EDIT SETTING                ║"
        echo "  ╠════════════════════════════════════╣"
        echo "  ║  1) 🔄 Relog"
        local relog_status="${RELOG_SETIAP_JAM} jam $([ "$RELOG_SETIAP_JAM" = "0" ] && echo '(OFF)' || echo '(ON)')"
        echo "  ║     : $relog_status"
        echo "  ║  2) 🔗 Reconnect Otomatis         ║"
        echo "  ║     : $(show_toggle $RECONNECT_OTOMATIS)"
        echo "  ║  3) 💥 Restart Kalau Crash        ║"
        echo "  ║     : $(show_toggle $RESTART_KALAU_CRASH)"
        echo "  ║  4) 🏠 Reconnect Saat Home        ║"
        echo "  ║     : $(show_toggle $RECONNECT_SAAT_HOME)"
        echo "  ║  5) ⬅️  Kembali                    ║"
        echo "  ╚════════════════════════════════════╝"
        echo ""
        printf "  Pilih (1-5): "
        read -r PILIHAN

        case $PILIHAN in
            1)
                echo ""
                echo "  Relog setiap berapa jam? (0 = matikan relog):"
                printf "  > "
                read -r V
                if [[ "$V" =~ ^[0-9]+$ ]]; then
                    RELOG_SETIAP_JAM=$V
                    save_config
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan angka!"
                fi
                sleep 1
                ;;
            2)
                echo ""
                echo "  Reconnect otomatis (1=ON / 0=OFF):"
                printf "  > "
                read -r V
                if [ "$V" = "0" ] || [ "$V" = "1" ]; then
                    RECONNECT_OTOMATIS=$V
                    save_config
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan 0 atau 1!"
                fi
                sleep 1
                ;;
            3)
                echo ""
                echo "  Restart kalau crash (1=ON / 0=OFF):"
                printf "  > "
                read -r V
                if [ "$V" = "0" ] || [ "$V" = "1" ]; then
                    RESTART_KALAU_CRASH=$V
                    save_config
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan 0 atau 1!"
                fi
                sleep 1
                ;;
            4)
                echo ""
                echo "  Reconnect saat home (1=ON / 0=OFF):"
                printf "  > "
                read -r V
                if [ "$V" = "0" ] || [ "$V" = "1" ]; then
                    RECONNECT_SAAT_HOME=$V
                    save_config
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan 0 atau 1!"
                fi
                sleep 1
                ;;
            5) return ;;
            *) echo "  ⚠ Pilih 1-5"; sleep 1 ;;
        esac
    done
}

menu_ganti_package() {
    pilih_package
    default_config
    load_config
    if [ -z "$URL" ] && [ ! -f "$CONFIG_FILE" ]; then
        wizard_setup
        load_config
    fi
}

menu_setup_discord() {
    clr
    header
    echo ""
    echo "  ╔════════════════════════════════════╗"
    echo "  ║      DISCORD WEBHOOK SETUP         ║"
    echo "  ╠════════════════════════════════════╣"
    echo "  ║  Status: $(show_toggle $DISCORD_ENABLED)                     ║"
    if [ -n "$DISCORD_WEBHOOK" ]; then
        local webhook_short=$(echo "$DISCORD_WEBHOOK" | cut -c1-30)...
        echo "  ║  Webhook: $webhook_short"
    fi
    if [ -n "$DISCORD_USER_ID" ]; then
        echo "  ║  User ID: $DISCORD_USER_ID"
    fi
    echo "  ╚════════════════════════════════════╝"
    echo ""
    echo "  1) Enable/Disable Discord"
    echo "  2) Ganti Webhook URL"
    echo "  3) Ganti/Hapus User ID"
    echo "  4) Test Discord Webhook"
    echo "  5) Kembali"
    echo ""
    printf "  Pilih (1-5): "
    read -r PILIHAN

    case $PILIHAN in
        1)
            if [ "$DISCORD_ENABLED" = "1" ]; then
                DISCORD_ENABLED=0
                echo ""
                echo "  ✅ Discord Webhook: DIMATIKAN"
            else
                DISCORD_ENABLED=1
                echo ""
                echo "  ✅ Discord Webhook: DINYALAKAN"
            fi
            save_config
            sleep 1
            ;;
        2)
            echo ""
            echo "  Webhook URL saat ini:"
            if [ -n "$DISCORD_WEBHOOK" ]; then
                echo "  ${DISCORD_WEBHOOK:0:50}..."
            else
                echo "  [belum diset]"
            fi
            echo ""
            echo "  Paste webhook URL baru (Enter untuk batal):"
            printf "  > "
            read -r NEW_WEBHOOK
            if [ -n "$NEW_WEBHOOK" ]; then
                if echo "$NEW_WEBHOOK" | grep -q "discord.com/api/webhooks"; then
                    DISCORD_WEBHOOK="$NEW_WEBHOOK"
                    DISCORD_ENABLED=1
                    save_config
                    echo ""
                    echo "  ✅ Webhook berhasil diupdate!"
                else
                    echo ""
                    echo "  ⚠ URL tidak valid!"
                fi
            else
                echo ""
                echo "  Dibatalkan."
            fi
            sleep 1
            ;;
        3)
            echo ""
            echo "  User ID saat ini: ${DISCORD_USER_ID:-[tidak ada]}"
            echo ""
            echo "  Masukkan User ID baru (atau kosongkan untuk hapus):"
            printf "  > "
            read -r NEW_USER_ID
            DISCORD_USER_ID="$NEW_USER_ID"
            save_config
            if [ -n "$DISCORD_USER_ID" ]; then
                echo "  ✅ User ID: $DISCORD_USER_ID"
            else
                echo "  ✅ User ID dihapus"
            fi
            sleep 1
            ;;
        4)
            if [ -z "$DISCORD_WEBHOOK" ]; then
                echo ""
                echo "  ⚠ Webhook belum diset!"
                sleep 1
            else
                echo ""
                echo "  🧪 Testing Discord Webhook..."
                send_discord_notification "reconnect_success" "Test message"
                echo "  ✅ Test notification terkirim!"
                sleep 2
            fi
            ;;
        5) return ;;
        *) echo "  ⚠ Pilih 1-5"; sleep 1 ;;
    esac
}

# ─────────────────────────────────────────
#   FUNGSI CORE (log, join, monitor)
# ─────────────────────────────────────────

log() {
    echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

get_active_url() {
    if [ "$MODE" = "$MODE_MARKET" ]; then
        echo "$URL_MARKET"
    else
        echo "$URL"
    fi
}

join_private_server() {
    local ACTIVE_URL
    ACTIVE_URL=$(get_active_url)
    local MODE_LABEL
    if [ "$MODE" = "$MODE_MARKET" ]; then
        MODE_LABEL="Public/Market"
    else
        MODE_LABEL="Private"
    fi
    log ""
    log "🚀 [$PKG] Join server... [Mode: $MODE_LABEL]"
    echo "1" > "$FILE_RECONNECTING"
    am force-stop "$PKG"
    sleep 4
    am start -a android.intent.action.VIEW -d "$ACTIVE_URL" "$PKG"
    log "✅ [$PKG] Server launched [Mode: $MODE_LABEL]"
    echo "$(date +%s)" > "$FILE_LAST_RELOG"
}

wait_for_ingame() {
    log "👀 Menunggu INGAME (max 90s)..."
    local FOUND=0

    while read -r line; do
        if echo "$line" | grep -qi "Connection accepted from"; then
            IP=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
            log "✅ INGAME! Server IP: $IP"
            FOUND=1
            termux-vibrate -d 300 2>/dev/null
            send_discord_notification "reconnect_success" "Connected to server: $IP"
            break
        fi
    done < <(timeout 90 logcat -v time 2>/dev/null | grep --line-buffered -i "Connection accepted from")

    if [ "$FOUND" -eq 0 ]; then
        log "⏱️ Timeout - retry join..."
        sleep 3
        am force-stop "$PKG"
        sleep 3
        am start -a android.intent.action.VIEW -d "$(get_active_url)" "$PKG"
        log "🔄 Retry join, menunggu 90s..."

        while read -r line; do
            if echo "$line" | grep -qi "Connection accepted from"; then
                IP=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
                log "✅ INGAME! Server IP: $IP"
                FOUND=1
                termux-vibrate -d 300 2>/dev/null
                send_discord_notification "reconnect_success" "Connected to server: $IP"
                break
            fi
        done < <(timeout 90 logcat -v time 2>/dev/null | grep --line-buffered -i "Connection accepted from")

        [ "$FOUND" -eq 0 ] && log "⏱️ Retry timeout - lanjut monitoring..."
    fi

    echo "0" > "$FILE_RECONNECTING"
}

monitor_disconnect() {
    log "🔍 [$PKG] Monitor DC aktif (PID: $$)"
    echo "0" > "$FILE_IN_BACKGROUND"

    while read -r line; do

        if echo "$line" | grep -qi "foregroundActivities=false" && echo "$line" | grep -q "$PKG"; then
            echo "1" > "$FILE_IN_BACKGROUND"
            log "📱 [$PKG] App masuk background"
            continue
        fi

        if echo "$line" | grep -qi "foregroundActivities=true" && echo "$line" | grep -q "$PKG"; then
            sleep 5
            echo "0" > "$FILE_IN_BACKGROUND"
            log "📱 [$PKG] App kembali foreground"
            continue
        fi

        DC_DETECTED=0
        DC_REASON=""

        if echo "$line" | grep -qi "Sending disconnect with reason"; then
            DC_DETECTED=1; DC_REASON="Sending disconnect"
        fi
        if echo "$line" | grep -qi "Connection lost" && ! echo "$line" | grep -qi "Connection lost:"; then
            DC_DETECTED=1; DC_REASON="Connection lost"
        fi
        if echo "$line" | grep -qi "Lost connection with reason"; then
            DC_DETECTED=1; DC_REASON="Lost connection"
        fi
        if echo "$line" | grep -qi "Disconnected from server for reason"; then
            DC_DETECTED=1; DC_REASON="Disconnected from server"
        fi

        if [ "$DC_DETECTED" -eq 1 ]; then
            [ "$RECONNECT_OTOMATIS" = "0" ] && continue

            RECONNECTING=$(cat "$FILE_RECONNECTING")
            [ "$RECONNECTING" = "1" ] && { log "⏳ Sedang reconnect - skip"; continue; }

            BG=$(cat "$FILE_IN_BACKGROUND")
            if [ "$BG" = "1" ]; then
                if [ "$RECONNECT_SAAT_HOME" = "0" ]; then
                    log "⚠️ DC di background - skip (RECONNECT_SAAT_HOME=0)"
                    continue
                fi
            fi

            NOW=$(date +%s)
            LAST=$(cat "$FILE_LAST_RECONNECT")
            DIFF=$((NOW - LAST))
            if [ "$DIFF" -lt "$RECONNECT_COOLDOWN" ]; then
                log "⏳ Cooldown ($DIFF/$RECONNECT_COOLDOWN s) - skip"
                continue
            fi

            log "❌ DC! Reason: $DC_REASON"
            send_discord_notification "disconnect" "$DC_REASON"
            echo "$NOW" > "$FILE_LAST_RECONNECT"
            sleep 5
            join_private_server
            wait_for_ingame
        fi

    done < <(logcat -v time 2>/dev/null | grep --line-buffered -iE \
        "Sending disconnect with reason|Connection lost|Lost connection with reason|Disconnected from server for reason|foregroundActivities=")
}

start_monitor() {
    kill "$MONITOR_PID" 2>/dev/null
    sleep 1
    logcat -c
    sleep 1
    monitor_disconnect &
    MONITOR_PID=$!
    log "✅ Monitor started (PID: $MONITOR_PID)"
}

check_relog_needed() {
    [ "$RELOG_SETIAP_JAM" = "0" ] && return 1
    local NOW; NOW=$(date +%s)
    local LAST; LAST=$(cat "$FILE_LAST_RELOG")
    local ELAPSED=$((NOW - LAST))
    local RELOG_SECONDS=$((RELOG_SETIAP_JAM * 3600))
    [ "$ELAPSED" -ge "$RELOG_SECONDS" ]
}

cleanup() {
    log "🛑 Script dihentikan."
    kill "$MONITOR_PID" 2>/dev/null
    rm -rf "$STATE_DIR"
    exit 0
}
trap cleanup INT TERM

# ─────────────────────────────────────────
#   MAIN — CEK ROOT DULU
# ─────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    echo "⚠️  Minta akses root..."
    exec su -c "$0"
fi

# ─────────────────────────────────────────
#   MAIN — PILIH PACKAGE / AKUN ROBLOX
# ───────────���─────────────────────────────

pilih_package

# ─────────────────────────────────────────
#   MAIN — DETEKSI CLONE APP
# ─────────────────────────────────────────

check_clone_app

# ─────────────────────────────────────────
#   MAIN — LOAD CONFIG & TAMPILKAN MENU
# ─────────────────────────────────────────

default_config
load_config

if [ -z "$URL" ] && [ ! -f "$CONFIG_FILE" ]; then
    wizard_setup
    load_config
else
    menu_utama
    load_config
fi

# ─────────────────────────────────────────
#   JALANIN SCRIPT
# ─────────────────────────────────────────

mkdir -p "$STATE_DIR"
echo "0" > "$FILE_LAST_RECONNECT"
echo "0" > "$FILE_IN_BACKGROUND"
echo "$(date +%s)" > "$FILE_LAST_RELOG"
echo "0" > "$FILE_RECONNECTING"

clr
echo "=========================================" | tee -a "$LOG_FILE"
echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"    | tee -a "$LOG_FILE"
echo "=========================================" | tee -a "$LOG_FILE"
log "Package          : $PKG"
log "Clone App        : $IS_CLONE_APP"
log "Mode             : $([ "$MODE" = "$MODE_MARKET" ] && echo 'Market Grow a Garden (Public)' || echo 'Game - Private Server')"
log "URL aktif        : $(get_active_url)"
log "Relog            : setiap ${RELOG_SETIAP_JAM} jam    → $([ "$RELOG_SETIAP_JAM" = "0" ] && echo OFF || echo ON)"
log "Reconnect        : DC detection  → $(show_toggle $RECONNECT_OTOMATIS)"
log "Restart crash    : auto restart  → $(show_toggle $RESTART_KALAU_CRASH)"
log "Reconnect@home   : saat home     → $(show_toggle $RECONNECT_SAAT_HOME)"
log "Discord Webhook  : $(show_toggle $DISCORD_ENABLED)"
log "Log file         : $LOG_FILE"
echo "=========================================" | tee -a "$LOG_FILE"
echo ""

join_private_server
wait_for_ingame

log "🔍 Monitoring aktif..."
echo "-----------------------------------------" | tee -a "$LOG_FILE"

start_monitor

while true; do

    if [ "$RESTART_KALAU_CRASH" = "1" ]; then
        if ! ps -A 2>/dev/null | grep -q "$PKG" && ! pidof "$PKG" > /dev/null 2>&1; then
            log "💥 Roblox crash! Restart..."
            send_discord_notification "crash" "App crashed, attempting restart"
            sleep 3
            join_private_server
            wait_for_ingame
            start_monitor
            continue
        fi
    fi

    if check_relog_needed; then
        log "🔄 Relog setiap ${RELOG_SETIAP_JAM} jam..."
        send_discord_notification "relog" "Auto relog triggered"
        join_private_server
        wait_for_ingame
        start_monitor
        continue
    fi

    NOW=$(date +%s)
    if [ $((NOW - LAST_VERBOSE)) -ge "$VERBOSE_INTERVAL" ]; then
        log "✅ Roblox running"
        LAST_VERBOSE=$NOW
    fi

    sleep "$CHECK_INTERVAL"
done
