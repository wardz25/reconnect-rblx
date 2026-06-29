#!/data/data/com.termux/files/usr/bin/bash

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 2.13 (Sphinx Dashboard + Connected with Stats)
#   Perbaikan: - Status update pertama ditunda 15 detik
#              - Notifikasi Connected memiliki format Sphinx + CPU/RAM
#              - Thumbnail & footer Sphinx di semua embed
# ─────────────────────────────────────────

PKG1=""
PKG2=""
CHECK_INTERVAL=10

MODE_MAIN="main"
MODE_PUBLIC="public"
MODE_MARKET="market"
MODE_GAG2="gag2"

URL_MARKET="https://www.roblox.com/games/129954712878723/Grow-a-Garden-Trade-World"
URL_GAG2="https://www.roblox.com/games/97598239454123/Grow-a-Garden-2"

CONFIG_BASE_DIR="/data/local/tmp"
STATE_BASE_DIR="/data/local/tmp"
LOG_BASE_DIR="/storage/emulated/0"
LAST_PKG_FILE="/data/local/tmp/rbx_last_pkg"

RECONNECT_COOLDOWN=45
MONITOR_PID=""
LAST_VERBOSE=0
VERBOSE_INTERVAL=600

DISCORD_WEBHOOK=""
DISCORD_USER_ID=""
DISCORD_ENABLED=0

IS_CLONE_APP=""
DETECTED_USER_ID=""

USE_MULTI_PKG=0
USE_ALL_PKGS=0
PKGS=()
STATUS_INTERVAL=3600

# Sphinx branding
BOT_USERNAME="Sphinx Community"
BOT_AVATAR_URL="https://raw.githubusercontent.com/wardz25/updater/main/sphinx.png"

# ─────────────────────────────────────────
#   PATH PER-PACKAGE
# ─────────────────────────────────────────

set_pkg_paths() {
    local pkg=$1
    local base_var=$2
    eval "${base_var}_CONFIG_FILE=${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    eval "${base_var}_STATE_DIR=${STATE_BASE_DIR}/rbx_state_${pkg}"
    eval "${base_var}_LOG_FILE=${LOG_BASE_DIR}/roblox_reconnect_${pkg}.log"
    eval "${base_var}_FILE_LAST_RECONNECT=\${${base_var}_STATE_DIR}/last_reconnect"
    eval "${base_var}_FILE_IN_BACKGROUND=\${${base_var}_STATE_DIR}/in_background"
    eval "${base_var}_FILE_LAST_RELOG=\${${base_var}_STATE_DIR}/last_relog"
    eval "${base_var}_FILE_RECONNECTING=\${${base_var}_STATE_DIR}/reconnecting"
}

# ─────────────────────────────────────────
#   DETEKSI CLONE APP
# ─────────────────────────────────────────

