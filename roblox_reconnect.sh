#!/data/data/com.termux/files/usr/bin/bash

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 2.4 (Multi-Package Split + Discord)
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

# Folder dasar
CONFIG_BASE_DIR="/data/local/tmp"
STATE_BASE_DIR="/data/local/tmp"
LOG_BASE_DIR="/storage/emulated/0"
LAST_PKG_FILE="/data/local/tmp/rbx_last_pkg"

RECONNECT_COOLDOWN=45
MONITOR_PID=""
LAST_VERBOSE=0
VERBOSE_INTERVAL=600

# Monitoring engine
JOIN_TIMEOUT=70
MONITOR_PID1=""
MONITOR_PID2=""
TIMEOUT_PID1=""
TIMEOUT_PID2=""
RECONNECT_MODE="stayps"   # stayps = selalu rejoin PS apapun | normal = cek doTeleport dulu

# Discord
DISCORD_WEBHOOK=""
DISCORD_USER_ID=""
DISCORD_ENABLED=0

# Clone detection
IS_CLONE_APP=""
DETECTED_USER_ID=""

# Split mode
USE_MULTI_PKG=0
SPLIT_ENABLED=0
DISPLAY_MODE="none"          # none | split | freeform
FREEFORM_LAYOUT="column"     # column | row
FREEFORM_PKG_LIST=""         # space-separated extra packages untuk freeform (PKG1 selalu pertama)

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
# ────────────────────────────────���────────

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
        log "⚠️ CLONE APP: $reason"
        return 0
    else
        log "✅ Direct install detected"
        return 1
    fi
}

# ─────────────────────────────────────────
#   DISCORD WEBHOOK
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
            embed_title="✅ Connected"
            embed_description="**Server IP:** $details\n**Waktu:** $timestamp"
            embed_color="65280"
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
        "value": "$pkg",
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
RECONNECT_MODE="${RECONNECT_MODE:-stayps}"
DISCORD_ENABLED=$DISCORD_ENABLED
DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
DISCORD_USER_ID="$DISCORD_USER_ID"
EOF
}

