#!/data/data/com.termux/files/usr/bin/bash

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 2.0
# ─────────────────────────────────────────

PKG="com.roblox.client"
CHECK_INTERVAL=10
LOG_FILE="/storage/emulated/0/roblox_reconnect.log"
CONFIG_FILE="/data/local/tmp/roblox_config.cfg"

MODE_MAIN="main"
MODE_MARKET="market"
URL_MARKET="https://www.roblox.com/games/129954712878723/Grow-a-Garden-Trade-World"

STATE_DIR="/data/local/tmp/rbx_state"
FILE_LAST_RECONNECT="$STATE_DIR/last_reconnect"
FILE_IN_BACKGROUND="$STATE_DIR/in_background"
FILE_LAST_RELOG="$STATE_DIR/last_relog"
FILE_RECONNECTING="$STATE_DIR/reconnecting"

RECONNECT_COOLDOWN=45
MONITOR_PID=""
LAST_VERBOSE=0
VERBOSE_INTERVAL=600

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
EOF
}

default_config() {
    URL=""
    MODE="$MODE_MAIN"
    RELOG_SETIAP_JAM=1
    RECONNECT_OTOMATIS=1
    RESTART_KALAU_CRASH=1
    RECONNECT_SAAT_HOME=0
}

# ─────────────────────────────────────────
#   FUNGSI TAMPILAN
# ─────────────────────────────────────────

clr() { clear 2>/dev/null || printf '\033[2J\033[H'; }

header() {
    echo "========================================="
    echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"
    echo "========================================="
}

show_toggle() {
    local val=$1
    if [ "$val" = "1" ]; then echo "ON"; else echo "OFF"; fi
}

show_current_config() {
    local MODE_LABEL
    if [ "$MODE" = "$MODE_MARKET" ]; then
        MODE_LABEL="Market Grow a Garden"
    else
        MODE_LABEL="Grow a Garden (Utama)"
    fi
    echo ""
    echo "  Mode aktif : $MODE_LABEL"
    echo "  URL Main   : ${URL:-[belum diisi]}"
    echo "  URL Market : [hardcoded - Trade World]"
    echo "  Relog  : ${RELOG_SETIAP_JAM} jam $([ "$RELOG_SETIAP_JAM" = "0" ] && echo '(OFF)' || echo '(ON)')"
    echo "  Reconnect otomatis : $(show_toggle $RECONNECT_OTOMATIS)"
    echo "  Restart kalau crash: $(show_toggle $RESTART_KALAU_CRASH)"
    echo "  Reconnect saat home: $(show_toggle $RECONNECT_SAAT_HOME)"
    echo ""
}

# ─────────────────────────────────────────
#   WIZARD SETUP PERTAMA KALI
# ─────────────────────────────────────────

wizard_setup() {
    clr
    header
    echo ""
    echo "  Halo! Config belum ada, mari setup dulu."
    echo ""

    # Pilih mode dulu
    echo "  Mau auto reconnect ke mana?"
    echo "  1) Grow a Garden - Private Server"
    echo "  2) Market Grow a Garden - Public"
    printf "  > "
    read -r INPUT_MODE
    if [ "$INPUT_MODE" = "2" ]; then
        MODE="$MODE_MARKET"
    else
        MODE="$MODE_MAIN"
    fi

    echo ""

    # URL Main — hanya kalau mode main
    if [ "$MODE" = "$MODE_MAIN" ]; then
        while true; do
            echo "  Paste link private server GROW A GARDEN:"
            printf "  > "
            read -r URL
            if [ -n "$URL" ]; then break; fi
            echo "  ⚠ URL tidak boleh kosong!"
            echo ""
        done
        echo ""
    fi

    # Relog
    echo "  Relog otomatis setiap berapa jam?"
    echo "  (ketik 0 untuk mematikan relog otomatis, default: 1)"
    printf "  > "
    read -r INPUT_RELOG
    if [[ "$INPUT_RELOG" =~ ^[0-9]+$ ]]; then
        RELOG_SETIAP_JAM=$INPUT_RELOG
    else
        RELOG_SETIAP_JAM=1
    fi

    echo ""

    # Reconnect
    echo "  Reconnect otomatis saat DC? (1=ON / 0=OFF, default: 1)"
    printf "  > "
    read -r INPUT_RC
    if [ "$INPUT_RC" = "0" ]; then RECONNECT_OTOMATIS=0; else RECONNECT_OTOMATIS=1; fi

    echo ""

    # Crash restart
    echo "  Restart otomatis kalau Roblox crash? (1=ON / 0=OFF, default: 1)"
    printf "  > "
    read -r INPUT_CR
    if [ "$INPUT_CR" = "0" ]; then RESTART_KALAU_CRASH=0; else RESTART_KALAU_CRASH=1; fi

    echo ""

    # Reconnect on home
    echo "  Reconnect saat app di-minimize/home? (1=ON / 0=OFF, default: 0)"
    printf "  > "
    read -r INPUT_RH
    if [ "$INPUT_RH" = "1" ]; then RECONNECT_SAAT_HOME=1; else RECONNECT_SAAT_HOME=0; fi

    save_config

    echo ""
    echo "  ✅ Config tersimpan!"
    echo ""
    sleep 1
}