detect_clone_app_method() {
    local pkg=$1
    local result="false"
    local reason=""
    local ext_dirs
    ext_dirs=$(ls -d /storage/emulated/* 2>/dev/null | grep -oE "[0-9]+$" | sort -u)
    for uid in $ext_dirs; do
        if [ "$uid" != "0" ]; then
            if [ -d "/storage/emulated/$uid/Android/data/$pkg" ]; then
                result="true"
                reason="User ID non-primary: /storage/emulated/$uid/"
                DETECTED_USER_ID="$uid"
                break
            fi
        fi
    done
    if [ "$result" = "false" ]; then
        if echo "$pkg" | grep -qiE "(clone|parallel|dual|sandbox|secure|miui|samsung)"; then
            result="true"
            reason="Package name suspicious: $pkg"
        fi
    fi
    if [ "$result" = "false" ]; then
        local app_storage_path
        app_storage_path=$(find /storage/emulated/0/Android/data/$pkg -type d -name "External" 2>/dev/null | head -1)
        if [ -n "$app_storage_path" ]; then
            result="true"
            reason="Nested External path detected"
        fi
    fi
    echo "$result|$reason"
}

check_clone_app() {
    local pkg=$1
    local detection_result
    detection_result=$(detect_clone_app_method "$pkg")
    IS_CLONE_APP=$(echo "$detection_result" | cut -d'|' -f1)
    if [ "$IS_CLONE_APP" = "true" ]; then
        local reason
        reason=$(echo "$detection_result" | cut -d'|' -f2)
        log_pkg "$pkg" "⚠️ CLONE APP: $reason"
        return 0
    else
        log_pkg "$pkg" "✅ Direct install detected"
        return 1
    fi
}

# ─────────────────────────────────────────
#   DISCORD WEBHOOK (dengan format Sphinx untuk Connected)
# ─────────────────────────────────────────

send_discord_notification() {
    local event_type=$1
    local details=$2
    local pkg=$3
    if [ "$DISCORD_ENABLED" != "1" ] || [ -z "$DISCORD_WEBHOOK" ]; then
        return
    fi
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local embed_color="16711680"
    local embed_title="⚠️ Event"
    local embed_description=""
    local fields="[]"
    case $event_type in
        "disconnect")
            embed_title="❌ Disconnected"
            embed_description="**Alasan:** $details\n**Waktu:** $timestamp"
            embed_color="16711680"
            ;;
        "crash")
            embed_title="💥 Crash"
            embed_description="**Waktu:** $timestamp"
            embed_color="16711680"
            ;;
        "relog")
            embed_title="🔄 Relog"
            embed_description="**Waktu:** $timestamp"
            embed_color="16776960"
            ;;
        "reconnect_success")
            embed_title="Connected ✅"
            embed_description="**Server IP:** $details\n**Waktu:** $timestamp"
            embed_color="65280"
            # Ambil status CPU/RAM dari package
            IFS='|' read -r status uptime ram_mb cpu ip ram_percent <<< "$(get_pkg_status "$pkg")"
            if [ "$status" = "Online" ]; then
                fields="[{\"name\":\"Package\",\"value\":\"$pkg\",\"inline\":true},{\"name\":\"Uptime\",\"value\":\"$uptime\",\"inline\":true},{\"name\":\"RAM\",\"value\":\"${ram_mb} MB (${ram_percent}%)\",\"inline\":true},{\"name\":\"CPU\",\"value\":\"${cpu}%\",\"inline\":true}]"
            else
                fields="[{\"name\":\"Package\",\"value\":\"$pkg\",\"inline\":true}]"
            fi
            ;;
        "split")
            embed_title="📱 Split Screen"
            embed_description="**2nd Package:** $details\n**Waktu:** $timestamp"
            embed_color="255255"
            ;;
        "floating")
            embed_title="🪟 Floating Window"
            embed_description="**Package:** $details\n**Waktu:** $timestamp"
            embed_color="16711935"
            ;;
    esac
    local mention=""
    if [ -n "$DISCORD_USER_ID" ]; then
        mention="<@$DISCORD_USER_ID> "
    fi
    local payload
    if [ "$event_type" = "reconnect_success" ]; then
        payload=$(cat <<EOF
{
  "username": "$BOT_USERNAME",
  "avatar_url": "$BOT_AVATAR_URL",
  "content": "$mention",
  "embeds": [{
    "title": "$embed_title",
    "description": "$embed_description",
    "color": $embed_color,
    "thumbnail": {
      "url": "$BOT_AVATAR_URL"
    },
    "fields": $fields,
    "footer": {
      "text": "$BOT_USERNAME",
      "icon_url": "$BOT_AVATAR_URL"
    },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
EOF
)
    else
        payload=$(cat <<EOF
{
  "username": "$BOT_USERNAME",
  "avatar_url": "$BOT_AVATAR_URL",
  "content": "$mention",
  "embeds": [{
    "title": "$embed_title",
    "description": "$embed_description",
    "color": $embed_color,
    "fields": [
      {
        "name": "Package",
        "value": "$pkg",
        "inline": true
      }
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
EOF
)
    fi
    curl -s -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 &
}

# ─────────────────────────────────────────
#   STATUS PERIODIK (Sphinx Dashboard)
# ─────────────────────────────────────────

get_pkg_status() {
    local pkg=$1
    local state_dir="${STATE_BASE_DIR}/rbx_state_${pkg}"
    local ip_file="${state_dir}/last_ip"
    local pid=$(ps -A 2>/dev/null | grep "$pkg" | grep -v grep | awk '{print $2}' | head -1)
    local status="Offline"
    local uptime="N/A"
    local ram_mb="N/A"
    local cpu="N/A"
    local ip=""
    local ram_percent="N/A"
    if [ -f "$ip_file" ]; then
        ip=$(cat "$ip_file")
    fi
    if [ -n "$pid" ]; then
        status="Online"
        uptime=$(ps -o etime= -p $pid 2>/dev/null | tr -d ' ' | head -1)
        local rss_kb=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ' | head -1)
        if [ -n "$rss_kb" ] && [ "$rss_kb" -gt 0 ]; then
            ram_mb=$(echo "scale=1; $rss_kb/1024" | bc)
            local total_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ]; then
                ram_percent=$(echo "scale=1; $rss_kb*100/$total_kb" | bc)
            fi
        fi
        cpu=$(ps -o %cpu= -p $pid 2>/dev/null | tr -d ' ' | head -1)
        if [ -z "$cpu" ]; then
            cpu="N/A"
        fi
    fi
    echo "$status|$uptime|$ram_mb|$cpu|$ip|$ram_percent"
}

send_status_update() {
    if [ "$DISCORD_ENABLED" != "1" ] || [ -z "$DISCORD_WEBHOOK" ]; then
        return
    fi
    local online_count=0
    local offline_count=0
    local fields=""
    for pkg in "${PKGS[@]}"; do
        IFS='|' read -r status uptime ram_mb cpu ip ram_percent <<< "$(get_pkg_status "$pkg")"
        if [ "$status" = "Online" ]; then
            online_count=$((online_count+1))
        else
            offline_count=$((offline_count+1))
        fi
        local field_value=""
        if [ "$status" = "Online" ]; then
            field_value="**Status:** ✅ Online\n**Uptime:** $uptime\n**RAM:** ${ram_mb} MB (${ram_percent}%)\n**CPU:** ${cpu}%\n**IP:** $ip"
        else
            field_value="**Status:** ❌ Offline"
        fi
        fields+="{\"name\":\"$pkg\",\"value\":\"$field_value\",\"inline\":true},"
    done
    fields=${fields%,}
    local device=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    local title=""
    local color=5814783
    if [ $online_count -gt 0 ]; then
        title="Connected ✅"
        color=65280
    else
        title="Disconnected ❌"
        color=16711680
    fi
    local embed=$(cat <<EOF
{
  "title": "$title",
  "description": "**Device:** $device\n**Online:** $online_count | **Offline:** $offline_count | **Total:** ${#PKGS[@]}",
  "color": $color,
  "thumbnail": {
    "url": "$BOT_AVATAR_URL"
  },
  "fields": [$fields],
  "footer": {
    "text": "$BOT_USERNAME",
    "icon_url": "$BOT_AVATAR_URL"
  },
  "timestamp": "$timestamp"
}
EOF
)
    curl -s -X POST "$DISCORD_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$BOT_USERNAME\",\"avatar_url\":\"$BOT_AVATAR_URL\",\"embeds\":[$embed]}" > /dev/null 2>&1 &
    echo "  📤 Status update sent: $title ($online_count online, $offline_count offline)"
}

# ─────────────────────────────────────────
#   CONFIG FUNCTIONS
# ─────────────────────────────────────────

load_config() {
    local cfg_file=$1
    if [ -f "$cfg_file" ]; then
        source "$cfg_file"
    fi
}

save_config() {
    local cfg_file=$1
    local pkg=$2
    local url=$3
    local mode=$4
    local relog=$5
    local reconnect=$6
    local restart=$7
    local home=$8
    cat > "$cfg_file" <<EOF
# Config untuk: $pkg

URL="$url"
MODE="$mode"
RELOG_SETIAP_JAM=$relog
RECONNECT_OTOMATIS=$reconnect
RESTART_KALAU_CRASH=$restart
RECONNECT_SAAT_HOME=$home
DISCORD_ENABLED=$DISCORD_ENABLED
DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
DISCORD_USER_ID="$DISCORD_USER_ID"
EOF
}

persist_discord_settings() {
    local cfg_file=$1
    local pkg=$2
    local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home
    if [ -f "$cfg_file" ]; then
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
    fi
    save_config "$cfg_file" "$pkg" "$saved_url" "$saved_mode" \
        "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home"
    echo "  ✅ Discord settings saved to $cfg_file"
}

# ─────────────────────────────────────────
#   TAMPILAN
# ─────────────────────────────────────────

clr() { clear 2>/dev/null || printf '\033[2J\033[H'; }

header() {
    echo "========================================="
    echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
    if [ "${#PKGS[@]}" -gt 0 ]; then
        echo "   Packages: ${PKGS[*]}"
    elif [ -n "$PKG1" ]; then
        echo "   Package 1: $PKG1"
    fi
    echo "========================================="
}

show_toggle() {
    if [ "$1" = "1" ]; then echo "ON"; else echo "OFF"; fi
}

get_mode_label() {
    local mode=$1
    case $mode in
        "main") echo "Game - Private Server" ;;
        "public") echo "Game - Public Server" ;;
        "market") echo "Market Grow a Garden" ;;
        "gag2") echo "Grow a Garden 2 - Public" ;;
        *) echo "Unknown" ;;
    esac
}

# ─────────────────────────────────────────
#   VALIDASI INPUT
# ─────────────────────────────────────────

validate_discord_webhook() {
    local url=$1
    echo "$url" | grep -qE '^https://(discord|discordapp)\.com/api/webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{60,90}(\?[A-Za-z0-9_=&-]*)?$'
}

validate_private_server_url() {
    local url=$1
    if echo "$url" | grep -qE '^https://www\.roblox\.com/games/[0-9]+/[^?]+\?(privateServerLinkCode|accessCode)=[A-Za-z0-9_-]+$'; then
        return 0
    fi
    if echo "$url" | grep -qE '^https://www\.roblox\.com/share\?(code=[A-Za-z0-9]{16,40}&type=Server|type=Server&code=[A-Za-z0-9]{16,40})$'; then
        return 0
    fi
    return 1
}

validate_public_server_url() {
    local url=$1
    echo "$url" | grep -qE '^https://www\.roblox\.com/games/[0-9]+/[A-Za-z0-9%_-]+/?$'
}

show_current_config() {
    local url=$1
    local mode=$2
    local relog=$3
    local reconnect=$4
    local restart=$5
    local home=$6
    echo ""
    echo "  Mode aktif  : $(get_mode_label $mode)"
    echo "  URL         : ${url:-[belum diisi]}"
    echo "  Relog       : ${relog} jam $([ "$relog" = "0" ] && echo '(OFF)' || echo '(ON)')"
    echo "  Reconnect   : $(show_toggle $reconnect)"
    echo "  Restart     : $(show_toggle $restart)"
    echo "  Home RC     : $(show_toggle $home)"
    echo ""
}

# ─────────────────────────────────────────
#   DETEKSI PACKAGE
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
    while IFS= read -r line; do
        [ -n "$line" ] && RUNNING_APPS+=("$line")
    done < <(detect_running_roblox_apps)
    while IFS= read -r line; do
        [ -n "$line" ] && INSTALLED_PKGS+=("$line")
    done < <(detect_installed_roblox_packages)
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
    printf "%s\n" "${ALL_PKGS[@]}"
}

pilih_package() {
    local label=$1
    local var_name=$2
    clr
    header
    echo ""
    echo "  $label"
    echo ""
    local PKGS_LIST=()
    while IFS= read -r line; do
        [ -n "$line" ] && PKGS_LIST+=("$line")
    done < <(detect_roblox_packages)
    if [ ${#PKGS_LIST[@]} -eq 0 ]; then
        echo "  ⚠ Tidak ada package Roblox terdeteksi."
        eval "$var_name=com.roblox.client"
        sleep 2
        return
    fi
    if [ ${#PKGS_LIST[@]} -eq 1 ]; then
        eval "$var_name=${PKGS_LIST[0]}"
        echo "  ℹ️  Package: ${PKGS_LIST[0]}"
        sleep 1
        return
    fi
    echo "  📦 Pilih package:"
    echo ""
    local i=1
    for p in "${PKGS_LIST[@]}"; do
        echo "  $i) $p"
        i=$((i+1))
    done
    echo ""
    printf "  Pilih (1-${#PKGS_LIST[@]}): "
    read -r PILIH
    if [[ "$PILIH" =~ ^[0-9]+$ ]] && [ "$PILIH" -ge 1 ] && [ "$PILIH" -le "${#PKGS_LIST[@]}" ]; then
        eval "$var_name=${PKGS_LIST[$((PILIH-1))]}"
    else
        eval "$var_name=${PKGS_LIST[0]}"
    fi
    echo ""
    echo "  ✅ Package: $(eval echo \$$var_name)"
    sleep 1
}

# ─────────────────────────────────────────
#   SETUP MODE & URL
# ─────────────────────────────────────────

setup_mode_and_url() {
    local label=$1
    local mode_var=$2
    local url_var=$3
    while true; do
        clr
        header
        echo ""
        echo "  $label"
        echo ""
        echo "  1) Game - Private Server (input link)"
        echo "  2) Game - Public Server (input link)"
        echo "  3) Market Grow a Garden"
        echo "  4) Grow a Garden 2 - Public"
        echo "  5) Kembali ke menu sebelumnya"
        echo "  6) Keluar"
        echo ""
        printf "  Pilih mode (1-6): "
        read -r MODE_CHOICE
        case $MODE_CHOICE in
            1)
                printf -v "$mode_var" '%s' "main"
                echo ""
                echo "  Paste link private server:"
                echo "  Contoh: https://www.roblox.com/games/ID/Nama-Game?privateServerLinkCode=xxx"
                echo "  Atau  : https://www.roblox.com/share?code=xxx&type=Server"
                echo "  (ketik 'back' untuk kembali)"
                while true; do
                    printf "  > "
                    read -r INPUT_URL
                    [ "$INPUT_URL" = "back" ] && break 2
                    if [ -z "$INPUT_URL" ]; then
                        echo "  ⚠ URL tidak boleh kosong!"
                        continue
                    fi
                    if validate_private_server_url "$INPUT_URL"; then
                        printf -v "$url_var" '%s' "$INPUT_URL"
                        echo "  ✅ Link valid!"
                        sleep 1
                        return 0
                    fi
                    echo "  ⚠ Format tidak valid! Harus link private server (format lama atau Share)."
                done
                ;;
            2)
                printf -v "$mode_var" '%s' "public"
                echo ""
                echo "  Paste link public server:"
                echo "  Contoh: https://www.roblox.com/games/ID/Nama-Game"
                echo "  (ketik 'back' untuk kembali)"
                while true; do
                    printf "  > "
                    read -r INPUT_URL
                    [ "$INPUT_URL" = "back" ] && break 2
                    if [ -z "$INPUT_URL" ]; then
                        echo "  ⚠ URL tidak boleh kosong!"
                        continue
                    fi
                    if validate_public_server_url "$INPUT_URL"; then
                        printf -v "$url_var" '%s' "$INPUT_URL"
                        echo "  ✅ Link valid!"
                        sleep 1
                        return 0
                    fi
                    echo "  ⚠ Format tidak valid! Harus link public, tanpa query string."
                done
                ;;
            3)
                printf -v "$mode_var" '%s' "market"
                printf -v "$url_var" '%s' "$URL_MARKET"
                echo "  ✅ Mode: Market Grow a Garden"
                sleep 1
                return 0
                ;;
            4)
                printf -v "$mode_var" '%s' "gag2"
                printf -v "$url_var" '%s' "$URL_GAG2"
                echo "  ✅ Mode: Grow a Garden 2"
                sleep 1
                return 0
                ;;
            5)
                return 1
                ;;
            6)
                echo ""
                echo "  Sampai jumpa."
                echo ""
                exit 0
                ;;
            *)
                echo "  ⚠ Pilih 1-6"
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────
#   WIZARD SETUP
# ─────────────────────────────────────────

wizard_setup_pkg() {
    local pkg=$1
    local pkg_num=$2
    clr
    header
    echo ""
    echo "  🎯 SETUP PACKAGE $pkg_num: $pkg"
    echo ""
    local mode url relog reconnect restart home
    setup_mode_and_url "Setup Mode & URL untuk Package $pkg_num" mode url
    clr
    header
    echo ""
    echo "  ⚙️ SETUP SETTINGS"
    echo ""
    echo "  Relog setiap berapa jam? (0=OFF, default: 1)"
    printf "  > "
    read -r relog
    if ! [[ "$relog" =~ ^[0-9]+$ ]]; then relog=1; fi
    echo ""
    echo "  Reconnect otomatis? (1=ON, 0=OFF, default: 1)"
    printf "  > "
    read -r reconnect
    if [ "$reconnect" != "0" ]; then reconnect=1; fi
    echo ""
    echo "  Restart kalau crash? (1=ON, 0=OFF, default: 1)"
    printf "  > "
    read -r restart
    if [ "$restart" != "0" ]; then restart=1; fi
    echo ""
    echo "  Reconnect saat home? (1=ON, 0=OFF, default: 0)"
    printf "  > "
    read -r home
    if [ "$home" != "1" ]; then home=0; fi
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    save_config "$cfg_file" "$pkg" "$url" "$mode" "$relog" "$reconnect" "$restart" "$home"
    echo ""
    echo "  ✅ Config Package $pkg_num tersimpan!"
    sleep 2
}

menu_ganti_url_mode_pkg() {
    local pkg=$1
    local pkg_num=$2
    local cfg_file=$3
    local keep_relog keep_reconnect keep_restart keep_home
    keep_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
    local new_mode new_url
    setup_mode_and_url "Ganti Mode & URL — Package $pkg_num ($pkg)" new_mode new_url
    save_config "$cfg_file" "$pkg" "$new_url" "$new_mode" \
        "$keep_relog" "$keep_reconnect" "$keep_restart" "$keep_home"
    echo ""
    echo "  ✅ Mode & URL diupdate, setting lain tetap."
    sleep 1
}

menu_edit_settings_pkg() {
    local pkg=$1
    local cfg_file=$2
    while true; do
        local cur_url cur_mode cur_relog cur_reconnect cur_restart cur_home
        cur_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        clr
        header
        echo ""
        echo "  ⚙️ UBAH SETTING — $pkg"
        show_current_config "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home"
        echo "  1) Relog interval        (sekarang: ${cur_relog} jam)"
        echo "  2) Reconnect otomatis    (sekarang: $(show_toggle $cur_reconnect))"
        echo "  3) Restart kalau crash   (sekarang: $(show_toggle $cur_restart))"
        echo "  4) Reconnect saat home   (sekarang: $(show_toggle $cur_home))"
        echo "  5) Kembali"
        echo ""
        printf "  Pilih (1-5): "
        read -r PILIHAN
        case $PILIHAN in
            1)
                echo ""
                echo "  Relog setiap berapa jam? (0=OFF)"
                printf "  > "
                read -r V
                if [[ "$V" =~ ^[0-9]+$ ]]; then
                    save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$V" "$cur_reconnect" "$cur_restart" "$cur_home"
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan angka!"
                fi
                sleep 1
                ;;
            2)
                local new_val; new_val=$([ "$cur_reconnect" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$new_val" "$cur_restart" "$cur_home"
                echo "  ✅ Reconnect: $(show_toggle $new_val)"
                sleep 1
                ;;
            3)
                local new_val; new_val=$([ "$cur_restart" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$new_val" "$cur_restart" "$cur_home"
                echo "  ✅ Restart: $(show_toggle $new_val)"
                sleep 1
                ;;
            4)
                local new_val; new_val=$([ "$cur_home" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$new_val" "$cur_home"
                echo "  ✅ Home RC: $(show_toggle $new_val)"
                sleep 1
                ;;
            5) return ;;
            *) echo "  ⚠ Pilih 1-5"; sleep 1 ;;
        esac
    done
}

setup_or_load_pkg() {
    local pkg=$1
    local pkg_num=$2
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    if [ ! -f "$cfg_file" ]; then
        wizard_setup_pkg "$pkg" "$pkg_num"
        return
    fi

    if [ "$USE_ALL_PKGS" = "1" ]; then
        return
    fi

    while true; do
        local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        clr
        header
        echo ""
        echo "  📦 Config Package $pkg_num ($pkg) ditemukan dari run sebelumnya:"
        show_current_config "$saved_url" "$saved_mode" "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home"
        echo "  1) Pakai config ini, langsung jalan"
        echo "  2) Ganti mode / URL"
        echo "  3) Ubah setting (relog/reconnect/restart/home)"
        echo "  4) Setup ulang semua dari awal"
        echo "  5) Keluar"
        echo ""
        printf "  Pilih (1-5, default 1): "
        read -r PILIHAN
        case $PILIHAN in
            2)
                menu_ganti_url_mode_pkg "$pkg" "$pkg_num" "$cfg_file"
                ;;
            3)
                menu_edit_settings_pkg "$pkg" "$cfg_file"
                ;;
            4)
                wizard_setup_pkg "$pkg" "$pkg_num"
                return
                ;;
            5)
                echo ""
                echo "  Sampai jumpa."
                echo ""
                exit 0
                ;;
            *)
                local needs_url=0
                [ "$saved_mode" = "main" ] || [ "$saved_mode" = "public" ] && needs_url=1
                if [ "$needs_url" = "1" ] && [ -z "$saved_url" ]; then
                    echo ""
                    echo "  ⚠ URL belum diisi untuk mode ini. Masukkan URL dulu."
                    sleep 2
                    menu_ganti_url_mode_pkg "$pkg" "$pkg_num" "$cfg_file"
                else
                    return
                fi
                ;;
        esac
    done
}

menu_setup_discord() {
    clr
    header
    echo ""
    echo "  🔔 DISCORD WEBHOOK SETUP"
    echo ""
    echo "  1) Enable/Disable"
    echo "  2) Ganti Webhook URL"
    echo "  3) Ganti User ID"
    echo "  4) Kembali"
    echo ""
    printf "  Pilih: "
    read -r PILIHAN
    case $PILIHAN in
        1)
            if [ "$DISCORD_ENABLED" = "1" ]; then
                DISCORD_ENABLED=0
                echo "  ✅ Discord: OFF"
            else
                DISCORD_ENABLED=1
                echo "  ✅ Discord: ON"
            fi
            sleep 1
            ;;
        2)
            echo ""
            echo "  Paste webhook URL:"
            printf "  > "
            read -r DISCORD_WEBHOOK
            if validate_discord_webhook "$DISCORD_WEBHOOK"; then
                DISCORD_ENABLED=1
                echo "  ✅ Webhook updated!"
            else
                echo "  ⚠ Invalid! Format harus: https://discord.com/api/webhooks/{id}/{token}"
            fi
            sleep 1
            ;;
        3)
            echo ""
            echo "  User ID (atau Enter untuk skip):"
            printf "  > "
            read -r DISCORD_USER_ID
            echo "  ✅ Updated!"
            sleep 1
            ;;
    esac
}

# ─────────────────────────────────────────
#   SPLIT SCREEN / FLOATING (tidak dipakai di mode semua package)
# ─────────────────────────────────────────

get_view_activity() {
    local pkg=$1
    local url=$2
    local activity=""
    if command -v cmd >/dev/null 2>&1; then
        activity=$(cmd package resolve-activity --brief -a android.intent.action.VIEW -d "$url" 2>/dev/null | grep "$pkg/" | head -1)
        if [ -n "$activity" ]; then
            echo "$activity"
            return
        fi
    fi
    activity=$(dumpsys package "$pkg" 2>/dev/null | grep -A20 "android.intent.action.VIEW" | grep -oE "$pkg/[^ ]+" | head -1)
    if [ -n "$activity" ]; then
        echo "$activity"
        return
    fi
    echo "$pkg/com.roblox.client.RobloxActivity"
}

check_windowing_mode() {
    local pkg=$1
    dumpsys activity activities 2>/dev/null | grep -A10 "package=$pkg" | grep -oE "windowingMode=[0-9]+" | head -1
}

try_split_screen() {
    local pkg2=$1
    local url2=$2
    log_pkg "$pkg2" "📱 Mencoba split screen (windowingMode=4) untuk: $pkg2"
    local activity
    activity=$(get_view_activity "$pkg2" "$url2")
    log_pkg "$pkg2" "🔍 Menggunakan activity: $activity"
    am start -a android.intent.action.VIEW -d "$url2" -n "$activity" -f 0x10000000 --windowingMode 4 2>/dev/null
    sleep 3
    local actual_mode
    actual_mode=$(check_windowing_mode "$pkg2")
    if echo "$actual_mode" | grep -q "windowingMode=4"; then
        log_pkg "$pkg2" "✅ Split screen berhasil ($actual_mode)"
        send_discord_notification "split" "$pkg2" "$pkg2"
        SPLIT_ENABLED=1
        return 0
    fi
    log_pkg "$pkg2" "⚠️ Split screen gagal/tidak didukung (status: ${actual_mode:-tidak terdeteksi})"
    return 1
}

try_floating_window() {
    local pkg2=$1
    local url2=$2
    log_pkg "$pkg2" "🪟 Fallback: freeform window (windowingMode=5) untuk $pkg2"
    local activity
    activity=$(get_view_activity "$pkg2" "$url2")
    am start -a android.intent.action.VIEW -d "$url2" -n "$activity" -f 0x10000000 --windowingMode 5 2>/dev/null
    sleep 3
    local actual_mode
    actual_mode=$(check_windowing_mode "$pkg2")
    if echo "$actual_mode" | grep -q "windowingMode=5"; then
        log_pkg "$pkg2" "✅ Freeform window berhasil ($actual_mode)"
    else
        log_pkg "$pkg2" "⚠️ Device tidak support freeform — $pkg2 kemungkinan terbuka fullscreen (status: ${actual_mode:-tidak terdeteksi})"
    fi
    send_discord_notification "floating" "$pkg2" "$pkg2"
    return 0
}

open_second_package() {
    if [ "$USE_MULTI_PKG" != "1" ] || [ -z "$PKG2" ]; then
        return
    fi
    local mode2 url2
    local cfg2="${CONFIG_BASE_DIR}/roblox_config_${PKG2}.cfg"
    if [ -f "$cfg2" ]; then
        source "$cfg2"
        mode2="$MODE"
        url2="$URL"
    else
        mode2="market"
        url2="$URL_MARKET"
    fi
    local active_url2
    active_url2=$(get_active_url "$mode2" "$url2")
    if ! try_split_screen "$PKG2" "$active_url2"; then
        try_floating_window "$PKG2" "$active_url2"
    fi
}

# ─────────────────────────────────────────
#   LOG & CORE
# ─────────────────────────────────────────

log_pkg() {
    local pkg=$1
    local msg=$2
    echo "[$pkg] [$(date +%H:%M:%S)] $msg"
    local logfile="${LOG_BASE_DIR}/roblox_reconnect_${pkg}.log"
    echo "[$(date +%H:%M:%S)] $msg" >> "$logfile"
}

build_join_url() {
    local url=$1
    local place_id query code type
    if echo "$url" | grep -qE 'roblox\.com/share\?'; then
        code=$(echo "$url" | grep -oE 'code=[^&]+' | head -1 | cut -d= -f2)
        type=$(echo "$url" | grep -oE 'type=[^&]+' | head -1 | cut -d= -f2)
        type="${type:-Server}"
        if [ -n "$code" ]; then
            echo "roblox://navigation/share_links?code=${code}&type=${type}"
            return
        fi
    fi
    place_id=$(echo "$url" | grep -oE '/games/[0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -z "$place_id" ]; then
        echo "$url"
        return
    fi
    query=$(echo "$url" | grep -oE '\?.*' | sed 's/^?//')
    if [ -n "$query" ]; then
        echo "$url"
    else
        echo "https://www.roblox.com/games/start?placeId=${place_id}"
    fi
}

get_active_url() {
    local mode=$1
    local raw_url
    case $mode in
        "market") raw_url="$URL_MARKET" ;;
        "gag2") raw_url="$URL_GAG2" ;;
        *) raw_url="$2" ;;
    esac
    build_join_url "$raw_url"
}

join_server() {
    local pkg=$1
    local url=$2
    local mode=$3
    log_pkg "$pkg" "🚀 Jalanin: $pkg"
    log_pkg "$pkg" "🔗 Join URL: $url"
    am force-stop "$pkg"
    sleep 3
    am start -a android.intent.action.VIEW -d "$url" "$pkg"
    log_pkg "$pkg" "✅ Launched"
}

wait_ingame() {
    local pkg=$1
    log_pkg "$pkg" "👀 Menunggu INGAME..."
    local pid=$(pgrep -f "$pkg" | head -1)
    if [ -z "$pid" ]; then
        log_pkg "$pkg" "⚠️ Proses tidak ditemukan, skip wait_ingame"
        return
    fi
    local state_dir="${STATE_BASE_DIR}/rbx_state_${pkg}"
    mkdir -p "$state_dir"
    timeout 90 logcat --pid="$pid" -v time 2>/dev/null | grep --line-buffered -i "Connection accepted from" | head -1 > /dev/null
    if [ $? -eq 0 ]; then
        IP=$(logcat --pid="$pid" -v time 2>/dev/null | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
        log_pkg "$pkg" "✅ INGAME! IP: $IP"
        echo "$IP" > "$state_dir/last_ip"
        send_discord_notification "reconnect_success" "$IP" "$pkg"
    else
        log_pkg "$pkg" "⏱️ Timeout"
    fi
}

verify_ingame_stable() {
    local pkg=$1
    local cfg_file=$2
    local checks=0
    log_pkg "$pkg" "🔁 Tight-monitor 20s pasca-join (fase paling rawan crash)..."
    while [ $checks -lt 20 ]; do
        sleep 1
        if ! ps -A 2>/dev/null | grep -q "$pkg"; then
            log_pkg "$pkg" "💥 $pkg mati di fase join — rejoin paksa"
            sleep 2
            source "$cfg_file"
            local active_url
            active_url=$(get_active_url "$MODE" "$URL")
            join_server "$pkg" "$active_url" "$MODE"
            wait_ingame "$pkg"
            checks=0
            continue
        fi
        checks=$((checks + 1))
    done
    log_pkg "$pkg" "✅ Stabil pasca-join"
}

monitor_events() {
    local pkg=$1
    local cfg_file=$2
    log_pkg "$pkg" "🔍 Monitor aktif"
    local pid
    while true; do
        pid=$(pgrep -f "$pkg" | head -1)
        if [ -n "$pid" ]; then
            break
        fi
        sleep 2
    done
    logcat --pid="$pid" -v time 2>/dev/null | grep --line-buffered -iE "Sending disconnect|Connection lost|Lost connection|Disconnected from server" | while read -r line; do
        if echo "$line" | grep -qi "Sending disconnect with reason\|Connection lost\|Lost connection\|Disconnected from server"; then
            local reason
            if echo "$line" | grep -qi "Sending disconnect"; then
                reason="Sending disconnect"
            elif echo "$line" | grep -qi "Connection lost"; then
                reason="Connection lost"
            else
                reason="Disconnected"
            fi
            log_pkg "$pkg" "❌ DC: $reason"
            send_discord_notification "disconnect" "$reason" "$pkg"
            sleep 3
            source "$cfg_file"
            local active_url=$(get_active_url "$MODE" "$URL")
            join_server "$pkg" "$active_url" "$MODE"
            wait_ingame "$pkg"
            verify_ingame_stable "$pkg" "$cfg_file"
            break
        fi
    done
    log_pkg "$pkg" "🔄 Merestart monitor karena PID berubah atau logcat berhenti"
    monitor_events "$pkg" "$cfg_file" &
}

crash_monitor() {
    local pkg=$1
    local cfg_file=$2
    while true; do
        if ! ps -A 2>/dev/null | grep -q "$pkg"; then
            log_pkg "$pkg" "💥 Crash detected"
            send_discord_notification "crash" "App crashed" "$pkg"
            sleep 3
            source "$cfg_file"
            local active_url=$(get_active_url "$MODE" "$URL")
            join_server "$pkg" "$active_url" "$MODE"
            wait_ingame "$pkg"
            verify_ingame_stable "$pkg" "$cfg_file"
            pkill -f "monitor_events $pkg" 2>/dev/null
            monitor_events "$pkg" "$cfg_file" &
        fi
        sleep 5
    done
}

start_monitoring_pkg() {
    local pkg=$1
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    if [ ! -f "$cfg_file" ]; then
        log_pkg "$pkg" "❌ Config tidak ditemukan, skip"
        return
    fi
    source "$cfg_file"
    local active_url=$(get_active_url "$MODE" "$URL")
    if [ -z "$active_url" ] && { [ "$MODE" = "main" ] || [ "$MODE" = "public" ]; }; then
        log_pkg "$pkg" "❌ URL kosong untuk mode $MODE — skip"
        return
    fi
    local state_dir="${STATE_BASE_DIR}/rbx_state_${pkg}"
    mkdir -p "$state_dir"
    log_pkg "$pkg" "🚀 Memulai monitoring untuk $pkg (mode: $MODE)"
    join_server "$pkg" "$active_url" "$MODE"
    wait_ingame "$pkg"
    verify_ingame_stable "$pkg" "$cfg_file"
    monitor_events "$pkg" "$cfg_file" &
    crash_monitor "$pkg" "$cfg_file" &
    log_pkg "$pkg" "✅ Monitoring aktif"
}

# ─────────────────────────────────────────
#   MAIN
# ─────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    echo "⚠️ Requesting root..."
    exec su -c "$0"
fi

trap 'echo "⏹️ Script dihentikan"; exit' INT TERM

clr
echo "========================================="
echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
echo "========================================="
echo ""
echo "  Mau setup untuk berapa package?"
echo ""
echo "  1) 1 Package"
echo "  2) Semua package yang tersedia (Split atau Freeform)"
echo ""
printf "  Pilih: "
read -r SETUP_CHOICE

if [ "$SETUP_CHOICE" = "2" ]; then
    USE_ALL_PKGS=1
    USE_MULTI_PKG=0
    PKGS=()
    while IFS= read -r line; do
        [ -n "$line" ] && PKGS+=("$line")
    done < <(detect_roblox_packages)
    if [ ${#PKGS[@]} -eq 0 ]; then
        echo "  ⚠ Tidak ada package Roblox terdeteksi. Keluar."
        exit 1
    fi
    PKG1="${PKGS[0]}"
else
    USE_ALL_PKGS=0
    USE_MULTI_PKG=0
    pilih_package "📦 PILIH PACKAGE" PKG1
    PKGS=("$PKG1")
fi

for pkg in "${PKGS[@]}"; do
    set_pkg_paths "$pkg" "TMP"
    check_clone_app "$pkg"
    setup_or_load_pkg "$pkg" 1
done

PKG1_CFG="${CONFIG_BASE_DIR}/roblox_config_${PKGS[0]}.cfg"
if [ -f "$PKG1_CFG" ]; then
    DISCORD_ENABLED=$(grep '^DISCORD_ENABLED=' "$PKG1_CFG" | head -1 | cut -d= -f2)
    DISCORD_WEBHOOK=$(grep '^DISCORD_WEBHOOK=' "$PKG1_CFG" | head -1 | cut -d'"' -f2)
    DISCORD_USER_ID=$(grep '^DISCORD_USER_ID=' "$PKG1_CFG" | head -1 | cut -d'"' -f2)
    echo "  📥 Discord settings loaded from config: ENABLED=$DISCORD_ENABLED"
else
    echo "  ⚠ Config file not found, using defaults"
fi

clr
header
echo ""
if [ "$DISCORD_ENABLED" = "1" ] && [ -n "$DISCORD_WEBHOOK" ]; then
    echo "  🔔 Discord webhook sudah aktif (${DISCORD_WEBHOOK:0:30}...)"
    echo "  Mau ganti webhook/user ID?"
else
    echo "  🔔 Discord webhook belum diatur atau tidak aktif."
    echo "  Mau setup Discord webhook?"
fi
printf "  (1=YES, 0=NO/biarkan): "
read -r SETUP_DISCORD
if [ "$SETUP_DISCORD" = "1" ]; then
    echo ""
    echo "  Webhook URL:"
    printf "  > "
    read -r DISCORD_WEBHOOK
    if validate_discord_webhook "$DISCORD_WEBHOOK"; then
        DISCORD_ENABLED=1
        echo ""
        echo "  User ID (opsional):"
        printf "  > "
        read -r DISCORD_USER_ID
        echo ""
        echo "  ✅ Discord configured!"
    else
        DISCORD_ENABLED=0
        echo "  ⚠️ Invalid webhook! Format harus: https://discord.com/api/webhooks/{id}/{token}"
    fi
    sleep 2
fi

echo "  💾 Saving Discord settings to all configs..."
for pkg in "${PKGS[@]}"; do
    persist_discord_settings "${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg" "$pkg"
done

for pkg in "${PKGS[@]}"; do
    start_monitoring_pkg "$pkg" &
    sleep 2
done

if [ "$USE_MULTI_PKG" = "1" ] && [ -n "$PKG2" ]; then
    sleep 10
    open_second_package
fi

# Kirim status update pertama setelah semua package berkesempatan online (delay 15 detik)
if [ "$DISCORD_ENABLED" = "1" ] && [ -n "$DISCORD_WEBHOOK" ]; then
    echo "  ⏳ Menunggu 15 detik sebelum mengirim status update pertama..."
    sleep 15
    send_status_update
    while true; do
        sleep $STATUS_INTERVAL
        send_status_update
    done &
fi

wait