persist_discord_settings() {
    local cfg_file=$1
    local pkg=$2
    local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home saved_rmode

    if [ -f "$cfg_file" ]; then
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_rmode=$(grep '^RECONNECT_MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        [ -n "$saved_rmode" ] && RECONNECT_MODE="$saved_rmode"
    fi

    save_config "$cfg_file" "$pkg" "$saved_url" "$saved_mode" \
        "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home"
}

# ─────────────────────────────────────────
#   TAMPILAN
# ─────────────────────────────────────────

clr() { clear 2>/dev/null || printf '\033[2J\033[H'; }

header() {
    echo "========================================="
    echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
    if [ -n "$PKG1" ]; then
        echo "   Package 1: $PKG1"
    fi
    if [ -n "$PKG2" ] && [ "$USE_MULTI_PKG" = "1" ]; then
        echo "   Package 2: $PKG2"
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
    # Format asli Discord: https://discord.com/api/webhooks/{snowflake}/{token}
    # - snowflake: 17-20 digit angka (Discord ID/snowflake, makin lama makin
    #   panjang seiring waktu, jadi range bukan angka pasti)
    # - token: 60-90 karakter alnum + underscore/hyphen (contoh asli: 68 char)
    # - host bisa discord.com ATAU discordapp.com (alias lama, masih jalan)
    # - boleh ada query string opsional (?thread_id=... buat forum channel)
    local url=$1
    echo "$url" | grep -qE '^https://(discord|discordapp)\.com/api/webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{60,90}(\?[A-Za-z0-9_=&-]*)?$'
}

validate_private_server_url() {
    # Terima DUA format link private/VIP server Roblox:
    # 1) Format LAMA: games/{placeId}/{nama}?privateServerLinkCode=xxx
    #    (juga terima accessCode= sebagai alias yang kadang dipakai)
    # 2) Format BARU (default sejak Okt 2023): share?code=xxx&type=Server
    #    Kalau cuma divalidasi pake regex format lama, link share yang
    #    sekarang jadi default copy-paste dari tombol Share di app Roblox
    #    bakal SELALU ditolak wizard — padahal build_join_url() udah bisa
    #    nangenin format ini.
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
    # Link publik polos: games/{placeId}/{nama-slug}, TANPA query string.
    # Di-anchor di akhir ($) biar gak ke-loloskan link yang sebenernya private
    # server/share link yang nyasar masuk ke mode public.
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
    # sed 's/:.*//' buat strip suffix user ID (e.g. "com.roblox.client:10")
    # yang muncul kalau ada package diinstall untuk multiple user/clone space.
    # grep -E dengan + (bukan *) buat minimal 1 char setelah prefix com.roblox.
    # Ini menangkap semua varian: client, nodey, nodez, clienu, clienv, clieny, dll.
    pm list packages 2>/dev/null \
        | sed -n 's/^package://p' \
        | sed 's/:.*//' \
        | grep -E "^com\.roblox\.[a-zA-Z0-9]+" \
        | sort -u
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

    local PKGS=()
    while IFS= read -r line; do
        [ -n "$line" ] && PKGS+=("$line")
    done < <(detect_roblox_packages)

    if [ ${#PKGS[@]} -eq 0 ]; then
        echo "  ⚠ Tidak ada package Roblox terdeteksi."
        eval "$var_name=com.roblox.client"
        sleep 2
        return
    fi

    if [ ${#PKGS[@]} -eq 1 ]; then
        eval "$var_name=${PKGS[0]}"
        echo "  ℹ️  Package: ${PKGS[0]}"
        sleep 1
        return
    fi

    echo "  📦 Pilih package:"
    echo ""
    local i=1
    for p in "${PKGS[@]}"; do
        echo "  $i) $p"
        i=$((i+1))
    done
    echo ""
    printf "  Pilih (1-${#PKGS[@]}): "
    read -r PILIH

    if [[ "$PILIH" =~ ^[0-9]+$ ]] && [ "$PILIH" -ge 1 ] && [ "$PILIH" -le "${#PKGS[@]}" ]; then
        eval "$var_name=${PKGS[$((PILIH-1))]}"
    else
        eval "$var_name=${PKGS[0]}"
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
                        # printf -v menghindari bug eval pada bash versi Android/Termux
                        # yang kadang set variabel di scope yang salah (bukan parent caller)
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
    
    # Mode & URL
    setup_mode_and_url "Setup Mode & URL untuk Package $pkg_num" mode url
    
    # Settings
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
    echo "  Reconnect saat home? (1=ON, 0=OFF, default: 1)"
    printf "  > "
    read -r home
    if [ "$home" = "0" ]; then home=0; else home=1; fi
    
    echo ""
    echo "  Mode reconnect:"
    echo "  1) Stay PS  - apapun yang terjadi (DC/teleport/kick) selalu rejoin PS"
    echo "  2) Normal   - cek doTeleport dulu 3s sebelum reconnect"
    printf "  > "
    read -r rmode_input
    if [ "$rmode_input" = "2" ]; then RECONNECT_MODE="normal"; else RECONNECT_MODE="stayps"; fi
    
    # Save
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    save_config "$cfg_file" "$pkg" "$url" "$mode" "$relog" "$reconnect" "$restart" "$home"
    
    echo ""
    echo "  ✅ Config Package $pkg_num tersimpan!"
    sleep 2
}

menu_ganti_url_mode_pkg() {
    # Ganti mode & URL aja, setting lain (relog/reconnect/restart/home) tetap
    # dipertahankan dari config yang udah ada — gak perlu jawab ulang semuanya.
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
        local cur_url cur_mode cur_relog cur_reconnect cur_restart cur_home cur_rmode
        cur_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_rmode=$(grep '^RECONNECT_MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_rmode="${cur_rmode:-stayps}"

        clr
        header
        echo ""
        echo "  ⚙️ UBAH SETTING — $pkg"
        show_current_config "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home"
        echo "  1) Relog interval        (sekarang: ${cur_relog} jam)"
        echo "  2) Reconnect otomatis    (sekarang: $(show_toggle $cur_reconnect))"
        echo "  3) Restart kalau crash   (sekarang: $(show_toggle $cur_restart))"
        echo "  4) Reconnect saat home   (sekarang: $(show_toggle $cur_home))"
        echo "  5) Mode reconnect        (sekarang: $cur_rmode)"
        echo "  6) Kembali"
        echo ""
        printf "  Pilih (1-6): "
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
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$new_val" "$cur_home"
                echo "  ✅ Restart: $(show_toggle $new_val)"
                sleep 1
                ;;
            4)
                local new_val; new_val=$([ "$cur_home" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$new_val"
                echo "  ✅ Home RC: $(show_toggle $new_val)"
                sleep 1
                ;;
            5)
                echo ""
                echo "  Mode reconnect:"
                echo "  1) stayps — selalu rejoin PS (doTeleport/DC/kick apapun)"
                echo "  2) normal — cek doTeleport 3s, kick code 267 force rejoin, selain itu tunggu"
                printf "  > "
                read -r V
                if [ "$V" = "2" ]; then
                    RECONNECT_MODE="normal"
                else
                    RECONNECT_MODE="stayps"
                fi
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home"
                echo "  ✅ Mode: $RECONNECT_MODE"
                sleep 1
                ;;
            6) return ;;
            *) echo "  ⚠ Pilih 1-6"; sleep 1 ;;
        esac
    done
}

setup_or_load_pkg() {
    # Cek dulu apakah config buat package ini udah ada. Kalau ada, masuk ke
    # MAIN MENU — bukan cuma 2 pilihan run/setup-ulang doang. Dari sini bisa
    # langsung jalan, edit URL/mode aja, edit setting lain aja, setup ulang
    # total, atau keluar. Loop terus sampai user pilih "jalan" atau "keluar".
    local pkg=$1
    local pkg_num=$2
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"

    if [ ! -f "$cfg_file" ]; then
        wizard_setup_pkg "$pkg" "$pkg_num"
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
                # 1 atau default/kosong → pakai config tersimpan, validasi dulu
                # Kalau mode butuh URL (main/public) tapi URL kosong, jangan
                # biarkan lanjut — itu penyebab "Join URL: (kosong)" di log
                # dan crash langsung. Paksa ke Ganti URL dulu sebelum bisa jalan.
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
#   SPLIT SCREEN / FLOATING
# ─────────────────────────────────────────

# ─────────────────────────────────────────
#   SPLIT SCREEN / FREEFORM ENGINE
# ─────────────────────────────────────────

get_screen_size() {
    # Kembalikan SCREEN_W dan SCREEN_H sebagai variabel global
    local size
    size=$(wm size 2>/dev/null | grep -oE "[0-9]+x[0-9]+" | head -1)
    SCREEN_W=$(echo "$size" | cut -dx -f1)
    SCREEN_H=$(echo "$size" | cut -dx -f2)
    # Fallback ke ukuran umum kalau gagal baca
    SCREEN_W="${SCREEN_W:-1080}"
    SCREEN_H="${SCREEN_H:-2400}"
}

check_windowing_mode() {
    local pkg=$1
    dumpsys activity activities 2>/dev/null | grep -A3 "$pkg" | grep -oE "windowingMode=[0-9]+" | head -1
}

init_split_screen() {
    # Split screen yang benar:
    # PKG1 HARUS di-launch ulang dengan windowingMode=3 (SPLIT_SCREEN_PRIMARY)
    # dulu sebelum PKG2 bisa masuk ke mode 4 (SPLIT_SCREEN_SECONDARY).
    # Versi lama langsung launch PKG2 ke mode 4 tanpa set PKG1 ke mode 3,
    # jadi Android nolak karena tidak ada primary app — itu bug split-nya.
    local pkg1=$1
    local url1=$2
    local pkg2=$3
    local url2=$4

    log "📱 Inisialisasi Split Screen..."
    log "   PKG1 (Primary, mode 3): $pkg1"
    log "   PKG2 (Secondary, mode 4): $pkg2"

    # Step 1: force-stop keduanya biar bersih
    am force-stop "$pkg1" 2>/dev/null
    am force-stop "$pkg2" 2>/dev/null
    sleep 2

    # Step 2: launch PKG1 ke SPLIT_SCREEN_PRIMARY (mode 3)
    am start -a android.intent.action.VIEW -d "$url1" \
        --windowingMode 3 "$pkg1" 2>/dev/null
    sleep 3

    # Step 3: cek apakah PKG1 berhasil masuk mode 3
    local mode1
    mode1=$(check_windowing_mode "$pkg1")
    if ! echo "$mode1" | grep -q "windowingMode=3"; then
        log "⚠️ Split primary gagal ($mode1) — device mungkin tidak support split"
        log "   Fallback ke freeform 2-column..."
        DISPLAY_MODE="freeform"
        FREEFORM_LAYOUT="column"
        FREEFORM_PKG_LIST="$pkg2"
        init_freeform_windows "$pkg1" "$url1"
        return 1
    fi

    # Step 4: launch PKG2 ke SPLIT_SCREEN_SECONDARY (mode 4)
    am start -a android.intent.action.VIEW -d "$url2" \
        --windowingMode 4 "$pkg2" 2>/dev/null
    sleep 2

    local mode2
    mode2=$(check_windowing_mode "$pkg2")
    if echo "$mode2" | grep -q "windowingMode=4"; then
        log "✅ Split screen berhasil (PKG1=mode3, PKG2=mode4)"
        send_discord_notification "split" "$pkg2" "$pkg1"
        SPLIT_ENABLED=1
        return 0
    fi

    log "⚠️ Split secondary gagal ($mode2)"
    return 1
}

init_freeform_windows() {
    # Freeform dengan auto-grid bounds berdasarkan FREEFORM_LAYOUT dan
    # FREEFORM_PKG_LIST. PKG1 selalu window pertama.
    # Layout column = windows berjajar kiri-kanan (dibagi lebar layar).
    # Layout row    = windows berjajar atas-bawah (dibagi tinggi layar).
    # Bounds dikirim via --launch-bounds ke am start agar windows gak
    # numpuk di titik yang sama seperti sebelumnya.
    local pkg1=$1
    local url1=$2

    get_screen_size

    # Bangun array semua package (PKG1 + FREEFORM_PKG_LIST)
    local ALL_PKGS=("$pkg1")
    local ALL_URLS=("$url1")

    for extra_pkg in $FREEFORM_PKG_LIST; do
        local extra_cfg="${CONFIG_BASE_DIR}/roblox_config_${extra_pkg}.cfg"
        local extra_url extra_mode
        if [ -f "$extra_cfg" ]; then
            extra_mode=$(grep '^MODE=' "$extra_cfg" | head -1 | cut -d'"' -f2)
            extra_url_raw=$(grep '^URL=' "$extra_cfg" | head -1 | cut -d'"' -f2)
            extra_url=$(get_active_url "$extra_mode" "$extra_url_raw")
        else
            extra_url=$(get_active_url "market" "")
        fi
        ALL_PKGS+=("$extra_pkg")
        ALL_URLS+=("$extra_url")
    done

    local N=${#ALL_PKGS[@]}
    log "🪟 Freeform auto-grid: $N window, layout=$FREEFORM_LAYOUT (${SCREEN_W}x${SCREEN_H})"

    local i=0
    for pkg in "${ALL_PKGS[@]}"; do
        local url="${ALL_URLS[$i]}"
        local left top right bottom

        if [ "$FREEFORM_LAYOUT" = "row" ]; then
            local win_h=$((SCREEN_H / N))
            left=0
            top=$((i * win_h))
            right=$SCREEN_W
            bottom=$(( (i+1) * win_h ))
        else
            # default: column
            local win_w=$((SCREEN_W / N))
            left=$((i * win_w))
            top=0
            right=$(( (i+1) * win_w ))
            bottom=$SCREEN_H
        fi

        log "   [$((i+1))/$N] $pkg → bounds [${left},${top},${right},${bottom}]"

        am force-stop "$pkg" 2>/dev/null
        sleep 1
        am start -a android.intent.action.VIEW -d "$url" \
            --windowingMode 5 \
            --launch-bounds "$left $top $right $bottom" \
            "$pkg" 2>/dev/null
        sleep 2

        local actual
        actual=$(check_windowing_mode "$pkg")
        if echo "$actual" | grep -q "windowingMode=5"; then
            log "   ✅ $pkg freeform OK"
        else
            log "   ⚠️ $pkg: $actual (launch-bounds mungkin tidak didukung ROM ini)"
        fi

        send_discord_notification "floating" "$pkg" "$pkg1"
        i=$((i+1))
    done

    log "✅ Freeform grid selesai"
}

open_second_package() {
    if [ "$USE_MULTI_PKG" != "1" ] || [ -z "$PKG2" ]; then
        return
    fi

    local cfg2="${CONFIG_BASE_DIR}/roblox_config_${PKG2}.cfg"
    local mode2 url2_raw url2

    if [ -f "$cfg2" ]; then
        mode2=$(grep '^MODE=' "$cfg2" | head -1 | cut -d'"' -f2)
        url2_raw=$(grep '^URL=' "$cfg2" | head -1 | cut -d'"' -f2)
    else
        mode2="market"
        url2_raw=""
    fi
    url2=$(get_active_url "$mode2" "$url2_raw")

    if [ "$DISPLAY_MODE" = "split" ]; then
        local cfg1="${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
        local url1_raw url1 mode1
        mode1=$(grep '^MODE=' "$cfg1" 2>/dev/null | head -1 | cut -d'"' -f2)
        url1_raw=$(grep '^URL=' "$cfg1" 2>/dev/null | head -1 | cut -d'"' -f2)
        url1=$(get_active_url "${mode1:-market}" "$url1_raw")
        init_split_screen "$PKG1" "$url1" "$PKG2" "$url2"
    elif [ "$DISPLAY_MODE" = "freeform" ]; then
        # PKG1 sudah berjalan, init_freeform_windows akan handle semua window
        # termasuk PKG1 (diposisikan ulang) dan FREEFORM_PKG_LIST
        local cfg1="${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
        local url1_raw url1 mode1
        mode1=$(grep '^MODE=' "$cfg1" 2>/dev/null | head -1 | cut -d'"' -f2)
        url1_raw=$(grep '^URL=' "$cfg1" 2>/dev/null | head -1 | cut -d'"' -f2)
        url1=$(get_active_url "${mode1:-market}" "$url1_raw")
        init_freeform_windows "$PKG1" "$url1"
    fi
}

# ─────────────────────────────────────────
#   LOG & CORE
# ─────────────────────────────────────────

log() {
    local msg=$1
    echo "[$PKG1] [$(date +%H:%M:%S)] $msg"
    if [ -f "$PKG1_LOG_FILE" ]; then
        echo "[$(date +%H:%M:%S)] $msg" >> "$PKG1_LOG_FILE"
    fi
}

build_join_url() {
    # Convert link "biasa" jadi link DIRECT-JOIN biar Roblox langsung
    # connect ke server tanpa nyangkut di halaman Game Details.
    local url=$1
    local place_id query code type

    # Format BARU Roblox (default sejak Okt 2023) buat private/VIP server:
    #   https://www.roblox.com/share?code=XXXX&type=Server
    # Link ini OPAQUE — placeId & kode server-nya gak ada di URL, jadi gak
    # bisa diparse jadi /games/start kayak link lama. Kalau dibuka via am
    # start biasa, Roblox gagal resolve kodenya dan jatuh ke server PUBLIC
    # (bukan private server yang dimaksud). Harus pake custom scheme internal
    # yang dipakai app sendiri buat resolve share link:
    if echo "$url" | grep -qE 'roblox\.com/share\?'; then
        code=$(echo "$url" | grep -oE 'code=[^&]+' | head -1 | cut -d= -f2)
        type=$(echo "$url" | grep -oE 'type=[^&]+' | head -1 | cut -d= -f2)
        type="${type:-Server}"
        if [ -n "$code" ]; then
            echo "roblox://navigation/share_links?code=${code}&type=${type}"
            return
        fi
    fi

    # Format LAMA: https://www.roblox.com/games/ID/Nama-Game[?privateServerLinkCode=...]
    place_id=$(echo "$url" | grep -oE '/games/[0-9]+' | grep -oE '[0-9]+' | head -1)

    if [ -z "$place_id" ]; then
        # Format gak dikenal, biarin apa adanya
        echo "$url"
        return
    fi

    # Ambil query string yang udah ada (privateServerLinkCode, accessCode, dll)
    query=$(echo "$url" | grep -oE '\?.*' | sed 's/^?//')

    if [ -n "$query" ]; then
        # Private server link (ada privateServerLinkCode) — kirim MENTAH,
        # sama kayak sistem versi lama. Link jenis ini udah auto-join langsung
        # dari dulu, gak perlu dikonversi ke games/start.
        echo "$url"
    else
        # Link publik polos (market/gag2/public, tanpa query) — ini yang
        # nyangkut di halaman Game Details kalau dikirim mentah, jadi tetap
        # dikonversi ke format direct-join.
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
    local state_dir=$4

    log "🚀 Jalanin: $pkg"
    log "🔗 Join URL: $url"

    # Reset state sebelum launch
    if [ -n "$state_dir" ]; then
        echo "0" > "$state_dir/ingame"
        echo "0" > "$state_dir/joining"
        echo "0" > "$state_dir/lag"
        echo "0" > "$state_dir/left_game"
        local RC
        RC=$(cat "$state_dir/rc_count" 2>/dev/null || echo 0)
        echo $((RC+1)) > "$state_dir/rc_count"
        echo "$(date +%s)" > "$state_dir/last_relog"
    fi

    am force-stop "$pkg"
    sleep 3
    am start -a android.intent.action.VIEW -d "$url" "$pkg"
    log "✅ Launched"
}

update_pid() {
    local pkg=$1
    local state_dir=$2
    local PID
    PID=$(pidof "$pkg" 2>/dev/null | awk '{print $1}')
    echo "${PID:-0}" > "$state_dir/pid"
}

get_pid() {
    cat "$1/pid" 2>/dev/null || echo "0"
}

bring_to_foreground() {
    local pkg=$1
    sleep 4
    am start -n "$pkg/com.roblox.client.ActivityNativeMain" 2>/dev/null
}

start_join_timeout() {
    local pkg=$1
    local state_dir=$2
    local cfg_file=$3

    local OLD_TPID
    OLD_TPID=$(cat "$state_dir/timeout_pid" 2>/dev/null)
    [[ "$OLD_TPID" =~ ^[1-9][0-9]*$ ]] && kill "$OLD_TPID" 2>/dev/null

    echo "1" > "$state_dir/joining"
    (
        sleep "$JOIN_TIMEOUT"
        local INGAME JOINING
        INGAME=$(cat "$state_dir/ingame" 2>/dev/null || echo 0)
        JOINING=$(cat "$state_dir/joining" 2>/dev/null || echo 0)
        if [ "$JOINING" = "1" ] && [ "$INGAME" != "1" ]; then
            log "⏱️ [$pkg] Join timeout ${JOIN_TIMEOUT}s — reconnect paksa"
            send_discord_notification "disconnect" "Join timeout" "$pkg"
            source "$cfg_file" 2>/dev/null
            local DC
            DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
            echo $((DC+1)) > "$state_dir/dc_count"
            local active_url
            active_url=$(get_active_url "$MODE" "$URL")
            join_server "$pkg" "$active_url" "$MODE" "$state_dir"
            echo "reconnect" > "$state_dir/monitor_signal"
        fi
    ) &
    echo $! > "$state_dir/timeout_pid"
}

monitor_instance() {
    # Engine monitoring utama — menggantikan monitor_events + crash_monitor.
    # Semua deteksi difilter per-PID bukan seluruh logcat, sehingga:
    # - Zero false positive dari package lain
    # - Pattern disconnect spesifik per-proses
    local pkg=$1
    local cfg_file=$2
    local state_dir=$3

    log "🔍 [$pkg] Monitor aktif (PID-filtered)"
    echo "0" > "$state_dir/in_background"
    echo "0" > "$state_dir/lag"
    echo "0" > "$state_dir/left_game"
    update_pid "$pkg" "$state_dir"
    local CURRENT_PID
    CURRENT_PID=$(get_pid "$state_dir")

    logcat --pid="$CURRENT_PID" -v time 2>/dev/null | while read -r line; do

        # ── INGAME CONFIRM ───────────────────────────────────────────────
        # Lebih akurat dari "Connection accepted" — ini momen Roblox benar-
        # benar selesai loading dan karakter sudah masuk dunia game.
        if echo "$line" | grep -q "onGameLoaded.*SessionReporterState_GameLoaded"; then
            log "✅ [$pkg] INGAME!"
            echo "1" > "$state_dir/ingame"
            echo "0" > "$state_dir/joining"
            local OLD_TPID
            OLD_TPID=$(cat "$state_dir/timeout_pid" 2>/dev/null)
            [ -n "$OLD_TPID" ] && kill "$OLD_TPID" 2>/dev/null
            local RC DC
            RC=$(cat "$state_dir/rc_count" 2>/dev/null || echo 0)
            DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
            local IP
            IP=$(cat "$state_dir/server_ip" 2>/dev/null || echo "?")
            send_discord_notification "reconnect_success" "$IP (RC:$RC DC:$DC)" "$pkg"
            continue
        fi

        # ── JOIN DIMULAI ─────────────────────────────────────────────────
        if echo "$line" | grep -qE "! Joining game|launchGameWithParams"; then
            local IP
            IP=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
            [ -n "$IP" ] && echo "$IP" > "$state_dir/server_ip"
            log "🔗 [$pkg] Join dimulai — timeout ${JOIN_TIMEOUT}s"
            echo "0" > "$state_dir/ingame"
            start_join_timeout "$pkg" "$state_dir" "$cfg_file"
            continue
        fi

        # ── LAG DETECTION ────────────────────────────────────────────────
        if echo "$line" | grep -q "Davey! duration="; then
            local DUR
            DUR=$(echo "$line" | grep -oE "duration=[0-9]+" | cut -d= -f2)
            if [ -n "$DUR" ] && [ "$DUR" -gt 500 ]; then
                echo "1" > "$state_dir/lag"
            else
                echo "0" > "$state_dir/lag"
            fi
            continue
        fi

        # ── BACKGROUND / FOREGROUND ──────────────────────────────────────
        if echo "$line" | grep -q "Detected application backgrounding"; then
            echo "1" > "$state_dir/in_background"
            log "🌙 [$pkg] Background"
            if [ "$RECONNECT_SAAT_HOME" = "0" ]; then
                (
                    sleep 5
                    local STILL_BG
                    STILL_BG=$(cat "$state_dir/in_background" 2>/dev/null || echo 0)
                    if [ "$STILL_BG" = "1" ]; then
                        log "↩️ [$pkg] Masih BG 5s — tarik ke foreground"
                        bring_to_foreground "$pkg"
                    fi
                ) &
            fi
            continue
        fi

        if echo "$line" | grep -q "Detected application foregrounding"; then
            echo "0" > "$state_dir/in_background"
            local LEFT_AT_FG
            LEFT_AT_FG=$(cat "$state_dir/left_game" 2>/dev/null || echo 0)
            if [ "$LEFT_AT_FG" = "1" ]; then
                log "🔙 [$pkg] FG setelah leave — force rejoin PS"
                echo "0" > "$state_dir/left_game"
                echo "0" > "$state_dir/ingame"
                local DC
                DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                echo $((DC+1)) > "$state_dir/dc_count"
                send_discord_notification "disconnect" "FG setelah leave" "$pkg"
                source "$cfg_file"
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                update_pid "$pkg" "$state_dir"
                CURRENT_PID=$(get_pid "$state_dir")
                break
            fi
            log "☀️ [$pkg] Foreground"
            continue
        fi

        # ── LEAVE MANUAL ─────────────────────────────────────────────────
        # leaveUGCGameInternal + "Roblox has entered APP mode" = dua-langkah
        # konfirmasi user beneran leave (bukan cold start atau teleport).
        if echo "$line" | grep -q "leaveUGCGameInternal"; then
            echo "1" > "$state_dir/left_game"
            log "🚪 [$pkg] leaveUGCGame — tunggu konfirmasi APP mode"
            continue
        fi

        if echo "$line" | grep -q "Roblox has entered APP mode"; then
            local LEFT
            LEFT=$(cat "$state_dir/left_game" 2>/dev/null || echo 0)
            if [ "$LEFT" = "1" ]; then
                log "🏠 [$pkg] Confirmed leave+APP mode — force rejoin PS"
                echo "0" > "$state_dir/left_game"
                echo "0" > "$state_dir/ingame"
                local DC
                DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                echo $((DC+1)) > "$state_dir/dc_count"
                send_discord_notification "disconnect" "Manual leave" "$pkg"
                source "$cfg_file"
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                update_pid "$pkg" "$state_dir"
                CURRENT_PID=$(get_pid "$state_dir")
                break
            else
                log "ℹ️ [$pkg] APP mode tanpa leave — skip (cold start)"
            fi
            continue
        fi

        # ── STAYPS MODE ──────────────────────────────────────────────────
        # Selalu force rejoin ke PS untuk ANY doTeleport atau disconnect.
        if [ "$RECONNECT_MODE" = "stayps" ]; then
            if echo "$line" | grep -qE "doTeleport|Lost connection with reason"; then
                log "🔄 [$pkg] [STAYPS] DC/Teleport — force rejoin PS"
                local DC
                DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                echo $((DC+1)) > "$state_dir/dc_count"
                send_discord_notification "disconnect" "DC/Teleport (stayps)" "$pkg"
                source "$cfg_file"
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                update_pid "$pkg" "$state_dir"
                CURRENT_PID=$(get_pid "$state_dir")
                break
            fi

            if echo "$line" | grep -q "Sending disconnect with reason:"; then
                local REASON
                REASON=$(echo "$line" | grep -oE "reason: [0-9]+" | grep -oE "[0-9]+")
                log "❌ [$pkg] [STAYPS] Disconnect reason:${REASON} — force rejoin PS"
                local DC
                DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                echo $((DC+1)) > "$state_dir/dc_count"
                send_discord_notification "disconnect" "Reason:${REASON}" "$pkg"
                source "$cfg_file"
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                update_pid "$pkg" "$state_dir"
                CURRENT_PID=$(get_pid "$state_dir")
                break
            fi
        fi

        # ── NORMAL MODE ───────────────────────────────────────────────────
        # Cek doTeleport 3s sebelum memutuskan reconnect, biar gak salah
        # kick user yang lagi teleport ke server lain yang legitimate.
        if [ "$RECONNECT_MODE" = "normal" ]; then
            if echo "$line" | grep -q "Lost connection with reason"; then
                log "⚠️ [$pkg] [NORMAL] Lost connection — tunggu 3s cek doTeleport"
                echo "WAITING" > "$state_dir/dc_state"
                (
                    sleep 3
                    local STATE
                    STATE=$(cat "$state_dir/dc_state" 2>/dev/null)
                    if [ "$STATE" = "WAITING" ]; then
                        log "❌ [$pkg] [NORMAL] Tidak ada doTeleport — reconnect ke PS"
                        local DC
                        DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                        echo $((DC+1)) > "$state_dir/dc_count"
                        echo "DONE" > "$state_dir/dc_state"
                        send_discord_notification "disconnect" "Lost connection (normal)" "$pkg"
                        source "$cfg_file"
                        local active_url
                        active_url=$(get_active_url "$MODE" "$URL")
                        join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                        echo "reconnect" > "$state_dir/monitor_signal"
                    fi
                ) &
                continue
            fi

            if echo "$line" | grep -q "doTeleport"; then
                local STATE
                STATE=$(cat "$state_dir/dc_state" 2>/dev/null)
                if [ "$STATE" = "WAITING" ]; then
                    log "🌀 [$pkg] [NORMAL] doTeleport terdeteksi — pantau ${JOIN_TIMEOUT}s"
                    echo "DONE" > "$state_dir/dc_state"
                fi
                continue
            fi

            if echo "$line" | grep -q "Sending disconnect with reason:"; then
                local REASON
                REASON=$(echo "$line" | grep -oE "reason: [0-9]+" | grep -oE "[0-9]+")
                if [ "$REASON" = "267" ]; then
                    # reason 267 = kicked dari server, selalu force rejoin
                    log "🦵 [$pkg] [NORMAL] Kicked (reason:267) — force rejoin PS"
                    local DC
                    DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                    echo $((DC+1)) > "$state_dir/dc_count"
                    echo "DONE" > "$state_dir/dc_state"
                    send_discord_notification "disconnect" "Kicked reason:267" "$pkg"
                    source "$cfg_file"
                    local active_url
                    active_url=$(get_active_url "$MODE" "$URL")
                    join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                    echo "reconnect" > "$state_dir/monitor_signal"
                    break
                fi
                log "ℹ️ [$pkg] [NORMAL] Disconnect reason:${REASON} — skip (bukan 267)"
                continue
            fi
        fi

        # ── CRASH VIA LOGCAT ─────────────────────────────────────────────
        # Lebih reliable dari polling ps karena System.exit tercatat di logcat
        # proses itu sendiri sebelum proses benar-benar mati.
        if echo "$line" | grep -q "System.exit called"; then
            log "💥 [$pkg] Crash! (System.exit)"
            echo "0" > "$state_dir/ingame"
            echo "0" > "$state_dir/joining"
            send_discord_notification "crash" "System.exit" "$pkg"
            if [ "$RESTART_KALAU_CRASH" = "1" ]; then
                local DC
                DC=$(cat "$state_dir/dc_count" 2>/dev/null || echo 0)
                echo $((DC+1)) > "$state_dir/dc_count"
                sleep 3
                source "$cfg_file"
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE" "$state_dir"
                update_pid "$pkg" "$state_dir"
                CURRENT_PID=$(get_pid "$state_dir")
                break
            fi
        fi

    done

    log "🔚 [$pkg] Monitor session ended"
}

start_monitor() {
    local pkg=$1
    local cfg_file=$2
    local state_dir=$3

    # Kill monitor lama kalau masih jalan
    local OLD_PID
    OLD_PID=$(cat "$state_dir/monitor_pid" 2>/dev/null)
    if [[ "$OLD_PID" =~ ^[1-9][0-9]*$ ]]; then
        kill -- -"$OLD_PID" 2>/dev/null || kill "$OLD_PID" 2>/dev/null
        sleep 1
    fi
    rm -f "$state_dir/monitor_signal" "$state_dir/monitor_stop"

    (
        while true; do
            [ -f "$state_dir/monitor_stop" ] && break
            monitor_instance "$pkg" "$cfg_file" "$state_dir"
            [ -f "$state_dir/monitor_stop" ] && break
            log "🔁 [$pkg] Monitor loop restart..."
            sleep 2
            update_pid "$pkg" "$state_dir"
        done
    ) &
    local NEW_PID=$!
    echo "$NEW_PID" > "$state_dir/monitor_pid"
}

# ─────────────────────────────────────────
#   MAIN
# ─────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    echo "⚠️ Requesting root..."
    exec su -c "$0"
fi

# Menu awal
clr
echo "========================================="
echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
echo "========================================="
echo ""
echo "  Mau setup untuk berapa package?"
echo ""
echo "  1) 1 Package"
  echo "  2) 2 Package - Split Screen"
  echo "  3) Freeform Windows (2-4 Package, auto-grid)"
  echo "  4) Keluar"
echo ""
printf "  Pilih: "
read -r SETUP_CHOICE

case "$SETUP_CHOICE" in
    2)
        USE_MULTI_PKG=1
        DISPLAY_MODE="split"
        ;;
    3)
        USE_MULTI_PKG=1
        DISPLAY_MODE="freeform"
        clr; header
        echo ""
        echo "  Layout freeform:"
        echo "  1) Column (berdampingan kiri-kanan)"
        echo "  2) Row (atas-bawah)"
        printf "  Pilih (1-2, default 1): "
        read -r _LAYOUT
        [ "$_LAYOUT" = "2" ] && FREEFORM_LAYOUT="row" || FREEFORM_LAYOUT="column"
        echo ""
        echo "  Berapa package? (2-4)"
        printf "  > "
        read -r _NPKG
        [[ "$_NPKG" =~ ^[2-4]$ ]] || _NPKG=2
        FREEFORM_NPKG=$_NPKG
        ;;
    4)
        echo ""; echo "  Sampai jumpa."; exit 0
        ;;
    *)
        USE_MULTI_PKG=0
        DISPLAY_MODE="none"
        ;;
esac

# Setup Package 1
echo ""
pilih_package "📦 PILIH PACKAGE 1" PKG1
set_pkg_paths "$PKG1" "PKG1"
check_clone_app "$PKG1"
setup_or_load_pkg "$PKG1" 1

# Setup Package 2 (jika dipilih)
if [ "$USE_MULTI_PKG" = "1" ]; then
    echo ""
    pilih_package "📦 PILIH PACKAGE 2" PKG2
    set_pkg_paths "$PKG2" "PKG2"
    check_clone_app "$PKG2"
    setup_or_load_pkg "$PKG2" 2

    # Freeform: setup package tambahan (PKG3, PKG4) jika diminta
    if [ "$DISPLAY_MODE" = "freeform" ] && [ "${FREEFORM_NPKG:-2}" -gt 2 ]; then
        _EXTRA_PKGS="$PKG2"
        _PKGN=3
        while [ "$_PKGN" -le "${FREEFORM_NPKG:-2}" ]; do
            echo ""
            _EXTRA_PKG=""
            pilih_package "📦 PILIH PACKAGE $_PKGN (Freeform)" _EXTRA_PKG
            if [ -n "$_EXTRA_PKG" ]; then
                set_pkg_paths "$_EXTRA_PKG" "PKGX"
                check_clone_app "$_EXTRA_PKG"
                setup_or_load_pkg "$_EXTRA_PKG" "$_PKGN"
                _EXTRA_PKGS="$_EXTRA_PKGS $_EXTRA_PKG"
            fi
            _PKGN=$((_PKGN+1))
        done
        # Simpan list extra pkg (PKG2..PKGn) ke FREEFORM_PKG_LIST untuk init_freeform_windows
        FREEFORM_PKG_LIST="$_EXTRA_PKGS"
    else
        FREEFORM_PKG_LIST="$PKG2"
    fi
fi

# Load Discord settings lama (kalau ada) SEBELUM nanya — kalau nggak,
# variable global DISCORD_ENABLED/WEBHOOK/USER_ID bakal balik ke default
# kosong/OFF tiap script dijalanin, dan kalau user jawab "tidak" di prompt
# bawah ini, settingan Discord yang udah ON dari run sebelumnya bakal
# ketulis ulang jadi OFF oleh persist_discord_settings.
PKG1_CFG="${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
if [ -f "$PKG1_CFG" ]; then
    DISCORD_ENABLED=$(grep '^DISCORD_ENABLED=' "$PKG1_CFG" | head -1 | cut -d= -f2)
    DISCORD_WEBHOOK=$(grep '^DISCORD_WEBHOOK=' "$PKG1_CFG" | head -1 | cut -d'"' -f2)
    DISCORD_USER_ID=$(grep '^DISCORD_USER_ID=' "$PKG1_CFG" | head -1 | cut -d'"' -f2)
fi

clr
header
echo ""
if [ "$DISCORD_ENABLED" = "1" ]; then
    echo "  🔔 Discord webhook udah aktif dari setup sebelumnya."
    echo "  Mau ganti webhook/user ID?"
else
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

# Simpen setting Discord yang baru diisi ke file config tiap package,
# SEBELUM file itu di-source ulang di bawah (kalau nggak, bakal ketimpa
# balik ke nilai lama dan status Discord jadi salah/OFF terus).
persist_discord_settings "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" "$PKG1"
if [ "$USE_MULTI_PKG" = "1" ]; then
    persist_discord_settings "${CONFIG_BASE_DIR}/roblox_config_${PKG2}.cfg" "$PKG2"
fi

# Load config
source "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" 2>/dev/null
# Load RECONNECT_MODE dari config (bisa dioverride di sini)
_RMODE=$(grep '^RECONNECT_MODE=' "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" 2>/dev/null | head -1 | cut -d'"' -f2)
[ -n "$_RMODE" ] && RECONNECT_MODE="$_RMODE"

# START — init state files PKG1
mkdir -p "$PKG1_STATE_DIR"
for _F in ingame joining in_background dc_count rc_count lag dc_state left_game; do
    echo "0" > "$PKG1_STATE_DIR/$_F"
done
echo "$(date +%s)" > "$PKG1_STATE_DIR/last_relog"
echo "" > "$PKG1_STATE_DIR/server_ip"

clr
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"    | tee -a "$PKG1_LOG_FILE"
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
log "Package 1        : $PKG1"
log "Mode             : $(get_mode_label $MODE)"
log "Reconnect Mode   : $RECONNECT_MODE"
log "Multi Package    : $(show_toggle $USE_MULTI_PKG)"
if [ "$USE_MULTI_PKG" = "1" ]; then
    log "Package 2        : $PKG2"
fi
log "Discord          : $(show_toggle $DISCORD_ENABLED)"
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
echo ""

# Get active URL
PKG1_ACTIVE_URL=$(get_active_url "$MODE" "$URL")

# Guard: URL kosong untuk mode yang butuh URL
if [ -z "$PKG1_ACTIVE_URL" ] && { [ "$MODE" = "main" ] || [ "$MODE" = "public" ]; }; then
    log "❌ FATAL: URL kosong untuk mode $MODE — config rusak atau URL belum pernah diisi"
    log "   Hapus config dan jalankan ulang: rm ${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
    exit 1
fi

# Join first package dan langsung start monitor
join_server "$PKG1" "$PKG1_ACTIVE_URL" "$MODE" "$PKG1_STATE_DIR"
start_join_timeout "$PKG1" "$PKG1_STATE_DIR" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"

# Open second package if enabled
if [ "$USE_MULTI_PKG" = "1" ]; then
    sleep 2
    open_second_package
    # Init state files PKG2
    if [ -n "$PKG2_STATE_DIR" ]; then
        mkdir -p "$PKG2_STATE_DIR"
        for _F in ingame joining in_background dc_count rc_count lag dc_state left_game; do
            echo "0" > "$PKG2_STATE_DIR/$_F"
        done
        echo "$(date +%s)" > "$PKG2_STATE_DIR/last_relog"
        echo "" > "$PKG2_STATE_DIR/server_ip"
    fi
fi

log "🚀 Ready untuk monitoring"
echo ""

# Start monitors — per-package, PID-filtered logcat
start_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" "$PKG1_STATE_DIR"
log "📡 [$PKG1] Monitor dimulai"

if [ "$USE_MULTI_PKG" = "1" ] && [ -n "$PKG2_STATE_DIR" ]; then
    sleep 2
    start_monitor "$PKG2" "${CONFIG_BASE_DIR}/roblox_config_${PKG2}.cfg" "$PKG2_STATE_DIR"
fi

# Relog periodic loop
while true; do
    # PKG1 relog check
    if [ "${RELOG_SETIAP_JAM:-0}" != "0" ]; then
        _NOW=$(date +%s)
        _LAST=$(cat "$PKG1_STATE_DIR/last_relog" 2>/dev/null | grep -oE "[0-9]+" | head -1)
        _LAST="${_LAST:-0}"
        if [ $((_NOW - _LAST)) -ge $((RELOG_SETIAP_JAM * 3600)) ]; then
            log "🔄 [$PKG1] Relog..."
            source "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" 2>/dev/null
            _URL=$(get_active_url "$MODE" "$URL")
            join_server "$PKG1" "$_URL" "$MODE" "$PKG1_STATE_DIR"
            start_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" "$PKG1_STATE_DIR"
            start_join_timeout "$PKG1" "$PKG1_STATE_DIR" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
