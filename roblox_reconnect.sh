#!/data/data/com.termux/files/usr/bin/bash

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 3.0 (+ Error Code Disconnect Detector)
#   Perbaikan (3.0): - Fitur baru: error_code_monitor() — deteksi kode
#                error disconnect Roblox (272/273/274/275/277/278/279/282)
#                via logcat, lalu auto-rejoin. Ini beda dari crash_monitor:
#                error code muncul saat KONEKSI ke server Roblox putus
#                (internet lag/putus, server issue) — app-nya sendiri
#                BELUM TENTU mati/hilang PID-nya, jadi butuh detector
#                terpisah yang tidak nunggu PID hilang dulu.
#              - Toggle baru per-package: DETEKSI_ERROR_CODE (default ON),
#                bisa di-ubah lewat menu "Ubah setting".
#              - Kenapa logcat, bukan OCR screen: dialog error Roblox
#                di-render di dalam game engine sendiri (GL surface),
#                BUKAN native Android View — jadi `uiautomator dump`
#                (baca teks dari accessibility tree) tidak akan bisa
#                "melihat" teks itu sama sekali. Opsi yang tersisa cuma
#                screenshot + OCR (tesseract), yang jauh lebih berat &
#                rapuh (tergantung resolusi/font/posisi dialog) dibanding
#                logcat yang sudah jadi fondasi semua detector lain di
#                script ini. Kalau nanti terbukti kode errornya TIDAK
#                muncul di logcat sama sekali di device kamu, screenshot+
#                OCR jadi fallback yang bisa ditambahkan belakangan.
#   ---
#   versi: 2.9 (Fix False-Positive Crash dari Sub-Process Roblox)
#   Perbaikan: - JOIN LOCK: crash_monitor & logcat_detector skip saat proses join
#              - wait_ingame: fallback PID+dumpsys, tidak hanya "Connection accepted"
#              - join_server: am start diperbaiki (-p flag) + JOIN_LOCK set/release
#              - Discord: full Embed (color, fields, thumbnail, footer)
#              - Bug fix: menu_edit_settings_pkg pilihan 3 argumen salah (extra $cur_restart)
#              - Discord: embed diubah ke layout "Sphinx Status Update"
#                (title tetap, description markdown + divider + emoji,
#                 thumbnail & footer icon logo Sphinx)
#              - Bug fix: JOIN LOCK basi di tengah loading Private Server
#                (lock tidak pernah di-refresh → expired sebelum join selesai
#                → crash_monitor salah kill proses yang sebenarnya sehat).
#                Sekarang lock direfresh aktif di wait_ingame +
#                verify_ingame_stable, JOIN_LOCK_TIMEOUT 180→240s, dan
#                miss_count crash_monitor 2→3 sebagai buffer tambahan.
#              - ROOT CAUSE FIX crash Private Server (double-launch):
#                join_server sebelumnya pakai `am start -p pkg || am start`
#                — exit code am start TIDAK KONSISTEN, sering bikin `||`
#                menembak am start KEDUA tepat setelah yang pertama, app
#                kelihatan blank/close sebentar. Diganti pakai
#                get_view_activity() untuk resolve component -n pkg/activity
#                secara deterministik — cuma SATU am start.
#              - ROOT CAUSE FIX crash loop pasca-join (logcat backlog
#                replay): logcat_crash_detector & monitor_events sebelumnya
#                panggil `logcat -b crash -b main` TANPA filter waktu (-T).
#                Tanpa -T, logcat SELALU dump SELURUH buffer historis dulu
#                (ribuan baris sejak boot) sebelum streaming live — termasuk
#                tombstone/native-crash LAMA yang sudah lama selesai. Proses
#                "mengunyah" backlog itu makan waktu nyata & kebetulan
#                bertepatan dengan event lain (mis. verify_ingame_stable
#                selesai) → kelihatan seperti crash baru padahal cuma entry
#                lama. Tiap restart pipe = backlog terbaca ulang = loop
#                tak berkesudahan. FIX: -T "$(date ...)" di-generate ULANG
#                tiap iterasi outer loop, jadi logcat cuma kasih baris BARU.
#              - Fitur SPLIT SCREEN dihapus sepenuhnya (try_split_screen,
#                SPLIT_ENABLED, embed case "split", menu text) — PKG2
#                sekarang SELALU pakai floating/freeform window langsung,
#                tanpa percobaan split screen dulu.
#              - ROOT CAUSE FIX "black screen" saat loading Private Server
#                BERAT (mis. Grow a Garden): Roblox pakai arsitektur MULTI-
#                PROCESS — ada sub-process terpisah (mis. "pkg:renderer",
#                "pkg:sandboxed_process0") yang wajar mati/restart sendiri
#                saat loading asset berat, BUKAN crash fatal. Regex crash
#                logcat_crash_detector pakai SUBSTRING match, jadi baris
#                seperti "Process com.roblox.client:renderer has died" ikut
#                ke-match walau yang mati cuma sub-process — script SALAH
#                force-stop app yang SEBENARNYA SEHAT (black screen yang
#                user lihat = ulah script sendiri, bukan Roblox crash asli).
#                FIX 2 lapis: (1) abaikan baris log yang jelas menyebut
#                proses ber-suffix ":nama" setelah nama package, (2) SEBELUM
#                bertindak, cross-verify PID utama via get_pid_for_pkg()
#                (exact-match, sudah aman dari sub-process) — kalau PID
#                utama masih hidup & sehat, sinyal crash logcat diabaikan,
#                tidak ada force-stop.
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

# Discord
DISCORD_WEBHOOK=""
DISCORD_USER_ID=""
DISCORD_ENABLED=0

# Clone detection
IS_CLONE_APP=""
DETECTED_USER_ID=""

# Multi package (kedua akun/app dijalankan bersamaan via floating window)
USE_MULTI_PKG=0

# Join lock — cegah crash_monitor/logcat_detector intervensi saat proses join
JOIN_LOCK_DIR="${STATE_BASE_DIR}"
# BUG FIX: 180 → 240. Lock sekarang di-refresh aktif tiap iterasi selama
# wait_ingame/verify_ingame_stable berjalan (lihat fungsi terkait), jadi nilai
# ini murni jadi "safety ceiling" kalau proses join benar-benar hang/macet —
# 240s ngasih buffer ekstra untuk private server berat yang loadingnya lama.
JOIN_LOCK_TIMEOUT=240   # detik — maks waktu loading private server sebelum lock dianggap hang