# ─────────────────────────────────────────
#   MENU UTAMA (kalau config sudah ada)
# ─────────────────────────────────────────

menu_utama() {
    while true; do
        clr
        header
        show_current_config
        echo "  Mau ngapain?"
        echo ""
        echo "  1) Langsung jalanin"
        echo "  2) Ganti mode (main / market)"
        echo "  3) Ganti URL private server"
        echo "  4) Ubah setting (relog, reconnect, dll)"
        echo "  5) Keluar"
        echo ""
        printf "  Pilih (1-5): "
        read -r PILIHAN

        case $PILIHAN in
            1) return 0 ;;
            2) menu_pilih_mode ;;
            3) menu_ganti_url ;;
            4) menu_edit_setting ;;
            5) echo ""; echo "  Sampai jumpa!"; echo ""; exit 0 ;;
            *) echo "  ⚠ Pilih angka 1-5"; sleep 1 ;;
        esac
    done
}

menu_pilih_mode() {
    clr
    header
    echo ""
    echo "  Pilih mode reconnect:"
    echo ""
    echo "  1) Grow a Garden"
    echo "  2) Market Grow a Garden"
    echo "  3) Batal"
    echo ""
    printf "  Pilih (1-3): "
    read -r PILIHAN_MODE

    case $PILIHAN_MODE in
        1)
            MODE="$MODE_MAIN"
            save_config
            echo ""
            echo "  ✅ Mode: Grow a Garden"
            ;;
        2)
            MODE="$MODE_MARKET"
            save_config
            echo ""
            echo "  ✅ Mode: Market Grow a Garden"
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
    echo "  Paste URL baru untuk MAIN (Enter untuk batal):"
    printf "  > "
    read -r NEW_URL
    if [ -n "$NEW_URL" ]; then
        URL="$NEW_URL"
        save_config
        echo ""
        echo "  ✅ URL diperbarui!"
    else
        echo ""
        echo "  Dibatalkan."
    fi
    sleep 1
}

menu_edit_setting() {
    while true; do
        clr
        header
        echo ""
        echo "  ── EDIT SETTING ──────────────────────"
        echo ""
        echo "  1) Relog otomatis : ${RELOG_SETIAP_JAM} jam $([ "$RELOG_SETIAP_JAM" = "0" ] && echo '(OFF)' || echo '(ON)')"
        echo "  2) Reconnect otomatis  : $(show_toggle $RECONNECT_OTOMATIS)"
        echo "  3) Restart kalau crash : $(show_toggle $RESTART_KALAU_CRASH)"
        echo "  4) Reconnect saat home : $(show_toggle $RECONNECT_SAAT_HOME)"
        echo "  5) Kembali ke menu utama"
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
        MODE_LABEL="Market"
    else
        MODE_LABEL="Main"
    fi
    log ""
    log "🚀 Join private server... [Mode: $MODE_LABEL]"
    echo "1" > "$FILE_RECONNECTING"
    am force-stop "$PKG"
    sleep 4
    am start -a android.intent.action.VIEW -d "$ACTIVE_URL" "$PKG"
    log "✅ Private server launched [Mode: $MODE_LABEL]"
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
                break
            fi
        done < <(timeout 90 logcat -v time 2>/dev/null | grep --line-buffered -i "Connection accepted from")

        [ "$FOUND" -eq 0 ] && log "⏱️ Retry timeout - lanjut monitoring..."
    fi

    echo "0" > "$FILE_RECONNECTING"
}

monitor_disconnect() {
    log "🔍 Monitor DC aktif (PID: $$)"
    echo "0" > "$FILE_IN_BACKGROUND"

    while read -r line; do

        if echo "$line" | grep -qi "foregroundActivities=false" && echo "$line" | grep -q "com.roblox.client"; then
            echo "1" > "$FILE_IN_BACKGROUND"
            log "📱 App masuk background"
            continue
        fi

        if echo "$line" | grep -qi "foregroundActivities=true" && echo "$line" | grep -q "com.roblox.client"; then
            sleep 5
            echo "0" > "$FILE_IN_BACKGROUND"
            log "📱 App kembali foreground"
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
log "Mode             : $([ "$MODE" = "$MODE_MARKET" ] && echo 'Market Grow a Garden' || echo 'Grow a Garden (Utama)')"
log "URL aktif        : $(get_active_url)"
log "Relog            : setiap ${RELOG_SETIAP_JAM} jam    → $([ "$RELOG_SETIAP_JAM" = "0" ] && echo OFF || echo ON)"
log "Reconnect        : DC detection  → $(show_toggle $RECONNECT_OTOMATIS)"
log "Restart crash    : auto restart  → $(show_toggle $RESTART_KALAU_CRASH)"
log "Reconnect@home   : saat home     → $(show_toggle $RECONNECT_SAAT_HOME)"
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
            sleep 3
            join_private_server
            wait_for_ingame
            start_monitor
            continue
        fi
    fi

    if check_relog_needed; then
        log "🔄 Relog setiap ${RELOG_SETIAP_JAM} jam..."
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