# ─────────────────────────────────────────
#   ERROR CODE DISCONNECT (auto-rejoin)
# ─────────────────────────────────────────
# Kode error Roblox yang muncul di dialog "Disconnected" saat koneksi ke
# server putus (internet lag/putus, network error, server issue, dll) —
# BUKAN app crash (PID biasanya masih hidup), makanya butuh detector
# sendiri (error_code_monitor), terpisah dari crash_monitor/logcat_crash_detector.
ERROR_CODE_LIST="272|273|274|275|277|278|279|282"

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

    # BUG FIX: operator harus && bukan ||
    # Sebelumnya: [ != "1" ] || [ -z ] → return bahkan saat enabled+webhook diisi
    [ "$DISCORD_ENABLED" = "1" ] || return
    [ -n "$DISCORD_WEBHOOK" ] || return

    # Jalankan seluruh proses di background subshell agar tidak block monitor
    (
    # ── Collect system stats ───────────────────────────────────────────────
    local timestamp device cpu ram_free ram_free_pct temp

    timestamp=$(date '+%d/%m/%Y %H:%M:%S')
    device=$(getprop ro.product.model 2>/dev/null || echo "Unknown")

    local nproc_n
    nproc_n=$(nproc 2>/dev/null \
        || grep -c "^processor" /proc/cpuinfo 2>/dev/null \
        || echo 1)
    cpu=$(awk -v n="$nproc_n" '{printf "%.0f", ($1 * 100) / n}' \
        /proc/loadavg 2>/dev/null || echo "N/A")

    ram_free=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' \
        /proc/meminfo 2>/dev/null || echo "N/A")
    ram_free_pct=$(awk \
        '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "%.0f",a*100/t;else print "N/A"}' \
        /proc/meminfo 2>/dev/null || echo "N/A")

    temp="N/A"
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$zone" ] || continue
        local raw; raw=$(cat "$zone" 2>/dev/null)
        [ -n "$raw" ] && [ "$raw" -gt 20000 ] && [ "$raw" -lt 85000 ] && {
            temp=$(( raw / 1000 )); break
        }
    done

    # ── App-specific stats: uptime proses, RSS memory, CPU (load avg) ──────
    # ⏱️ Uptime  : dihitung dari starttime proses (/proc/PID/stat field 22)
    #              dibanding /proc/uptime — jadi murni "sejak proses OS start",
    #              bukan sejak reconnect/join terakhir.
    # 💾 Memory  : VmRSS dari /proc/PID/status (RAM nyata yang dipakai proses).
    # ⚡ CPU     : formula sama dengan System Stats (load avg device), cuma
    #              presisi 1 desimal biar match tampilan referensi.
    local app_pid app_uptime app_rss_mb app_cpu
    app_pid=$(get_pid_for_pkg "$pkg")

    app_uptime="N/A"
    if [ -n "$app_pid" ] && [ -f "/proc/$app_pid/stat" ]; then
        local clk_tck sys_uptime start_ticks start_sec elapsed_sec
        clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
        sys_uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)
        start_ticks=$(awk '{print $22}' "/proc/$app_pid/stat" 2>/dev/null)
        if [ -n "$sys_uptime" ] && [ -n "$start_ticks" ] && [ "${clk_tck:-0}" -gt 0 ] 2>/dev/null; then
            start_sec=$(awk -v t="$start_ticks" -v c="$clk_tck" 'BEGIN{printf "%.0f", t/c}')
            elapsed_sec=$(awk -v s="$sys_uptime" -v st="$start_sec" 'BEGIN{d=s-st; if(d<0)d=0; printf "%.0f", d}')
            app_uptime=$(awk -v s="$elapsed_sec" 'BEGIN{
                h=int(s/3600); m=int((s%3600)/60); sec=s%60;
                printf "%02d:%02d:%02d", h, m, sec
            }')
        fi
    fi

    app_rss_mb="N/A"
    if [ -n "$app_pid" ] && [ -f "/proc/$app_pid/status" ]; then
        local rss_kb
        rss_kb=$(grep -m1 "^VmRSS:" "/proc/$app_pid/status" 2>/dev/null | awk '{print $2}')
        [ -n "$rss_kb" ] && app_rss_mb=$(awk -v k="$rss_kb" 'BEGIN{printf "%.1f", k/1024}')
    fi

    app_cpu=$(awk -v n="$nproc_n" '{printf "%.1f", ($1 * 100) / n}' \
        /proc/loadavg 2>/dev/null || echo "N/A")

    # ── Status per event type ─────────────────────────────────────────────
    local embed_color app_icon app_status online_c offline_c
    case $event_type in
        "reconnect_success")
            embed_color=3066993
            app_icon="🟢"; app_status="Online"
            online_c=1; offline_c=0 ;;
        "disconnect")
            embed_color=15158332
            app_icon="🔴"; app_status="Offline"
            online_c=0; offline_c=1 ;;
        "crash")
            embed_color=10038562
            app_icon="🔴"; app_status="Crashed"
            online_c=0; offline_c=1 ;;
        "relog")
            embed_color=16776960
            app_icon="🔄"; app_status="Re-logging"
            online_c=0; offline_c=1 ;;
        "floating")
            embed_color=3447003
            app_icon="📱"; app_status="Multi-Window"
            online_c=1; offline_c=0 ;;
        *)
            embed_color=9807270
            app_icon="🟡"; app_status="${event_type}"
            online_c=0; offline_c=0 ;;
    esac
    local total_c=$(( online_c + offline_c ))

    # ── Timestamp: ISO (embed), format panjang (Last Updated), footer ────
    local iso_ts last_updated footer_ts
    iso_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    last_updated=$(date '+%B %d, %Y %I:%M %p' 2>/dev/null || echo "$timestamp")
    footer_ts="${timestamp%:*}"   # buang detik: "DD/MM/YYYY HH:MM:SS" -> "DD/MM/YYYY HH:MM"

    # ── Helper escape JSON ────────────────────────────────────────────────
    # BUG FIX: definisikan di scope subshell ini (bukan di dalam heredoc)
    _jesc() {
        printf '%s' "$1" \
            | sed 's/\\/\\\\/g' \
            | sed 's/"/\\"/g' \
            | awk '{if(NR>1)printf "\\n"; printf "%s",$0}'
    }

    local esc_pkg esc_device esc_status esc_ts esc_mention esc_last_updated esc_footer_ts
    esc_pkg=$(_jesc "$pkg")
    esc_device=$(_jesc "$device")
    esc_status=$(_jesc "$app_status")
    esc_ts=$(_jesc "$timestamp")
    esc_last_updated=$(_jesc "$last_updated")
    esc_footer_ts=$(_jesc "$footer_ts")

    local mention_str=""
    [ -n "$DISCORD_USER_ID" ] && mention_str="<@${DISCORD_USER_ID}>"
    esc_mention=$(_jesc "$mention_str")

    # ── Aset visual "Sphinx Status Update" ────────────────────────────────
    local sphinx_icon_url="https://raw.githubusercontent.com/wardz25/updater/main/sphinx.png"
    local divider="────────────────────"

    # ── Susun description — layout disamakan 1:1 dengan referensi "Sphinx
    #    Status Update": Last Updated, Device, System Stats, Status
    #    Overview, Application Details, dipisah garis divider.
    #    (bukan lagi pakai "fields" Discord — semua jadi satu blok markdown)
    local description
    description="**Last Updated:** ${esc_last_updated} (just now)\n\n"
    description+="📱 **Device** \`${esc_device}\`\n"
    description+="${divider}\n"
    description+="🖥️ **System Stats**\n"
    description+="⚡ CPU: **${cpu}%**\n"
    description+="💾 RAM: **${ram_free}MB** free (${ram_free_pct}%)\n"
    description+="🌡️ Temp: **${temp}°C**\n"
    description+="${divider}\n"
    description+="📊 **Status Overview**\n"
    description+="🟢 Online: **${online_c}**  ⋮  🔴 Offline: **${offline_c}**  ⋮  👤 Total: **${total_c}**\n"
    description+="${divider}\n"
    description+="📦 **Application Details**\n"
    description+="${app_icon} ||${esc_pkg}|| — ${esc_status}\n"
    description+="⏱️ ${app_uptime} | 💾 ${app_rss_mb}MB | ⚡ ${app_cpu}%"

    # ── Build JSON dengan printf ──────────────────────────────────────────
    # BUG FIX: heredoc multiline menyebabkan payload corrupt saat di-pass ke curl.
    # printf memberikan kontrol penuh — output dijamin satu string tanpa newline liar.
    local payload
    payload=$(printf '{"username":"Sphinx Monitor","avatar_url":"%s","content":"%s","embeds":[{"title":"📊 Sphinx Status Update","description":"%s","color":%d,"timestamp":"%s","thumbnail":{"url":"%s"},"footer":{"text":"Sphinx Monitor • %s • %s","icon_url":"%s"}}]}' \
        "$sphinx_icon_url" \
        "$esc_mention" \
        "$description" \
        "$embed_color" \
        "$iso_ts" \
        "$sphinx_icon_url" \
        "$esc_device" "$esc_footer_ts" \
        "$sphinx_icon_url")

    # ── Kirim via temp file — hindari shell expansion corrupt payload ─────
    # BUG FIX: curl -d "$payload" gagal jika payload mengandung newline/spasi
    # khusus. --data-binary @file memastikan payload dikirim apa adanya.
    local tmp_payload
    tmp_payload=$(mktemp /data/local/tmp/rbx_discord_XXXXXX 2>/dev/null \
        || mktemp /tmp/rbx_discord_XXXXXX 2>/dev/null)

    if [ -n "$tmp_payload" ]; then
        printf '%s' "$payload" > "$tmp_payload"
        curl -s -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            --data-binary "@${tmp_payload}" \
            -o /dev/null 2>/dev/null
        rm -f "$tmp_payload" 2>/dev/null
    fi
    ) &
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
    local error_code=${9:-1}

    # BUG FIX: Discord setup terjadi SETELAH package setup.
    # Kalau save_config dipanggil dari wizard/menu sebelum Discord diinput
    # (globals masih kosong), webhook yang sudah tersimpan bakal ketimpa "".
    # Solusi: baca dari file dulu jika global kosong.
    local disc_enabled="${DISCORD_ENABLED:-0}"
    local disc_webhook="${DISCORD_WEBHOOK}"
    local disc_uid="${DISCORD_USER_ID}"

    if [ -z "$disc_webhook" ] && [ -f "$cfg_file" ]; then
        disc_enabled=$(grep '^DISCORD_ENABLED=' "$cfg_file" | head -1 | cut -d= -f2)
        disc_webhook=$(grep '^DISCORD_WEBHOOK=' "$cfg_file" | head -1 | cut -d'"' -f2)
        disc_uid=$(grep '^DISCORD_USER_ID=' "$cfg_file" | head -1 | cut -d'"' -f2)
    fi

    cat > "$cfg_file" <<EOF
# Config untuk: $pkg

URL="$url"
MODE="$mode"
RELOG_SETIAP_JAM=$relog
RECONNECT_OTOMATIS=$reconnect
RESTART_KALAU_CRASH=$restart
RECONNECT_SAAT_HOME=$home
DETEKSI_ERROR_CODE=$error_code
DISCORD_ENABLED=${disc_enabled:-0}
DISCORD_WEBHOOK="${disc_webhook}"
DISCORD_USER_ID="${disc_uid}"
EOF
}

persist_discord_settings() {
    local cfg_file=$1
    local pkg=$2
    local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home saved_error_code

    if [ -f "$cfg_file" ]; then
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
    fi

    save_config "$cfg_file" "$pkg" "$saved_url" "$saved_mode" \
        "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home" \
        "${saved_error_code:-1}"
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
    local url=$1
    echo "$url" | grep -qE '^https://(discord|discordapp)\.com/api/webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{60,90}(\?[A-Za-z0-9_=&-]*)?$'
}

# ─────────────────────────────────────────
#   VALIDASI LIVE — cek webhook ke server Discord asli
# ─────────────────────────────────────────
# validate_discord_webhook() di atas cuma cek FORMAT (regex) — URL bisa
# aja formatnya benar tapi webhook-nya sendiri sudah dihapus/direset di
# Discord (mis. channel dihapus, integrasi di-revoke). Fungsi ini nembak
# GET ke endpoint webhook itu sendiri: Discord balas 200 kalau valid &
# masih aktif, 404/401 kalau sudah tidak valid.
check_discord_webhook_live() {
    local url=$1
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 8 -m 12 "$url" 2>/dev/null)
    echo "${http_code:-000}"
}

# Loop input webhook: validasi format DULU (looping sampai bener/batal),
# baru setelah format lolos, cek live ke Discord. Hasil akhir (webhook
# yang mau dipakai) ditaruh ke variabel dengan nama $1 (indirect, sama
# gaya kayak setup_mode_and_url()). Return 0 = ada webhook yang disimpan,
# return 1 = user ketik "batal".
prompt_discord_webhook() {
    local var_name=$1

    while true; do
        echo ""
        echo "  Paste webhook URL Discord:"
        echo "  Contoh: https://discord.com/api/webhooks/123456789012345678/AbCdEf..."
        echo "  (ketik 'batal' untuk skip)"
        printf "  > "
        local input_webhook
        read -r input_webhook

        if [ "$input_webhook" = "batal" ]; then
            return 1
        fi

        if [ -z "$input_webhook" ]; then
            echo "  ⚠ URL tidak boleh kosong!"
            continue
        fi

        if ! validate_discord_webhook "$input_webhook"; then
            echo "  ⚠ Format salah! Harus: https://discord.com/api/webhooks/{id}/{token}"
            continue
        fi

        echo "  🔎 Mengecek webhook ke Discord..."
        local http_code
        http_code=$(check_discord_webhook_live "$input_webhook")

        case "$http_code" in
            200)
                echo "  ✅ Webhook valid & aktif!"
                printf -v "$var_name" '%s' "$input_webhook"
                return 0
                ;;
            401|404)
                echo "  ⚠ Format URL benar, tapi Discord MENOLAK webhook ini"
                echo "     (kemungkinan sudah dihapus/direset di sisi Discord)."
                echo "  1) Masukkan ulang   2) Tetap pakai ini"
                printf "  Pilih (1/2): "
                local force
                read -r force
                if [ "$force" = "2" ]; then
                    printf -v "$var_name" '%s' "$input_webhook"
                    return 0
                fi
                ;;
            000|"")
                echo "  ⚠ Gagal konek ke Discord (cek internet/data seluler)."
                echo "     Format URL sudah benar — disimpan tanpa verifikasi live."
                printf -v "$var_name" '%s' "$input_webhook"
                return 0
                ;;
            *)
                echo "  ⚠ Discord merespons kode $http_code (tidak terduga) — format OK,"
                echo "     disimpan tanpa verifikasi live."
                printf -v "$var_name" '%s' "$input_webhook"
                return 0
                ;;
        esac
    done
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
    local error_code=${7:-1}
    
    echo ""
    echo "  Mode aktif  : $(get_mode_label $mode)"
    echo "  URL         : ${url:-[belum diisi]}"
    echo "  Relog       : ${relog} jam $([ "$relog" = "0" ] && echo '(OFF)' || echo '(ON)')"
    echo "  Reconnect   : $(show_toggle $reconnect)"
    echo "  Restart     : $(show_toggle $restart)"
    echo "  Home RC     : $(show_toggle $home)"
    echo "  Error Code  : $(show_toggle $error_code)"
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
    
    local mode url relog reconnect restart home error_code
    
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
    echo "  Reconnect saat home? (1=ON, 0=OFF, default: 0)"
    printf "  > "
    read -r home
    if [ "$home" != "1" ]; then home=0; fi
    
    echo ""
    echo "  Deteksi Error Code disconnect (internet putus/lag)?"
    echo "  Auto-rejoin kalau muncul Error Code: 272/273/274/275/277/278/279/282"
    echo "  (1=ON, 0=OFF, default: 1)"
    printf "  > "
    read -r error_code
    if [ "$error_code" != "0" ]; then error_code=1; fi
    
    # Save
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    save_config "$cfg_file" "$pkg" "$url" "$mode" "$relog" "$reconnect" "$restart" "$home" "$error_code"
    
    echo ""
    echo "  ✅ Config Package $pkg_num tersimpan!"
    sleep 2
}

menu_ganti_url_mode_pkg() {
    local pkg=$1
    local pkg_num=$2
    local cfg_file=$3

    local keep_relog keep_reconnect keep_restart keep_home keep_error_code
    keep_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)

    local new_mode new_url
    setup_mode_and_url "Ganti Mode & URL — Package $pkg_num ($pkg)" new_mode new_url

    # BUG FIX: user pilih "5) Kembali" → setup_mode_and_url return 1
    # Sebelumnya save_config tetap dipanggil dengan new_mode="" → MODE="Unknown"
    [ $? -ne 0 ] && return

    save_config "$cfg_file" "$pkg" "$new_url" "$new_mode" \
        "$keep_relog" "$keep_reconnect" "$keep_restart" "$keep_home" \
        "${keep_error_code:-1}"

    echo ""
    echo "  ✅ Mode & URL diupdate, setting lain tetap."
    sleep 1
}

menu_edit_settings_pkg() {
    local pkg=$1
    local cfg_file=$2

    while true; do
        local cur_url cur_mode cur_relog cur_reconnect cur_restart cur_home cur_error_code
        cur_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_error_code="${cur_error_code:-1}"

        clr
        header
        echo ""
        echo "  ⚙️ UBAH SETTING — $pkg"
        show_current_config "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" "$cur_error_code"
        echo "  1) Relog interval        (sekarang: ${cur_relog} jam)"
        echo "  2) Reconnect otomatis    (sekarang: $(show_toggle $cur_reconnect))"
        echo "  3) Restart kalau crash   (sekarang: $(show_toggle $cur_restart))"
        echo "  4) Reconnect saat home   (sekarang: $(show_toggle $cur_home))"
        echo "  5) Deteksi Error Code    (sekarang: $(show_toggle $cur_error_code))"
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
                    save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$V" "$cur_reconnect" "$cur_restart" "$cur_home" "$cur_error_code"
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan angka!"
                fi
                sleep 1
                ;;
            2)
                local new_val; new_val=$([ "$cur_reconnect" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$new_val" "$cur_restart" "$cur_home" "$cur_error_code"
                echo "  ✅ Reconnect: $(show_toggle $new_val)"
                sleep 1
                ;;
            3)
                local new_val; new_val=$([ "$cur_restart" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$new_val" "$cur_home" "$cur_error_code"
                echo "  ✅ Restart: $(show_toggle $new_val)"
                sleep 1
                ;;
            4)
                local new_val; new_val=$([ "$cur_home" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$new_val" "$cur_error_code"
                echo "  ✅ Home RC: $(show_toggle $new_val)"
                sleep 1
                ;;
            5)
                local new_val; new_val=$([ "$cur_error_code" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" "$new_val"
                echo "  ✅ Deteksi Error Code: $(show_toggle $new_val)"
                sleep 1
                ;;
            6) return ;;
            *) echo "  ⚠ Pilih 1-6"; sleep 1 ;;
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

    while true; do
        local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home saved_error_code
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code="${saved_error_code:-1}"

        clr
        header
        echo ""
        echo "  📦 Config Package $pkg_num ($pkg) ditemukan dari run sebelumnya:"
        show_current_config "$saved_url" "$saved_mode" "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home" "$saved_error_code"
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
            if prompt_discord_webhook DISCORD_WEBHOOK; then
                DISCORD_ENABLED=1
                echo "  ✅ Webhook updated!"
            else
                echo "  ℹ️ Dibatalkan — webhook tidak diubah."
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
#   FLOATING WINDOW (Split screen dihapus — freeform only)
# ─────────────────────────────────────────

# Fungsi untuk mendapatkan activity yang menangani intent VIEW untuk package tertentu
get_view_activity() {
    local pkg="$1"
    local url="$2"
    local activity=""

    # Coba resolve-activity dengan cmd package (Android 8+)
    if command -v cmd >/dev/null 2>&1; then
        activity=$(cmd package resolve-activity --brief -a android.intent.action.VIEW -d "$url" 2>/dev/null | grep "$pkg/" | head -1)
        if [ -n "$activity" ]; then
            echo "$activity"
            return
        fi
    fi

    # Fallback: cari dari dumpsys package
    activity=$(dumpsys package "$pkg" 2>/dev/null | grep -A20 "android.intent.action.VIEW" | grep -oE "$pkg/[^ ]+" | head -1)
    if [ -n "$activity" ]; then
        echo "$activity"
        return
    fi

    # Fallback hardcoded (activity umum Roblox)
    echo "$pkg/com.roblox.client.RobloxActivity"
}

check_windowing_mode() {
    local pkg=$1
    # Ambil windowingMode dari dumpsys dengan konteks yang lebih akurat
    dumpsys activity activities 2>/dev/null | grep -A10 "package=$pkg" | grep -oE "windowingMode=[0-9]+" | head -1
}

try_floating_window() {
    local pkg2=$1
    local url2=$2

    log "🪟 Membuka floating/freeform window (windowingMode=5) untuk: $pkg2"

    local activity
    activity=$(get_view_activity "$pkg2" "$url2")
    log "🔍 Menggunakan activity: $activity"

    { am start -a android.intent.action.VIEW -d "$url2" -n "$activity" -f 0x10000000 --windowingMode 5 </dev/null >/dev/null 2>&1; }
    sleep 3

    local actual_mode
    actual_mode=$(check_windowing_mode "$pkg2")

    if echo "$actual_mode" | grep -q "windowingMode=5"; then
        log "✅ Freeform window berhasil ($actual_mode)"
    else
        log "⚠️ Device tidak support freeform — $pkg2 kemungkinan terbuka fullscreen (status: ${actual_mode:-tidak terdeteksi})"
    fi

    send_discord_notification "floating" "$pkg2" "$PKG1"
    return 0
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

# ─────────────────────────────────────────
#   GET PID FOR PACKAGE (was undefined — BUG FIX)
# ─────────────────────────────────────────

get_pid_for_pkg() {
    local pkg=$1
    local pid=""

    # Method 1: pidof (tersedia di Android 8+)
    pid=$(pidof "$pkg" 2>/dev/null | awk '{print $1}')
    [ -n "$pid" ] && { echo "$pid"; return; }

    # Method 2: ps -A dengan awk exact match di kolom NAME
    pid=$(ps -A 2>/dev/null \
        | awk '{print $2, $NF}' \
        | grep " ${pkg}$" \
        | awk '{print $1}' \
        | head -1)
    [ -n "$pid" ] && { echo "$pid"; return; }

    # Method 3: scan /proc/*/cmdline (paling akurat, butuh root)
    for f in /proc/[0-9]*/cmdline; do
        local p="${f%/cmdline}"
        p="${p##*/}"
        local cmd
        cmd=$(cat "$f" 2>/dev/null | tr '\0' '\n' | head -1)
        if [ "$cmd" = "$pkg" ]; then
            pid="$p"
            break
        fi
    done
    [ -n "$pid" ] && { echo "$pid"; return; }

    echo ""
}

# ─────────────────────────────────────────
#   CRASH LOCK — cegah double-handle dari crash_monitor + logcat_detector
# ─────────────────────────────────────────

acquire_crash_lock() {
    local pkg=$1
    local lock_file="${STATE_BASE_DIR}/rbx_state_${pkg}/crash_lock"
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null

    if [ -f "$lock_file" ]; then
        local lock_age now mtime
        now=$(date +%s)
        mtime=$(stat -c %Y "$lock_file" 2>/dev/null || echo 0)
        lock_age=$(( now - mtime ))
        # Lock masih fresh (< 3 menit) → skip, biarkan handler lain yang jalan
        if [ "$lock_age" -lt 180 ]; then
            return 1
        fi
    fi

    echo $$ > "$lock_file"
    return 0
}

release_crash_lock() {
    local pkg=$1
    local lock_file="${STATE_BASE_DIR}/rbx_state_${pkg}/crash_lock"
    rm -f "$lock_file" 2>/dev/null
}

# ─────────────────────────────────────────
#   JOIN LOCK — cegah crash_monitor/logcat_detector
#   intervensi saat proses join/loading berlangsung
# ─────────────────────────────────────────

acquire_join_lock() {
    local pkg=$1
    local lock_file="${STATE_BASE_DIR}/rbx_state_${pkg}/join_lock"
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null
    echo $$ > "$lock_file"
}

release_join_lock() {
    local pkg=$1
    local lock_file="${STATE_BASE_DIR}/rbx_state_${pkg}/join_lock"
    rm -f "$lock_file" 2>/dev/null
}

is_joining() {
    # Return 0 (true) kalau join lock aktif dan masih fresh
    local pkg=$1
    local lock_file="${STATE_BASE_DIR}/rbx_state_${pkg}/join_lock"
    [ -f "$lock_file" ] || return 1

    local now mtime lock_age
    now=$(date +%s)
    mtime=$(stat -c %Y "$lock_file" 2>/dev/null || echo 0)
    lock_age=$(( now - mtime ))

    # Lock expired (> JOIN_LOCK_TIMEOUT) = proses join hang / stuck → anggap sudah selesai
    if [ "$lock_age" -gt "${JOIN_LOCK_TIMEOUT:-180}" ]; then
        rm -f "$lock_file" 2>/dev/null
        return 1
    fi
    return 0
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

    # Set JOIN LOCK sebelum force-stop agar crash_monitor tidak intervensi
    # selama proses loading berlangsung
    acquire_join_lock "$pkg"

    am force-stop "$pkg"
    sleep 3

    # BUG FIX (root cause "crash" di Private Server): SEBELUMNYA pakai
    #   am start ... -p "$pkg" 2>/dev/null || am start ... 2>/dev/null
    # `am start` exit code TIDAK KONSISTEN antar Android/ROM — untuk intent
    # dengan skema "roblox://" (private server share_link), Android sering
    # print "Warning: Activity not started, its current task has been
    # brought to the front" dan itu bikin exit code dibaca non-zero PADAHAL
    # app sudah berhasil launch. Akibatnya `||` menembak am start KEDUA
    # tepat setelah yang pertama — Activity yang baru mulai init kena
    # restart/replace oleh instance kedua → app keliatan blank/close
    # sebentar (persis dilaporkan). Public server (URL https://) jarang
    # kena karena skemanya lebih konsisten di-resolve dengan -p.
    #
    # FIX: resolve activity spesifik SEKALI pakai get_view_activity (fungsi
    # yang sama yang dipakai & terbukti stabil di try_floating_window),
    # lalu -n pkg/activity — deterministik, cuma SATU
    # am start, tidak ada lagi gambling exit code / double-launch.
    local activity
    activity=$(get_view_activity "$pkg" "$url")

    { am start -a android.intent.action.VIEW -d "$url" -n "$activity" </dev/null >/dev/null 2>&1; }

    log "🚀 Joining Server"
}

wait_ingame() {
    local pkg=$1
    log "👀 Menunggu INGAME..."

    # JOIN LOCK harus aktif saat wait_ingame (dipasang oleh join_server).
    # Jika belum, pasang sekarang sebagai safety net.
    is_joining "$pkg" || acquire_join_lock "$pkg"

    # ── Metode 1: Tunggu "Connection accepted" via logcat (max 120s) ─────
    # Private server memerlukan loading lebih lama dari public server.
    local tmp_ip
    tmp_ip=$(timeout 120 logcat -b main -b system -v time 2>/dev/null \
        | grep --line-buffered -iE "Connection accepted from|NetworkClient.*connected|RobloxNetworkHandler.*Join" \
        | head -1 \
        | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" \
        | head -1)

    if [ -n "$tmp_ip" ]; then
        log "✅ INGAME via logcat! IP: $tmp_ip"
        send_discord_notification "reconnect_success" "IP: $tmp_ip" "$pkg"
        release_join_lock "$pkg"
        return
    fi

    # ── Metode 2: Fallback — cek PID hidup + activity foreground ─────────
    # BUG FIX: refresh join lock di sini. Metode 1 sendirian bisa makan ~120s,
    # kalau ditambah metode 2 (~60s) totalnya pas/lewat JOIN_LOCK_TIMEOUT lama
    # (180s) — apalagi kalau device lagi berat (CPU tinggi, private server
    # berat). Lock basi = crash_monitor/logcat_detector aktif lagi DI TENGAH
    # loading yang masih wajar → PID hilang sesaat (Roblox restart proses
    # internal saat pindah ke private server) kebaca CRASH → am force-stop
    # proses yang sebenarnya masih sehat/berhasil join.
    log "⏱️ logcat timeout — fallback cek PID & activity..."
    acquire_join_lock "$pkg"   # refresh sebelum mulai fallback
    local waited=0
    while [ $waited -lt 30 ]; do
        sleep 2
        waited=$(( waited + 2 ))
        acquire_join_lock "$pkg"   # refresh tiap iterasi — cegah lock basi selagi masih nunggu

        local pid
        pid=$(get_pid_for_pkg "$pkg")
        local alive=0

        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            local state
            state=$(grep -m1 "^State:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            if [ "$state" != "Z" ] && [ "$state" != "X" ]; then
                local cmdline
                cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr -d '\0')
                echo "$cmdline" | grep -q "$pkg" && alive=1
            fi
        fi

        # Juga cek activity foreground sebagai konfirmasi tambahan
        if [ "$alive" = "1" ]; then
            if dumpsys activity top 2>/dev/null | grep -q "ACTIVITY ${pkg}"; then
                log "✅ INGAME via PID+Activity (fallback)"
                send_discord_notification "reconnect_success" "Joined (fallback detect)" "$pkg"
                release_join_lock "$pkg"
                return
            fi
        fi
    done

    log "⚠️ INGAME tidak terdeteksi setelah timeout — lanjut (join lock dilepas)"
    release_join_lock "$pkg"
}

verify_ingame_stable() {
    local pkg=$1
    local cfg_file=$2
    local checks=0
    local max_rejoin=3
    local rejoin_count=0

    # JOIN LOCK wajib aktif selama fase verify ini.
    # wait_ingame sudah release join_lock saat berhasil detect — kita pasang ulang
    # karena verify ini masih bagian dari proses join (belum aman untuk crash_monitor).
    acquire_join_lock "$pkg"

    log "🔁 Tight-monitor 20s pasca-join (join lock aktif)..."
    while [ $checks -lt 20 ]; do
        sleep 1
        acquire_join_lock "$pkg"   # refresh — jaga lock tetap fresh selama tight-monitor
        local main_pid
        main_pid=$(get_pid_for_pkg "$pkg")
        local alive=0

        if [ -n "$main_pid" ] && [ -d "/proc/$main_pid" ]; then
            # Cek zombie state — zombie = crash, jangan dianggap alive
            local proc_state
            proc_state=$(grep -m1 "^State:" "/proc/$main_pid/status" 2>/dev/null | awk '{print $2}')
            if [ "$proc_state" != "Z" ] && [ "$proc_state" != "X" ]; then
                local cmdline
                cmdline=$(cat "/proc/$main_pid/cmdline" 2>/dev/null | tr -d '\0')
                echo "$cmdline" | grep -q "$pkg" && alive=1
            fi
        fi

        if [ "$alive" = "0" ]; then
            rejoin_count=$((rejoin_count + 1))
            if [ "$rejoin_count" -gt "$max_rejoin" ]; then
                log "⚠️ Max rejoin ($max_rejoin) tercapai di verify — serahkan ke crash_monitor"
                release_join_lock "$pkg"
                return
            fi
            log "💥 $pkg mati di fase join (attempt $rejoin_count/$max_rejoin) — rejoin paksa"
            sleep 2
            source "$cfg_file" 2>/dev/null || true
            local active_url
            active_url=$(get_active_url "$MODE" "$URL")
            # join_server akan acquire join_lock baru — release dulu yg lama
            release_join_lock "$pkg"
            join_server "$pkg" "$active_url" "$MODE"
            wait_ingame "$pkg"
            # Pasang ulang untuk lanjut verify
            acquire_join_lock "$pkg"
            checks=0
            continue
        fi
        checks=$((checks + 1))
    done

    # Stabil — lepas join lock agar crash_monitor kembali aktif memantau
    release_join_lock "$pkg"
    log "✅ Stabil pasca-join — crash_monitor aktif kembali"
}

monitor_events() {
    local pkg=$1
    local cfg_file=$2

    # Outer loop: restart otomatis kalau logcat pipe tutup (disconnect,
    # Android kill proses logcat, dll). Sebelumnya fungsi ini langsung
    # return saat pipe selesai → background process mati → wait di MAIN
    # kehabisan job → script exit ke Termux shell.
    while true; do
        # BUG FIX: sama seperti logcat_crash_detector — tanpa -T, logcat
        # dump seluruh buffer historis dulu tiap kali loop restart, bisa
        # re-trigger sinyal disconnect LAMA yang sudah lama selesai.
        local start_ts
        start_ts=$(date '+%m-%d %H:%M:%S.000')

        while read -r line; do
            if echo "$line" | grep -qiE "Sending disconnect with reason|Connection lost|Lost connection|Disconnected from server"; then
                # Skip jika join sedang berlangsung — signal disconnect bisa muncul
                # saat Roblox berpindah server / loading private server baru
                if is_joining "$pkg"; then
                    log "⏭️ monitor_events: join aktif — abaikan disconnect signal"
                    continue
                fi

                local reason
                if echo "$line" | grep -qiE "Sending disconnect"; then
                    reason="Sending disconnect"
                elif echo "$line" | grep -qiE "Connection lost"; then
                    reason="Connection lost"
                else
                    reason="Disconnected"
                fi

                log "❌ DC: $reason"
                send_discord_notification "disconnect" "$reason" "$pkg"

                sleep 3
                source "$cfg_file" 2>/dev/null
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE"
                wait_ingame "$pkg"
                verify_ingame_stable "$pkg" "$cfg_file"
            fi

        done < <(logcat -T "$start_ts" -v time 2>/dev/null | grep --line-buffered -iE "Sending disconnect|Connection lost|Lost connection|Disconnected from server")

        sleep 3
    done
}

crash_monitor() {
    local pkg=$1
    local cfg_file=$2
    local miss_count=0
    local state_dir="${STATE_BASE_DIR}/rbx_state_${pkg}"

    while true; do
        # ── SKIP jika proses join sedang berlangsung ──────────────────────
        # Saat loading private server, Roblox restart prosesnya sendiri
        # sehingga PID hilang sebentar — crash_monitor TIDAK boleh intervensi.
        if is_joining "$pkg"; then
            miss_count=0   # reset agar tidak menumpuk miss palsu
            sleep 3
            continue
        fi

        # ── Deteksi via PID ──────────────────────────────────────────────
        local main_pid=""

        # Method 1: ps -A exact match di kolom NAME
        main_pid=$(ps -A 2>/dev/null \
            | grep -v ":" \
            | awk '{print $NF, $2}' \
            | grep "^${pkg} " \
            | awk '{print $2}' \
            | head -1)

        # Method 2: get_pid_for_pkg
        if [ -z "$main_pid" ]; then
            main_pid=$(get_pid_for_pkg "$pkg")
        fi

        # Verifikasi PID via /proc — + cek zombie state
        local app_alive=0
        if [ -n "$main_pid" ] && [ -d "/proc/$main_pid" ]; then
            local proc_state
            proc_state=$(grep -m1 "^State:" "/proc/$main_pid/status" 2>/dev/null | awk '{print $2}')
            if [ "$proc_state" != "Z" ] && [ "$proc_state" != "X" ]; then
                local cmdline
                cmdline=$(cat "/proc/$main_pid/cmdline" 2>/dev/null | tr -d '\0')
                if echo "$cmdline" | grep -q "$pkg"; then
                    app_alive=1
                    miss_count=0
                    mkdir -p "$state_dir" 2>/dev/null
                    echo "$main_pid" > "$state_dir/pid" 2>/dev/null
                fi
            fi
        fi

        # ── Fallback: dumpsys ─────────────────────────────────────────────
        if [ "$app_alive" = "0" ]; then
            local dumpsys_out
            dumpsys_out=$(dumpsys activity processes 2>/dev/null)

            if echo "$dumpsys_out" | grep -qE "(^|[[:space:]])(proc|processName)=${pkg}([[:space:]]|\$|,)"; then
                app_alive=1
                miss_count=0
            fi

            if [ "$app_alive" = "0" ]; then
                if dumpsys activity top 2>/dev/null | grep -q "ACTIVITY ${pkg}"; then
                    app_alive=1
                    miss_count=0
                fi
            fi
        fi

        # ── Deklarasi crash ───────────────────────────────────────────────
        # BUG FIX: 2 → 3 miss beruntun (±9s, bukan ±6s) sebelum declare crash.
        # Nambah sedikit buffer terhadap hiccup PID sesaat (mis. Roblox
        # restart proses internal saat transisi private server) yang lolos
        # dari JOIN_LOCK karena kejadian pas di tepi window join.
        if [ "$app_alive" = "0" ]; then
            miss_count=$((miss_count + 1))
            if [ "$miss_count" -ge 3 ]; then
                miss_count=0

                # Double-check join lock sekali lagi sebelum trigger crash
                # (bisa saja lock baru saja dipasang oleh monitor lain)
                if is_joining "$pkg"; then
                    log "⏭️ crash_monitor: join lock aktif saat akan trigger — batal"
                    sleep 3
                    continue
                fi

                # Cegah double-handle dari logcat_crash_detector
                if ! acquire_crash_lock "$pkg"; then
                    log "⏭️ crash_monitor: handler lain sudah handling crash — skip"
                    sleep 5
                    continue
                fi

                log "💥 CRASH DETECTED — $pkg tidak ditemukan (PID hilang)"
                send_discord_notification "crash" "App crashed / PID hilang" "$pkg"
                sleep 3

                source "$cfg_file" 2>/dev/null || true

                if [ "${RESTART_KALAU_CRASH:-1}" != "1" ]; then
                    log "ℹ️ RESTART_KALAU_CRASH=OFF — tidak auto-restart"
                    release_crash_lock "$pkg"
                    sleep 5
                    continue
                fi

                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE"
                wait_ingame "$pkg"
                verify_ingame_stable "$pkg" "$cfg_file"
                open_second_package
                release_crash_lock "$pkg"
            fi
        fi

        sleep 3
    done
}

# ─────────────────────────────────────────
#   LOGCAT CRASH DETECTOR (parallel dengan crash_monitor)
# ─────────────────────────────────────────
logcat_crash_detector() {
    # Deteksi crash via logcat sebagai jalur kedua — menangkap crash
    # yang prosesnya respawn terlalu cepat sebelum crash_monitor sempat
    # mendeteksi PID hilang (race condition 3s polling).
    local pkg=$1
    local cfg_file=$2

    while true; do
        # BUG FIX (root cause "crash terus-terusan" pasca-join): SEBELUMNYA
        # `logcat -b crash -b main -v time` dipanggil TANPA filter waktu (-T).
        # Tanpa -T, logcat SELALU dump SELURUH buffer historis dulu (bisa
        # ribuan baris sejak boot/wrap terakhir) sebelum streaming live —
        # termasuk tombstone/native-crash lama yang sudah lama kelar/ditangani.
        # `while read` yang manggil beberapa subprocess grep per baris makan
        # waktu NYATA untuk mengunyah backlog itu, dan waktu itu kebetulan
        # bisa bertepatan persis dengan event lain (mis. verify_ingame_stable
        # declare stabil) — kelihatan seolah crash baru terjadi saat itu,
        # padahal cuma entry LAMA yang baru "ketemu" grep. Tiap kali fungsi
        # ini restart (pipe tutup), backlog yang sama bisa terbaca ulang →
        # loop tak berkesudahan.
        # FIX: -T dengan timestamp "sekarang", di-generate ULANG tiap
        # iterasi outer loop, supaya logcat cuma kasih baris BARU sejak saat
        # itu — backlog lama tidak pernah diproses lagi.
        local start_ts
        start_ts=$(date '+%m-%d %H:%M:%S.000')

        while read -r line; do
            # BUG FIX (root cause "black screen" saat loading Private Server
            # berat): Roblox pakai arsitektur MULTI-PROCESS — ada sub-process
            # terpisah (mis. "com.roblox.client:renderer", "com.roblox.
            # client:sandboxed_process0") yang dipakai untuk render/GPU/
            # sandbox. Sub-process ini BOLEH mati & restart sendiri sebagai
            # bagian NORMAL loading asset berat (private server besar sekelas
            # "Grow a Garden") — bukan crash fatal. Regex crash kita di bawah
            # pakai SUBSTRING match ("${pkg}" ada di mana saja dalam baris),
            # jadi baris seperti "Process com.roblox.client:renderer has died"
            # IKUT ke-match walau yang mati cuma sub-process — bikin kita
            # SALAH force-stop app yang sebenarnya SEHAT (black screen yang
            # user lihat itu ULAH SCRIPT SENDIRI, bukan Roblox yang crash).
            # FIX lapis 1: abaikan baris yang jelas-jelas menyebut nama
            # PROSES BER-SUFFIX ":something" setelah nama package.
            if echo "$line" | grep -qE "${pkg}:[A-Za-z_]"; then
                continue
            fi

            local is_crash=0
            local reason=""

            # BUG FIX: grep -qi "a\|b" TIDAK bekerja di Android toybox grep
            # (tanpa -E, \| dianggap literal bukan OR). Harus pakai -qiE "a|b"
            # atau cek satu-satu. Di sini pakai -qiE.

            # Roblox crash / exit — System.exit, FATAL EXCEPTION, process died
            if echo "$line" | grep -qiE "System\.exit called|FATAL EXCEPTION.*(roblox|${pkg})|Process.*${pkg}.*(has died|died)|Roblox has crashed"; then
                is_crash=1
                reason="System.exit / Fatal"
            fi

            # Force-close / killed oleh ActivityManager
            if echo "$line" | grep -qiE "Force finishing activity.*${pkg}|Killing.*${pkg}.*(crashed|dying)|${pkg}.*force.*(stop|close)"; then
                is_crash=1
                reason="Force-closed by AM"
            fi

            # crash_dump / tombstone (native crash)
            if echo "$line" | grep -qiE "crash_dump.*${pkg}|tombstone.*${pkg}|SIGSEGV.*${pkg}|${pkg}.*native.*crash"; then
                is_crash=1
                reason="Native crash"
            fi

            if [ "$is_crash" = "1" ]; then
                # Skip jika sedang proses join — crash logcat bisa muncul
                # saat Roblox restart prosesnya sendiri waktu loading private server
                if is_joining "$pkg"; then
                    log "⏭️ logcat_detector: join sedang berlangsung — abaikan crash signal ($reason)"
                    continue
                fi

                # FIX lapis 2 (paling penting): CROSS-VERIFY PID sebelum
                # bertindak. Satu baris logcat SAJA tidak cukup dipercaya —
                # get_pid_for_pkg() sudah exact-match aman (tidak akan
                # ke-match ke sub-process ":renderer" dkk, lihat definisinya).
                # Kalau PID utama masih hidup & sehat, sinyal "crash" di atas
                # hampir pasti cuma noise dari sub-process yang sudah pulih
                # sendiri — JANGAN force-stop app yang sehat.
                sleep 1
                local verify_pid
                verify_pid=$(get_pid_for_pkg "$pkg")
                if [ -n "$verify_pid" ] && [ -d "/proc/$verify_pid" ]; then
                    local vstate
                    vstate=$(grep -m1 "^State:" "/proc/$verify_pid/status" 2>/dev/null | awk '{print $2}')
                    if [ "$vstate" != "Z" ] && [ "$vstate" != "X" ]; then
                        log "ℹ️ logcat_detector: sinyal '$reason' terdeteksi, tapi PID utama ($verify_pid) masih hidup & sehat — kemungkinan cuma sub-process (renderer/sandbox) restart. Diabaikan, TIDAK force-stop."
                        continue
                    fi
                fi

                # Cegah race condition dengan crash_monitor
                if ! acquire_crash_lock "$pkg"; then
                    log "⏭️ logcat_detector: crash_monitor sudah handle — skip ($reason)"
                    continue
                fi

                log "💥 CRASH DETECTED via logcat — $reason (PID utama terkonfirmasi hilang)"
                send_discord_notification "crash" "$reason" "$pkg"
                sleep 5

                source "$cfg_file" 2>/dev/null || true

                if [ "${RESTART_KALAU_CRASH:-1}" != "1" ]; then
                    log "ℹ️ RESTART_KALAU_CRASH=OFF — tidak auto-restart"
                    release_crash_lock "$pkg"
                    continue
                fi

                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE"
                wait_ingame "$pkg"
                verify_ingame_stable "$pkg" "$cfg_file"
                release_crash_lock "$pkg"
            fi

        # BUG FIX: tambah -b crash -b main untuk capture crash buffer
        # + perluas pattern agar lebih banyak jenis crash terdeteksi
        # + -T "$start_ts" cegah replay backlog historis (lihat penjelasan di atas)
        done < <(logcat -T "$start_ts" -b crash -b main -v time 2>/dev/null | grep --line-buffered -iE \
            "System\.exit called|FATAL EXCEPTION|Process.*${pkg}.*(has died|died)|Force finishing.*${pkg}|Killing.*${pkg}.*crash|Roblox has crashed|crash_dump.*${pkg}|tombstone.*${pkg}")

        sleep 3
    done
}

# ─────────────────────────────────────────
#   ERROR CODE MONITOR (parallel dengan crash_monitor & logcat_crash_detector)
# ─────────────────────────────────────────
# Kenapa fungsi terpisah, bukan digabung ke monitor_events?
#   monitor_events sudah nangkep frasa disconnect GENERIK ("Sending
#   disconnect with reason", "Connection lost", dll) — tapi TIDAK berhenti
#   di angka kode error spesifik. Kode 272/273/274/275/277/278/279/282
#   adalah kode disconnect Roblox yang paling sering muncul akibat internet
#   putus/lag/network error (BUKAN Roblox lagi nge-crash — PID app biasanya
#   masih hidup, cuma koneksi socket ke server yang terputus). Karena app
#   tidak mati, crash_monitor (yang nunggu PID hilang) & logcat_crash_detector
#   (yang nunggu pola FATAL EXCEPTION/tombstone) TIDAK akan pernah trigger
#   untuk kasus ini — makanya perlu detector sendiri yang langsung rejoin
#   begitu kode errornya ketemu, tanpa nunggu app "keliatan mati" dulu.
#
# Catatan soal metode deteksi (dijawab dari yang user tanya: "cara lain?"):
#   Dialog "Disconnected... Error Code: 277" itu di-render Roblox DI DALAM
#   game engine-nya sendiri (GL surface / canvas internal), BUKAN native
#   Android View/TextView. Konsekuensinya:
#     - `uiautomator dump` (baca teks lewat accessibility tree) TIDAK akan
#       bisa "melihat" teks itu — accessibility tree cuma tahu ada satu
#       SurfaceView kosong, tanpa isi teks di dalamnya.
#     - Screenshot + OCR (tesseract) SECARA TEKNIS bisa baca teks itu, tapi:
#         a) butuh install tesseract-ocr + trained data di Termux (berat),
#         b) akurasi tergantung resolusi/DPI/font/posisi dialog per device,
#         c) tiap check = screencap + OCR = jauh lebih lambat & lebih makan
#            baterai/CPU dibanding grep logcat yang instan.
#   Makanya dipilih LOGCAT — sama seperti fondasi semua detector lain di
#   script ini (monitor_events, crash_monitor, logcat_crash_detector).
#   Roblox Android mencatat reason disconnect ke logcat saat dialog error
#   itu muncul. KALAU ternyata di device kamu kode errornya TIDAK pernah
#   nongol di logcat (format log Roblox beda-beda per versi app), OCR bisa
#   ditambahkan belakangan sebagai fallback — tinggal bilang aja.
#
# Cara verifikasi/tuning pattern-nya di device asli (kalau ternyata tidak
# ke-detect): saat lagi reproduce error (mis. matiin data/wifi sebentar
# sampai muncul dialog Error Code), jalankan di sesi Termux LAIN:
#   logcat -v time | grep -i "error\|disconnect"
# lalu lihat format baris persis yang muncul, dan sesuaikan pattern grep
# di bawah (variabel ERROR_CODE_LIST + kata kunci "error code"/"disconnect").
error_code_monitor() {
    local pkg=$1
    local cfg_file=$2

    while true; do
        # Sama seperti detector lain: -T "sekarang" di-generate ULANG tiap
        # iterasi outer loop, cegah replay backlog logcat lama.
        local start_ts
        start_ts=$(date '+%m-%d %H:%M:%S.000')

        while read -r line; do
            # Skip kalau proses join lagi berlangsung — dialog error code
            # kadang ikut kesebut sekilas di log waktu Roblox pindah server,
            # bukan disconnect asli yang butuh rejoin manual.
            if is_joining "$pkg"; then
                continue
            fi

            # Ambil kode yang match persis (hindari nyangkut ke substring,
            # mis. "1277" ke-anggap "277" — makanya dibatasi bukan-digit
            # di kedua sisi, bukan pakai \b yang belum tentu didukung
            # grep -E di Android/toybox).
            local code
            code=$(echo "$line" \
                | grep -oE "(^|[^0-9])(${ERROR_CODE_LIST})([^0-9]|\$)" \
                | head -1 \
                | grep -oE "[0-9]+")
            [ -z "$code" ] && continue

            # Cegah race/double-handle dengan crash_monitor & logcat_crash_detector
            # (mis. kasus disconnect yang ujung-ujungnya bikin app force-close juga)
            if ! acquire_crash_lock "$pkg"; then
                log "⏭️ error_code_monitor: handler lain sudah handling — skip (Error Code $code)"
                continue
            fi

            log "🌐 ERROR CODE $code TERDETEKSI — kemungkinan internet putus/lag, auto-rejoin..."
            send_discord_notification "disconnect" "Error Code: $code (internet putus/lag)" "$pkg"

            sleep 3
            source "$cfg_file" 2>/dev/null || true

            if [ "${DETEKSI_ERROR_CODE:-1}" != "1" ]; then
                log "ℹ️ DETEKSI_ERROR_CODE=OFF — tidak auto-rejoin"
                release_crash_lock "$pkg"
                continue
            fi

            local active_url
            active_url=$(get_active_url "$MODE" "$URL")
            join_server "$pkg" "$active_url" "$MODE"
            wait_ingame "$pkg"
            verify_ingame_stable "$pkg" "$cfg_file"
            release_crash_lock "$pkg"

        done < <(logcat -T "$start_ts" -b main -b system -b crash -v time 2>/dev/null | grep --line-buffered -iE \
            "(error.{0,3}code|disconnect(ed)?).{0,60}(^|[^0-9])(${ERROR_CODE_LIST})([^0-9]|\$)|(^|[^0-9])(${ERROR_CODE_LIST})([^0-9]|\$).{0,60}(error.{0,3}code|disconnect(ed)?)")

        sleep 3
    done
}

# ─────────────────────────────────────────
#   OPEN SECOND PACKAGE (menggunakan perbaikan)
# ─────────────────────────────────────────

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

    # Split screen dihapus — langsung pakai floating/freeform window
    try_floating_window "$PKG2" "$active_url2"
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
echo "  2) 2 Package (Floating Window)"
echo ""
printf "  Pilih: "
read -r SETUP_CHOICE

if [ "$SETUP_CHOICE" = "2" ]; then
    USE_MULTI_PKG=1
else
    USE_MULTI_PKG=0
fi

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
fi

# Load Discord settings lama
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
    if prompt_discord_webhook DISCORD_WEBHOOK; then
        DISCORD_ENABLED=1
        echo ""
        echo "  User ID (opsional):"
        printf "  > "
        read -r DISCORD_USER_ID
        echo ""
        echo "  ✅ Discord configured!"
    else
        echo "  ℹ️ Dibatalkan — Discord tidak di-setup."
    fi
    sleep 2
fi

# Simpan setting Discord ke config
persist_discord_settings "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" "$PKG1"
if [ "$USE_MULTI_PKG" = "1" ]; then
    persist_discord_settings "${CONFIG_BASE_DIR}/roblox_config_${PKG2}.cfg" "$PKG2"
fi

# Load config
source "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" 2>/dev/null

# START
mkdir -p "$PKG1_STATE_DIR"

clr
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
echo "   ROBLOX AUTO RECONNECT + AUTO RELOG"    | tee -a "$PKG1_LOG_FILE"
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
log "Package 1        : $PKG1"
log "Mode             : $(get_mode_label $MODE)"
log "Multi Package    : $(show_toggle $USE_MULTI_PKG)"
if [ "$USE_MULTI_PKG" = "1" ]; then
    log "Package 2        : $PKG2"
fi
log "Discord          : $(show_toggle $DISCORD_ENABLED)"
log "Deteksi Error Code: $(show_toggle ${DETEKSI_ERROR_CODE:-1})"
echo "=========================================" | tee -a "$PKG1_LOG_FILE"
echo ""

# Get active URL
PKG1_ACTIVE_URL=$(get_active_url "$MODE" "$URL")

# Guard: URL kosong
if [ -z "$PKG1_ACTIVE_URL" ] && { [ "$MODE" = "main" ] || [ "$MODE" = "public" ]; }; then
    log "❌ FATAL: URL kosong untuk mode $MODE — config rusak atau URL belum pernah diisi"
    log "   Hapus config dan jalankan ulang: rm ${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
    exit 1
fi

# Join first package
join_server "$PKG1" "$PKG1_ACTIVE_URL" "$MODE"
wait_ingame "$PKG1"
verify_ingame_stable "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"

# Open second package if enabled
if [ "$USE_MULTI_PKG" = "1" ]; then
    sleep 2
    open_second_package
fi

log "🚀 Ready untuk monitoring"
echo ""

# Start monitors
monitor_events "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
MONITOR_PID=$!

crash_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
CRASH_PID=$!

logcat_crash_detector "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
LOGCAT_CRASH_PID=$!

error_code_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
ERROR_CODE_PID=$!

# Keep alive — restart monitor jika mati
while true; do
    if ! kill -0 "$MONITOR_PID" 2>/dev/null; then
        log "⚠️ monitor_events mati — restart otomatis"
        monitor_events "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
        MONITOR_PID=$!
    fi
    if ! kill -0 "$CRASH_PID" 2>/dev/null; then
        log "⚠️ crash_monitor mati — restart otomatis"
        crash_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
        CRASH_PID=$!
    fi
    if ! kill -0 "$LOGCAT_CRASH_PID" 2>/dev/null; then
        log "⚠️ logcat_crash_detector mati — restart otomatis"
        logcat_crash_detector "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
        LOGCAT_CRASH_PID=$!
    fi
    if ! kill -0 "$ERROR_CODE_PID" 2>/dev/null; then
        log "⚠️ error_code_monitor mati — restart otomatis"
        error_code_monitor "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg" &
        ERROR_CODE_PID=$!
    fi
    sleep "$CHECK_INTERVAL"
done