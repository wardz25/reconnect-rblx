#!/data/data/com.termux/files/usr/bin/bash

# Pastikan PATH Termux tersedia saat jalan sebagai root (exec su -c tidak
# inherit PATH user) — tanpa ini, pkg/curl/awk/dll tidak ketemu di root shell
export PATH="/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/sbin:$PATH"

# ─────────────────────────────────────────
#   ROBLOX AUTO RECONNECT + AUTO RELOG
#   by: Wardz | versi: 3.1 (+ PIL Grid Error Detection + Auto Grid)
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
ERROR_CODE_LIST="272|273|274|275|277|278|279|282|529"

# Timeout stuck watchdog: berapa detik Roblox boleh "hidup tapi diam"
# sebelum dianggap stuck di dialog error dan di-rejoin.
# Default 120 detik (2 menit) — cukup lama untuk loading normal,
# cukup cepat untuk nangkep disconnect yang gak ke-detect logcat.
STUCK_WATCHDOG_TIMEOUT=120

# Timeout wait_ingame: berapa detik tunggu logcat detect INGAME setelah join.
# Kalau private server berat / koneksi lambat, naikkan ke 180-240.
WAIT_INGAME_TIMEOUT=120

# Verify stable duration: berapa detik tight-monitor pasca-join sebelum
# dianggap stabil dan crash_monitor dikembalikan. Default 20 detik.
VERIFY_STABLE_DURATION=20

# Debug screenshot directory untuk error code detection
SCREENSHOT_DIR="/data/local/tmp/rblx-reconnect"

# Auto Grid: otomatis atur 2 Roblox dalam freeform window side-by-side
AUTO_GRID_ENABLED=0

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

    # ── COOLDOWN (v3.1 FIX: bug 4x webhook) ──────────────────────────────
    # Root cause: verify_ingame_stable memanggil join_server → wait_ingame
    # hingga max_rejoin=3 kali kalau app terus mati pasca-join. Setiap
    # wait_ingame kirim reconnect_success → bisa sampai 4 notif untuk satu
    # event. Tambahan: monitor_events + error_code_monitor + stuck_watchdog
    # bisa race dan fire disconnect hampir bersamaan untuk event yang sama.
    # FIX: satu timestamp-file per event_type. Kalau < 90 detik dari fire
    # terakhir untuk event yang sama → skip, jangan kirim lagi.
    local _cd_dir="${STATE_BASE_DIR}/rbx_discord_cd"
    local _cd_file="${_cd_dir}/${event_type}"
    mkdir -p "$_cd_dir" 2>/dev/null
    if [ -f "$_cd_file" ]; then
        local _last _now _age
        _last=$(cat "$_cd_file" 2>/dev/null || echo 0)
        _now=$(date +%s)
        _age=$(( _now - ${_last:-0} ))
        if [ "$_age" -lt 90 ]; then
            return 0   # skip — sudah kirim notif yang sama < 90 detik lalu
        fi
    fi
    date +%s > "$_cd_file" 2>/dev/null

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

    # ── Timestamp: ISO (embed), Unix epoch (Discord native TS), footer ───
    local iso_ts unix_ts footer_ts
    iso_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    unix_ts=$(date +%s 2>/dev/null || echo "0")
    footer_ts="${timestamp%:*}"   # buang detik: "DD/MM/YYYY HH:MM:SS" -> "DD/MM/YYYY HH:MM"

    # ── Helper escape JSON ────────────────────────────────────────────────
    # BUG FIX: definisikan di scope subshell ini (bukan di dalam heredoc)
    _jesc() {
        printf '%s' "$1" \
            | sed 's/\\/\\\\/g' \
            | sed 's/"/\\"/g' \
            | awk '{if(NR>1)printf "\\n"; printf "%s",$0}'
    }

    local esc_pkg esc_device esc_status esc_ts esc_mention esc_footer_ts
    esc_pkg=$(_jesc "$pkg")
    esc_device=$(_jesc "$device")
    esc_status=$(_jesc "$app_status")
    esc_ts=$(_jesc "$timestamp")
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
    description="**Last Updated:** <t:${unix_ts}:F> (<t:${unix_ts}:R>)\n\n"
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

    # Timeout fields — arg 10/11/12 opsional
    local t_wait="${10}"
    local t_verify="${11}"
    local t_watchdog="${12}"

    # Auto Grid — arg 13, default baca dari file jika ada
    local auto_grid="${13}"

    if [ -f "$cfg_file" ]; then
        [ -z "$t_wait" ]     && t_wait=$(grep '^WAIT_INGAME_TIMEOUT='    "$cfg_file" | cut -d= -f2)
        [ -z "$t_verify" ]   && t_verify=$(grep '^VERIFY_STABLE_DURATION=' "$cfg_file" | cut -d= -f2)
        [ -z "$t_watchdog" ] && t_watchdog=$(grep '^STUCK_WATCHDOG_TIMEOUT=' "$cfg_file" | cut -d= -f2)
        [ -z "$auto_grid" ]  && auto_grid=$(grep '^AUTO_GRID=' "$cfg_file" | head -1 | cut -d= -f2)
    fi
    t_wait="${t_wait:-120}"
    t_verify="${t_verify:-20}"
    t_watchdog="${t_watchdog:-120}"
    auto_grid="${auto_grid:-0}"

    # Discord settings — preserve existing if globals empty
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

# Timeout settings
WAIT_INGAME_TIMEOUT=$t_wait
VERIFY_STABLE_DURATION=$t_verify
STUCK_WATCHDOG_TIMEOUT=$t_watchdog

# Auto Grid (freeform arrangement — 2 package)
AUTO_GRID=$auto_grid

DISCORD_ENABLED=${disc_enabled:-0}
DISCORD_WEBHOOK="${disc_webhook}"
DISCORD_USER_ID="${disc_uid}"
EOF
}

persist_discord_settings() {
    local cfg_file=$1
    local pkg=$2
    local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home saved_error_code saved_auto_grid

    if [ -f "$cfg_file" ]; then
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_auto_grid=$(grep '^AUTO_GRID=' "$cfg_file" | head -1 | cut -d= -f2)
    fi

    save_config "$cfg_file" "$pkg" "$saved_url" "$saved_mode" \
        "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home" \
        "${saved_error_code:-1}" "" "" "" "${saved_auto_grid:-0}"
}

# ─────────────────────────────────────────
#   TAMPILAN
# ─────────────────────────────────────────

clr() { clear 2>/dev/null || printf '\033[2J\033[H'; }

header() {
    if command -v figlet >/dev/null 2>&1; then
        figlet -f small "SPHINX" 2>/dev/null || echo "  SPHINX MONITOR"
    else
        echo "  SPHINX MONITOR"
    fi
    echo "  Roblox Auto Reconnect + Auto Relog  |  by Wardz"
    echo "  ─────────────────────────────────────────────────"
    if [ -n "$PKG1" ]; then
        echo "  📦 Package 1: $PKG1"
    fi
    if [ -n "$PKG2" ] && [ "$USE_MULTI_PKG" = "1" ]; then
        echo "  📦 Package 2: $PKG2"
    fi
    echo ""
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
    local auto_grid=${8:-0}
    
    echo ""
    echo "  Mode aktif  : $(get_mode_label $mode)"
    echo "  URL         : ${url:-[belum diisi]}"
    echo "  Relog       : ${relog} jam $([ "$relog" = "0" ] && echo '(OFF)' || echo '(ON)')"
    echo "  Reconnect   : $(show_toggle $reconnect)"
    echo "  Restart     : $(show_toggle $restart)"
    echo "  Home RC     : $(show_toggle $home)"
    echo "  Error Code  : $(show_toggle $error_code)"
    echo "  Auto Grid   : $(show_toggle $auto_grid)"
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
    
    local auto_grid=0
    if [ "$USE_MULTI_PKG" = "1" ]; then
        echo ""
        echo "  Auto Grid (freeform window arrangement)?"
        echo "  Buka 2 Roblox Paket side-by-side dalam floating windows"
        echo "  (1=ON, 0=OFF, default: 0)"
        printf "  > "
        read -r auto_grid
        if [ "$auto_grid" != "1" ]; then auto_grid=0; fi
    fi
    
    # Save
    local cfg_file="${CONFIG_BASE_DIR}/roblox_config_${pkg}.cfg"
    save_config "$cfg_file" "$pkg" "$url" "$mode" "$relog" "$reconnect" "$restart" "$home" "$error_code" "" "" "" "$auto_grid"
    
    echo ""
    echo "  ✅ Config Package $pkg_num tersimpan!"
    sleep 2
}

menu_ganti_url_mode_pkg() {
    local pkg=$1
    local pkg_num=$2
    local cfg_file=$3

    local keep_relog keep_reconnect keep_restart keep_home keep_error_code keep_auto_grid
    keep_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_auto_grid=$(grep '^AUTO_GRID=' "$cfg_file" | head -1 | cut -d= -f2)
    keep_auto_grid="${keep_auto_grid:-0}"

    local new_mode new_url
    setup_mode_and_url "Ganti Mode & URL — Package $pkg_num ($pkg)" new_mode new_url

    # BUG FIX: user pilih "5) Kembali" → setup_mode_and_url return 1
    # Sebelumnya save_config tetap dipanggil dengan new_mode="" → MODE="Unknown"
    [ $? -ne 0 ] && return

    save_config "$cfg_file" "$pkg" "$new_url" "$new_mode" \
        "$keep_relog" "$keep_reconnect" "$keep_restart" "$keep_home" \
        "${keep_error_code:-1}" "" "" "" "$keep_auto_grid"

    echo ""
    echo "  ✅ Mode & URL diupdate, setting lain tetap."
    sleep 1
}

menu_edit_settings_pkg() {
    local pkg=$1
    local cfg_file=$2

    while true; do
        local cur_url cur_mode cur_relog cur_reconnect cur_restart cur_home cur_error_code cur_auto_grid
        local cur_wait cur_verify cur_watchdog
        cur_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        cur_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_error_code="${cur_error_code:-1}"
        cur_auto_grid=$(grep '^AUTO_GRID=' "$cfg_file" | head -1 | cut -d= -f2)
        cur_auto_grid="${cur_auto_grid:-0}"
        cur_wait=$(grep '^WAIT_INGAME_TIMEOUT=' "$cfg_file" | cut -d= -f2); cur_wait="${cur_wait:-120}"
        cur_verify=$(grep '^VERIFY_STABLE_DURATION=' "$cfg_file" | cut -d= -f2); cur_verify="${cur_verify:-20}"
        cur_watchdog=$(grep '^STUCK_WATCHDOG_TIMEOUT=' "$cfg_file" | cut -d= -f2); cur_watchdog="${cur_watchdog:-120}"

        clr
        header
        echo ""
        echo "  ⚙️ UBAH SETTING — $pkg"
        show_current_config "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" "$cur_error_code" "$cur_auto_grid"
        echo "  1) Relog interval        (sekarang: ${cur_relog} jam)"
        echo "  2) Reconnect otomatis    (sekarang: $(show_toggle $cur_reconnect))"
        echo "  3) Restart kalau crash   (sekarang: $(show_toggle $cur_restart))"
        echo "  4) Reconnect saat home   (sekarang: $(show_toggle $cur_home))"
        echo "  5) Deteksi Error Code    (sekarang: $(show_toggle $cur_error_code))"
        echo "  6) Auto Grid (freeform)  (sekarang: $(show_toggle $cur_auto_grid))"
        echo "  7) Timeout settings      (Join: ${cur_wait}s | Verify: ${cur_verify}s | Watchdog: ${cur_watchdog}s)"
        echo "  8) Kembali"
        echo ""
        printf "  Pilih (1-8): "
        read -r PILIHAN

            case $PILIHAN in
            1)
                echo ""
                echo "  Relog setiap berapa jam? (0=OFF)"
                printf "  > "
                read -r V
                if [[ "$V" =~ ^[0-9]+$ ]]; then
                    save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$V" "$cur_reconnect" "$cur_restart" "$cur_home" "$cur_error_code" "" "" "" "$cur_auto_grid"
                    echo "  ✅ Disimpan!"
                else
                    echo "  ⚠ Masukkan angka!"
                fi
                sleep 1
                ;;
            2)
                local new_val; new_val=$([ "$cur_reconnect" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$new_val" "$cur_restart" "$cur_home" "$cur_error_code" "" "" "" "$cur_auto_grid"
                echo "  ✅ Reconnect: $(show_toggle $new_val)"
                sleep 1
                ;;
            3)
                local new_val; new_val=$([ "$cur_restart" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$new_val" "$cur_home" "$cur_error_code" "" "" "" "$cur_auto_grid"
                echo "  ✅ Restart: $(show_toggle $new_val)"
                sleep 1
                ;;
            4)
                local new_val; new_val=$([ "$cur_home" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$new_val" "$cur_error_code" "" "" "" "$cur_auto_grid"
                echo "  ✅ Home RC: $(show_toggle $new_val)"
                sleep 1
                ;;
             5)
                local new_val; new_val=$([ "$cur_error_code" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" "$new_val" "" "" "" "$cur_auto_grid"
                echo "  ✅ Deteksi Error Code: $(show_toggle $new_val)"
                sleep 1
                ;;
            6)
                # ── Auto Grid toggle ──────────────────────────────────────
                local new_val; new_val=$([ "$cur_auto_grid" = "1" ] && echo 0 || echo 1)
                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" "$cur_error_code" "$cur_wait" "$cur_verify" "$cur_watchdog" "$new_val"
                AUTO_GRID_ENABLED="$new_val"
                echo "  ✅ Auto Grid: $(show_toggle $new_val)"
                sleep 1
                ;;
            7)
                # ── Timeout sub-menu ─────────────────────────────────────
                while true; do
                    clr; header
                    echo ""
                    echo "  ⏱️ TIMEOUT SETTINGS — $pkg"
                    echo ""
                    echo "  1) Wait INGAME timeout    (sekarang: ${cur_wait}s)"
                    echo "     → Berapa detik tunggu Roblox INGAME setelah join via logcat"
                    echo "       Naikkan ke 180-240s kalau private server lambat loading"
                    echo ""
                    echo "  2) Verify stable duration (sekarang: ${cur_verify}s)"
                    echo "     → Berapa detik tight-monitor pasca-join sebelum dianggap stabil"
                    echo "       Naikkan ke 30s kalau sering crash langsung setelah join"
                    echo ""
                    echo "  3) Stuck watchdog timeout (sekarang: ${cur_watchdog}s)"
                    echo "     → Berapa detik idle tanpa network sebelum auto-rejoin"
                    echo "       Turunkan ke 60s untuk deteksi cepat, naikkan ke 180s kalau false positive"
                    echo ""
                    echo "  4) Kembali"
                    echo ""
                    printf "  Pilih (1-4): "
                    read -r TSUB

                    case $TSUB in
                        1)
                            echo ""
                            printf "  Wait INGAME timeout (detik, sekarang: ${cur_wait}s) > "
                            read -r V
                            if [[ "$V" =~ ^[0-9]+$ ]] && [ "$V" -ge 30 ] && [ "$V" -le 600 ]; then
                                cur_wait="$V"
                                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" \
                                    "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" \
                                    "$cur_error_code" "$cur_wait" "$cur_verify" "$cur_watchdog" "$cur_auto_grid"
                                WAIT_INGAME_TIMEOUT="$V"
                                echo "  ✅ Wait INGAME timeout: ${V}s"
                            else
                                echo "  ⚠ Masukkan angka 30-600"
                            fi
                            sleep 1 ;;
                        2)
                            echo ""
                            printf "  Verify stable duration (detik, sekarang: ${cur_verify}s) > "
                            read -r V
                            if [[ "$V" =~ ^[0-9]+$ ]] && [ "$V" -ge 5 ] && [ "$V" -le 120 ]; then
                                cur_verify="$V"
                                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" \
                                    "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" \
                                    "$cur_error_code" "$cur_wait" "$cur_verify" "$cur_watchdog" "$cur_auto_grid"
                                VERIFY_STABLE_DURATION="$V"
                                echo "  ✅ Verify stable duration: ${V}s"
                            else
                                echo "  ⚠ Masukkan angka 5-120"
                            fi
                            sleep 1 ;;
                        3)
                            echo ""
                            printf "  Stuck watchdog timeout (detik, sekarang: ${cur_watchdog}s) > "
                            read -r V
                            if [[ "$V" =~ ^[0-9]+$ ]] && [ "$V" -ge 30 ] && [ "$V" -le 600 ]; then
                                cur_watchdog="$V"
                                save_config "$cfg_file" "$pkg" "$cur_url" "$cur_mode" \
                                    "$cur_relog" "$cur_reconnect" "$cur_restart" "$cur_home" \
                                    "$cur_error_code" "$cur_wait" "$cur_verify" "$cur_watchdog" "$cur_auto_grid"
                                STUCK_WATCHDOG_TIMEOUT="$V"
                                echo "  ✅ Stuck watchdog timeout: ${V}s"
                            else
                                echo "  ⚠ Masukkan angka 30-600"
                            fi
                            sleep 1 ;;
                        4) break ;;
                        *) echo "  ⚠ Pilih 1-4"; sleep 1 ;;
                    esac
                done
                ;;
            8) return ;;
            *) echo "  ⚠ Pilih 1-8"; sleep 1 ;;
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
        local saved_url saved_mode saved_relog saved_reconnect saved_restart saved_home saved_error_code saved_auto_grid
        saved_url=$(grep '^URL=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_mode=$(grep '^MODE=' "$cfg_file" | head -1 | cut -d'"' -f2)
        saved_relog=$(grep '^RELOG_SETIAP_JAM=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_reconnect=$(grep '^RECONNECT_OTOMATIS=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_restart=$(grep '^RESTART_KALAU_CRASH=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_home=$(grep '^RECONNECT_SAAT_HOME=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code=$(grep '^DETEKSI_ERROR_CODE=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_error_code="${saved_error_code:-1}"
        saved_auto_grid=$(grep '^AUTO_GRID=' "$cfg_file" | head -1 | cut -d= -f2)
        saved_auto_grid="${saved_auto_grid:-0}"

        clr
        header
        echo ""
        echo "  📦 Config Package $pkg_num ($pkg) ditemukan dari run sebelumnya:"
        show_current_config "$saved_url" "$saved_mode" "$saved_relog" "$saved_reconnect" "$saved_restart" "$saved_home" "$saved_error_code" "$saved_auto_grid"
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
#   AUTO GRID — freeform window arrangement
# ─────────────────────────────────────────

init_freeform_support() {
    local changed=0
    if [ "$(settings get global enable_freeform_support 2>/dev/null)" != "1" ]; then
        settings put global enable_freeform_support 1 2>/dev/null && changed=1
    fi
    if [ "$(settings get global force_resizable_activities 2>/dev/null)" != "1" ]; then
        settings put global force_resizable_activities 1 2>/dev/null && changed=1
    fi
    if [ "$changed" = "1" ]; then
        log "🔲 Freeform support enabled"
    fi
}

get_task_id_for_pkg() {
    local pkg=$1
    local tid=""
    tid=$(dumpsys activity activities 2>/dev/null \
        | grep -B3 "package=$pkg" \
        | grep -oE "taskId=[0-9]+" \
        | grep -oE "[0-9]+" \
        | head -1)
    echo "$tid"
}

auto_grid_arrange() {
    local pkg1=$1 url1=$2
    local pkg2=$3 url2=$4

    log "🔲 Auto Grid: arranging windows..."

    init_freeform_support

    local display
    display=$(wm size 2>/dev/null | grep -oE "[0-9]+x[0-9]+" | head -1)
    local disp_w="${display%%x*}"
    local disp_h="${display##*x}"
    local half_w=$(( disp_w / 2 ))
    log "🔲 Display: ${disp_w}x${disp_h}, half: ${half_w}"

    local act1
    act1=$(get_view_activity "$pkg1" "$url1")

    local act2
    act2=$(get_view_activity "$pkg2" "$url2")

    # ── PKG1: resize existing task if running, else launch fresh ──
    local tid1
    tid1=$(get_task_id_for_pkg "$pkg1")

    if [ -n "$tid1" ]; then
        log "🔲 $pkg1 already running (task $tid1) — resizing to left half"
        am task resize "$tid1" 0 0 "$half_w" "$disp_h" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "✅ Auto Grid: PKG1 resized to left half (task $tid1)"
        else
            log "⚠️ Auto Grid: PKG1 resize failed — force-stop + relaunch"
            am force-stop "$pkg1" 2>/dev/null
            sleep 2
            am start -a android.intent.action.VIEW -d "$url1" -n "$act1" \
                --windowingMode 5 -f 0x10000000 </dev/null >/dev/null 2>&1
        fi
    else
        log "🔲 Launching $pkg1 in freeform (left half)"
        am start -a android.intent.action.VIEW -d "$url1" -n "$act1" \
            --windowingMode 5 -f 0x10000000 </dev/null >/dev/null 2>&1
    fi
    sleep 5

    # ── PKG2: launch fresh in right half ──────────────────────────
    log "🔲 Launching $pkg2 in freeform (right half)"
    am force-stop "$pkg2" 2>/dev/null
    sleep 1
    am start -a android.intent.action.VIEW -d "$url2" -n "$act2" \
        --windowingMode 5 -f 0x10000000 </dev/null >/dev/null 2>&1
    sleep 5

    local tid2
    tid2=$(get_task_id_for_pkg "$pkg2")
    if [ -n "$tid2" ]; then
        am task resize "$tid2" "$half_w" 0 "$disp_w" "$disp_h" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "✅ Auto Grid: PKG2 resized to right half (task $tid2)"
        else
            log "⚠️ Auto Grid: PKG2 resize failed — freeform tetap jalan"
        fi
    else
        log "⚠️ Auto Grid: cannot get task ID for $pkg2"
    fi

    log "✅ Auto Grid done"
    send_discord_notification "floating" "Auto Grid — both arranged" "$pkg1"
}

# ─────────────────────────────────────────
#   LOG & CORE
# ─────────────────────────────────────────

log() {
    local msg=$1
    local type=${2:-info}   # info | success | error | warning
    echo "[$PKG1] [$(date +%H:%M:%S)] $msg"
    if [ -f "$PKG1_LOG_FILE" ]; then
        echo "[$(date +%H:%M:%S)] $msg" >> "$PKG1_LOG_FILE"
    fi
    # Tulis ke dashboard events (dipakai oleh Python dashboard)
    write_dashboard_event "$PKG1" "$msg" "$type"
}

# ─────────────────────────────────────────
#   DASHBOARD STATE
# ─────────────────────────────────────────

DASH_DIR="/data/local/tmp/rbx_dash"

update_dashboard_state() {
    local pkg=$1 status=$2 event=$3
    mkdir -p "$DASH_DIR" 2>/dev/null
    local sf="${DASH_DIR}/${pkg//[^a-zA-Z0-9]/_}.json"

    # Baca count dari file existing
    local rc=0 cr=0
    if [ -f "$sf" ]; then
        rc=$(grep -o '"rc":[0-9]*' "$sf" | grep -o '[0-9]*' || echo 0)
        cr=$(grep -o '"cr":[0-9]*' "$sf" | grep -o '[0-9]*' || echo 0)
    fi
    # Increment berdasarkan event type
    case "$status" in
        online)  rc=$(( rc + 1 )) ;;
        crashed) cr=$(( cr + 1 )) ;;
    esac

    local cpu ram temp now
    now=$(date +%s)
    cpu=$(top -bn1 2>/dev/null | grep -i "cpu" | head -1 | grep -oE "[0-9]+\.?[0-9]*%" | head -1 || echo "?")
    ram=$(free -m 2>/dev/null | awk 'NR==2{printf "%dMB free (%.0f%%)", $4, $4/$2*100}' || echo "?")
    temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.0f°C",$1/1000}' || echo "?")

    printf '{"pkg":"%s","status":"%s","event":"%s","rc":%s,"cr":%s,"ts":%s,"cpu":"%s","ram":"%s","temp":"%s"}\n' \
        "$pkg" "$status" "$event" "${rc:-0}" "${cr:-0}" "$now" \
        "${cpu:-?}" "${ram:-?}" "${temp:-?}" > "$sf" 2>/dev/null
}

write_dashboard_event() {
    local pkg=$1 event=$2 type=${3:-info}
    mkdir -p "$DASH_DIR" 2>/dev/null
    local ef="${DASH_DIR}/${pkg//[^a-zA-Z0-9]/_}_events.jsonl"
    local now ts
    now=$(date +%s); ts=$(date '+%H:%M:%S')
    printf '{"ts":%s,"t":"%s","type":"%s","ev":"%s"}\n' \
        "$now" "$ts" "$type" "${event//\"/\'}" >> "$ef" 2>/dev/null
    # Trim ke 30 baris terakhir
    local lc; lc=$(wc -l < "$ef" 2>/dev/null || echo 0)
    [ "$lc" -gt 30 ] && tail -30 "$ef" > "${ef}.tmp" && mv "${ef}.tmp" "$ef"
}

# ─────────────────────────────────────────
#   CAPTURE SCREEN — multiple fallback methods
# ─────────────────────────────────────────
capture_screen() {
    local out_file=$1
    mkdir -p "$(dirname "$out_file")" 2>/dev/null

    # Method 1: direct screencap (via PATH)
    screencap -p "$out_file" 2>/dev/null
    if [ -s "$out_file" ]; then return 0; fi

    # Method 2: full path
    /system/bin/screencap -p "$out_file" 2>/dev/null
    if [ -s "$out_file" ]; then return 0; fi

    # Method 3: su 2000 (shell UID — works when root screencap blocked)
    su 2000 -c "screencap -p '$out_file'" 2>/dev/null
    if [ -s "$out_file" ]; then return 0; fi

    # Method 4: su system
    su system -c "screencap -p '$out_file'" 2>/dev/null
    if [ -s "$out_file" ]; then return 0; fi

    # Method 5: python subprocess
    python -c "
import subprocess, sys
with open('$out_file', 'wb') as f:
    try:
        subprocess.run(['/system/bin/screencap', '-p'], stdout=f, check=True)
    except: sys.exit(1)
" 2>/dev/null
    if [ -s "$out_file" ]; then return 0; fi

    return 1
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

    # force-stop: coba am force-stop dulu, kalau ROM tidak support
    # (Error: unknown command 'force-stop') fallback ke kill -9 semua PID
    # yang milik package ini — termasuk child process render/RCC/dll
    if ! am force-stop "$pkg" 2>/dev/null; then
        ps -ef 2>/dev/null \
            | awk -v p="$pkg" '$0 ~ p && !/awk/ && !/grep/ {print $2}' \
            | xargs -r kill -9 2>/dev/null
    fi
    # Tunggu proses benar-benar mati sebelum am start
    sleep 1
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
    tmp_ip=$(timeout "${WAIT_INGAME_TIMEOUT:-120}" logcat -b main -b system -v time 2>/dev/null \
        | grep --line-buffered -iE "Connection accepted from|NetworkClient.*connected|RobloxNetworkHandler.*Join" \
        | head -1 \
        | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" \
        | head -1)

    if [ -n "$tmp_ip" ]; then
        log "✅ INGAME via logcat! IP: $tmp_ip" "success"
            update_dashboard_state "$pkg" "online" "Ingame via logcat - IP: $tmp_ip"
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
                log "✅ INGAME via PID+Activity (fallback)" "success"
                update_dashboard_state "$pkg" "online" "Ingame via fallback detect"
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

    log "🔁 Tight-monitor ${VERIFY_STABLE_DURATION:-20}s pasca-join (join lock aktif)..."
    while [ $checks -lt "${VERIFY_STABLE_DURATION:-20}" ]; do
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
    log "✅ Stabil pasca-join — crash_monitor aktif kembali" "success"
    update_dashboard_state "$pkg" "online" "Stabil pasca-join"
}

monitor_events() {
    # DINONAKTIFKAN: Roblox tidak mengirim string "Sending disconnect",
    # "Connection lost", "Disconnected from server" ke logcat — monitor
    # ini tidak pernah fire untuk event yang sebenarnya.
    # Deteksi disconnect sekarang via:
    #   - ocr_error_monitor (PIL pixel analysis dialog di layar)
    #   - crash_monitor + logcat_crash_detector (PID hilang / System.exit)
    while true; do sleep 86400; done
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

                log "💥 CRASH DETECTED — $pkg tidak ditemukan (PID hilang)" "error"
                update_dashboard_state "$pkg" "crashed" "Crash: PID hilang"
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

        # _seen_joining flag — sama seperti error_code_monitor:
        # kalau join pernah aktif di iterasi ini, saat is_joining → false
        # langsung break → outer loop restart dengan start_ts baru →
        # buffer crash dari sesi join sebelumnya tidak pernah diproses.
        local _seen_joining=0
        local _last_join_log=0   # rate-limit log "join berlangsung"

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
                if is_joining "$pkg"; then
                    _seen_joining=1
                    # Rate-limit: hanya log sekali per 60 detik — cegah spam
                    # saat ada banyak baris buffered crash masuk sekaligus
                    local _now; _now=$(date +%s)
                    if [ $(( _now - _last_join_log )) -gt 60 ]; then
                        log "⏭️ logcat_detector: join sedang berlangsung — abaikan crash signal ($reason)"
                        _last_join_log=$_now
                    fi
                    continue
                fi

                # Join BARU SELESAI → buang sisa buffer crash dari sesi join
                if [ "$_seen_joining" = "1" ]; then
                    _seen_joining=0
                    log "⏭️ logcat_detector: join baru selesai — reset pipe (buang buffer crash)"
                    break
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
                        # Cooldown 30s setelah sub-process ignore — private server
                        # loading spawn/kill banyak sub-process berurutan, tanpa ini
                        # log spam terus dan CPU habis untuk cek PID berulang.
                        sleep 30
                        continue
                    fi
                fi

                # Cegah race condition dengan crash_monitor
                if ! acquire_crash_lock "$pkg"; then
                    log "⏭️ logcat_detector: crash_monitor sudah handle — skip ($reason)"
                    continue
                fi

                log "💥 CRASH DETECTED via logcat — $reason (PID utama terkonfirmasi hilang)" "error"
                update_dashboard_state "$pkg" "crashed" "Crash via logcat: $reason"
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
#   STUCK WATCHDOG — deteksi Roblox hidup tapi diam (dialog error)
# ─────────────────────────────────────────
# Kenapa fungsi ini ada:
#   Di MuMu Player (dan emulator lain yang strip logcat), error code
#   277/278/279/282/529 TIDAK muncul di logcat sama sekali — sudah
#   dikonfirmasi. Satu-satunya hal yang bisa dideteksi dari luar adalah:
#   PID Roblox MASIH HIDUP tapi network activity-nya NOL (stuck di dialog
#   error, user tidak bisa ngapa-ngapain, perlu rejoin manual).
#
#   Cara kerjanya:
#   1. Pantau file /proc/PID/net/dev (statistik paket RX/TX per interface)
#      setiap CHECK_INTERVAL detik.
#   2. Kalau counter RX TIDAK BERUBAH selama STUCK_WATCHDOG_TIMEOUT detik
#      + PID masih hidup + lagi INGAME (bukan lagi di fase join/loading)
#      → Roblox stuck → force-stop → rejoin.
#   3. Kalau /proc/PID/net/dev tidak bisa dibaca (MuMu restrict /proc antar
#      proses) → fallback ke cek waktu modifikasi file state Roblox di
#      /data/data/com.roblox.client/files/ atau /sdcard/Android/data/.
#      Kalau itu juga gak bisa → fallback terakhir: cek apakah activity
#      foreground masih Roblox via `cmd activity` atau `am stack`.
#
#   Kenapa tidak pakai timer join lock saja:
#   join_lock punya timeout (JOIN_LOCK_TIMEOUT) tapi itu untuk fase LOADING —
#   kalau Roblox sudah berhasil masuk game lalu 30 menit kemudian disconnect,
#   join lock sudah lama dilepas dan crash_monitor tidak akan trigger karena
#   PID-nya masih ada. Stuck watchdog mengisi celah ini.
stuck_watchdog() {
    local pkg=$1
    local cfg_file=$2

    local last_rx=0
    local stuck_since=0
    local is_stuck=0

    log "🔍 stuck_watchdog: mulai memantau $pkg (timeout: ${STUCK_WATCHDOG_TIMEOUT}s)"

    while true; do
        sleep "$CHECK_INTERVAL"

        # Skip kalau lagi proses join/loading — normal kalau diam saat loading
        if is_joining "$pkg"; then
            last_rx=0
            stuck_since=0
            is_stuck=0
            continue
        fi

        # Cek PID masih hidup
        local pid
        pid=$(get_pid_for_pkg "$pkg")
        if [ -z "$pid" ]; then
            # PID mati → crash_monitor yang handle, kita reset saja
            last_rx=0
            stuck_since=0
            is_stuck=0
            continue
        fi

        # ── Coba baca network RX — per-UID, bukan system-wide ───────────
        # v3.1 FIX: sebelumnya pakai /proc/$pid/net/dev yang SAMA dengan
        # /proc/net/dev (statistik SELURUH SISTEM, bukan per-proses/per-UID).
        # Akibatnya current_rx SELALU naik (dari traffic app lain, background
        # services, WiFi keep-alive dll) → condition "rx tidak berubah" TIDAK
        # PERNAH true → stuck_watchdog tidak pernah trigger, jadi gimmick.
        # FIX: pakai per-UID stats:
        #   1. /proc/net/xt_qtaguid/stats (Android 5-10, kolom 4=uid, 6=rx_bytes)
        #   2. /proc/uid_stat/<uid>/tcp_rcv (Android 4.x - beberapa 11)
        # Keduanya hanya counting traffic milik UID Roblox — kalau Roblox
        # stuck di dialog error (tidak menerima game data), counter diam.
        local current_rx=""
        local _uid=""
        [ -n "$pid" ] && _uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)

        if [ -n "$_uid" ]; then
            if [ -f "/proc/net/xt_qtaguid/stats" ]; then
                current_rx=$(awk -v u="$_uid" '$4==u{s+=$6}END{print s+0}' \
                    /proc/net/xt_qtaguid/stats 2>/dev/null)
            fi
            if [ -z "$current_rx" ] || [ "$current_rx" = "0" ]; then
                if [ -f "/proc/uid_stat/${_uid}/tcp_rcv" ]; then
                    current_rx=$(cat "/proc/uid_stat/${_uid}/tcp_rcv" 2>/dev/null)
                fi
            fi
        fi

        # ── Fallback 1: cek mtime file data Roblox ───────────────────────
        if [ -z "$current_rx" ] || [ "$current_rx" = "0" ]; then
            # Kalau /proc tidak bisa dibaca, cek kapan terakhir file Roblox dimodif
            # (Roblox nulis ke storage saat aktif bermain — autosave, log internal, dll)
            local roblox_data_dir="/sdcard/Android/data/${pkg}"
            if [ -d "$roblox_data_dir" ]; then
                local newest_mtime
                newest_mtime=$(find "$roblox_data_dir" -maxdepth 3 -type f \
                    -newer "${STATE_BASE_DIR}/rbx_state_${pkg}/last_activity_check" \
                    2>/dev/null | wc -l)
                # Kalau ada file yang lebih baru dari last check → masih aktif
                if [ "${newest_mtime:-0}" -gt 0 ]; then
                    touch "${STATE_BASE_DIR}/rbx_state_${pkg}/last_activity_check" 2>/dev/null
                    last_rx=1   # gunakan dummy non-zero buat reset stuck counter
                    current_rx=1
                fi
            fi
        fi

        # ── Evaluasi stuck ────────────────────────────────────────────────
        if [ -z "$current_rx" ] || [ "$current_rx" = "0" ]; then
            # Tidak bisa baca rx sama sekali (MuMu restrict semua method)
            # Jangan false-positive — skip watchdog untuk device ini
            continue
        fi

        local now
        now=$(date +%s)

        if [ "$current_rx" = "$last_rx" ] && [ "$last_rx" != "0" ]; then
            # RX tidak berubah sejak check terakhir
            if [ "$is_stuck" = "0" ]; then
                stuck_since=$now
                is_stuck=1
            fi

            local stuck_duration=$(( now - stuck_since ))
            if [ "$stuck_duration" -ge "$STUCK_WATCHDOG_TIMEOUT" ]; then
                # Sudah stuck terlalu lama → kemungkinan besar dialog error
                if ! acquire_crash_lock "$pkg"; then
                    log "⏭️ stuck_watchdog: handler lain sedang jalan — skip"
                    is_stuck=0
                    stuck_since=0
                    continue
                fi

                log "🚨 Roblox STUCK ${stuck_duration}s tanpa network activity — kemungkinan dialog Error Code (277/278/279/282/529) — auto-rejoin!"
                send_discord_notification "disconnect" "Stuck ${stuck_duration}s tanpa network (Error Code?)" "$pkg"

                sleep 2
                source "$cfg_file" 2>/dev/null || true

                if [ "${DETEKSI_ERROR_CODE:-1}" != "1" ]; then
                    log "ℹ️ DETEKSI_ERROR_CODE=OFF — tidak auto-rejoin"
                    release_crash_lock "$pkg"
                    is_stuck=0
                    stuck_since=0
                    last_rx=0
                    continue
                fi

                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE"
                wait_ingame "$pkg"
                verify_ingame_stable "$pkg" "$cfg_file"
                release_crash_lock "$pkg"

                # Reset counter setelah rejoin
                is_stuck=0
                stuck_since=0
                last_rx=0
            fi
        else
            # RX berubah → Roblox masih aktif terima data → reset stuck counter
            is_stuck=0
            stuck_since=0
            last_rx=$current_rx
        fi

        # Update last_activity_check buat fallback mtime
        mkdir -p "${STATE_BASE_DIR}/rbx_state_${pkg}" 2>/dev/null
        touch "${STATE_BASE_DIR}/rbx_state_${pkg}/last_activity_check" 2>/dev/null

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
    # DINONAKTIFKAN: deteksi error code sekarang via OCR (ocr_error_monitor).
    # Logcat-based detection terlalu banyak false positive dari buffer replay
    # saat transisi server — error code 275/529 dari proses JOIN ke-detect
    # sebagai disconnect asli. OCR baca pixel layar langsung → hanya fire
    # kalau dialog error BENAR-BENAR tampil di layar sekarang.
    # Sleep infinity agar keep-alive tidak restart terus (proses tetap "hidup").
    while true; do sleep 86400; done
}


# ─────────────────────────────────────────
#   OCR ERROR CODE MONITOR
#   Baca layar langsung via screencap + tesseract.
#
#   Kenapa perlu ini (padahal sudah ada error_code_monitor):
#     Dialog "Disconnected (Error Code: NNN)" di Roblox di-render di dalam
#     GL surface (game engine canvas), BUKAN native Android View. Jadi:
#     - uiautomator dump → tidak bisa baca teks ini
#     - logcat → KADANG tidak muncul, tergantung versi Roblox / ROM
#     - screencap + OCR → baca pixel layar langsung → SELALU akurat
#       karena yang dibaca persis apa yang user lihat di layar
#
#   Cara kerja:
#     Setiap OCR_INTERVAL detik:
#     1. Cek Roblox masih running & di foreground
#     2. screencap → /data/local/tmp/rbx_ocr_<pkg>.png
#     3. tesseract OCR → cari pola "Error Code NNN" atau "Error NNN"
#     4. Kalau ketemu → acquire crash_lock → rejoin
#
#   Requirement:
#     pkg install tesseract  (di Termux)
#     tesseract akan otomatis skip kalau tidak terinstall
# ─────────────────────────────────────────

ocr_error_monitor() {
    local pkg=$1
    local cfg_file=$2

    mkdir -p "$SCREENSHOT_DIR" 2>/dev/null

    local PYTHON=""
    command -v python3 >/dev/null 2>&1 && PYTHON="python3"
    command -v python  >/dev/null 2>&1 && PYTHON="${PYTHON:-python}"

    if [ -z "$PYTHON" ]; then
        log "⚠️ ocr_error_monitor: python tidak tersedia — idle"
        while true; do sleep 86400; done; return
    fi

    if ! $PYTHON -c "from PIL import Image" 2>/dev/null; then
        log "⚠️ ocr_error_monitor: Pillow tidak tersedia — idle"
        while true; do sleep 86400; done; return
    fi

    local ocr_interval=45
    local safe_pkg="${pkg//[^a-zA-Z0-9]/_}"
    local py_file="/data/local/tmp/rbx_pil_${safe_pkg}.py"
    local debug_log="${SCREENSHOT_DIR}/_pixel_grid_${safe_pkg}.log"

    cat > "$py_file" << 'PYEOF'
import sys, os
try:
    from PIL import Image
except ImportError:
    print("ERROR:NO_PIL"); sys.exit(0)

scr = sys.argv[1]
if not os.path.exists(scr):
    print("ERROR:FILE_NOT_FOUND"); sys.exit(0)

try:
    img = Image.open(scr).convert('RGB')
    w, h = img.size

    cols, rows = 6, 6
    x_start = int(w * 0.10)
    x_end   = int(w * 0.90)
    y_start = int(h * 0.10)
    y_end   = int(h * 0.85)
    cell_w = max(1, (x_end - x_start) // cols)
    cell_h = max(1, (y_end - y_start) // rows)

    grid_grey  = [[0]*cols for _ in range(rows)]
    grid_white = [[0]*cols for _ in range(rows)]

    for r in range(rows):
        for c in range(cols):
            cx1 = x_start + c * cell_w
            cy1 = y_start + r * cell_h
            cx2 = min(cx1 + cell_w, w)
            cy2 = min(cy1 + cell_h, h)
            region = img.crop((cx1, cy1, cx2, cy2))
            pixels = list(region.getdata())
            total = len(pixels)
            if total == 0:
                continue
            grey_cnt = 0
            white_cnt = 0
            for pix in pixels:
                greyness = abs(pix[0]-pix[1]) + abs(pix[1]-pix[2]) + abs(pix[2]-pix[0])
                if greyness < 60:
                    brightness = (pix[0] + pix[1] + pix[2]) / 3.0
                    if 30 <= brightness <= 100:
                        grey_cnt += 1
                    elif brightness > 200:
                        white_cnt += 1
            grid_grey[r][c]  = grey_cnt / total if total else 0
            grid_white[r][c] = white_cnt / total if total else 0

    center_grey  = 0
    center_white = 0
    center_total = 0
    for r in range(1, rows-1):
        for c in range(1, cols-1):
            center_total += 1
            if grid_grey[r][c] > 0.15:
                center_grey += 1
            if grid_white[r][c] > 0.03:
                center_white += 1

    grey_ratio  = center_grey  / center_total if center_total else 0
    white_ratio = center_white / center_total if center_total else 0

    dbg = f"GREY:{grey_ratio:.3f}:WHITE:{white_ratio:.3f}"
    logfile = os.path.join(os.path.dirname(scr), "_pixel_grid_" + os.path.basename(scr).replace(".png","") + ".log")
    with open(logfile, "w") as f:
        f.write(dbg + "\n== GREY grid ==\n")
        for r in range(rows):
            f.write(" ".join(f"{grid_grey[r][c]:.2f}" for c in range(cols)) + "\n")
        f.write("== WHITE grid ==\n")
        for r in range(rows):
            f.write(" ".join(f"{grid_white[r][c]:.2f}" for c in range(cols)) + "\n")

    if grey_ratio > 0.35 and white_ratio > 0.05:
        print(f"DIALOG:{dbg}")
    else:
        print(f"CLEAR:{dbg}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF

    log "📸 ocr_error_monitor: aktif (PIL 6x6 grid, interval ${ocr_interval}s, debug: ${SCREENSHOT_DIR})"

    while true; do
        sleep "$ocr_interval"
        is_joining "$pkg" && continue

        local pid
        pid=$(get_pid_for_pkg "$pkg")
        [ -z "$pid" ] && continue

        local fg
        fg=$(dumpsys activity top 2>/dev/null | grep -E "ACTIVITY|mResumedActivity" | head -5)
        echo "$fg" | grep -q "$pkg" || continue

        input keyevent KEYCODE_WAKEUP 2>/dev/null
        sleep 0.3

        local ts; ts=$(date '+%Y%m%d_%H%M%S')
        local debug_scr="${SCREENSHOT_DIR}/${ts}_${safe_pkg}.png"

        if ! capture_screen "$debug_scr"; then
            log "⚠️ ocr_error_monitor: capture_screen gagal"
            continue
        fi

        local result
        result=$($PYTHON "$py_file" "$debug_scr" 2>&1)

        # Cleanup old screenshots — keep last 100
        ls -t "${SCREENSHOT_DIR}"/*.png 2>/dev/null | tail -n +101 | xargs -r rm -f 2>/dev/null

        case "${result%%:*}" in
            DIALOG)
                log "📸 DIALOG DETECTED: ${result}" "warning"
                is_joining "$pkg" && continue
                acquire_crash_lock "$pkg" || continue
                send_discord_notification "disconnect" "Disconnect dialog detected" "$pkg"
                sleep 3
                source "$cfg_file" 2>/dev/null
                local active_url
                active_url=$(get_active_url "$MODE" "$URL")
                join_server "$pkg" "$active_url" "$MODE"
                wait_ingame "$pkg"
                verify_ingame_stable "$pkg" "$cfg_file"
                release_crash_lock "$pkg"
                ;;
            CLEAR) ;;
            ERROR*)
                log "⚠️ PIL error: ${result}"
                ;;
        esac
    done

    rm -f "$py_file" 2>/dev/null
}

# ─────────────────────────────────────────
#   OPEN SECOND PACKAGE (menggunakan perbaikan)
# ─────────────────────────────────────────

open_second_package() {
    if [ "$USE_MULTI_PKG" != "1" ] || [ -z "$PKG2" ]; then
        return
    fi

    local cfg1="${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
    local auto_grid

    # Baca AUTO_GRID dari config PKG1
    if [ -f "$cfg1" ]; then
        auto_grid=$(grep '^AUTO_GRID=' "$cfg1" | head -1 | cut -d= -f2)
    fi
    auto_grid="${auto_grid:-0}"

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

    if [ "$auto_grid" = "1" ] && [ -n "$PKG1" ]; then
        # Auto Grid: arrange PKG1 (left) + PKG2 (right) in freeform
        local active_url1
        local cfg1_mode cfg1_url
        cfg1_mode=$(grep '^MODE=' "$cfg1" | head -1 | cut -d'"' -f2)
        cfg1_url=$(grep '^URL=' "$cfg1" | head -1 | cut -d'"' -f2)
        active_url1=$(get_active_url "$cfg1_mode" "$cfg1_url")
        auto_grid_arrange "$PKG1" "$active_url1" "$PKG2" "$active_url2"
    else
        # Standard: floating window for PKG2 only
        try_floating_window "$PKG2" "$active_url2"
    fi
}

# ─────────────────────────────────────────
#   MAIN
# ─────────────────────────────────────────

ensure_deps() {
    echo "🔧 Cek dependency..."

    # Pillow WAJIB via pkg, bukan pip — pip akan compile dari source
    # (butuh C compiler, bisa 5-10 menit, dan sering gagal di ARM karena
    # ABI mismatch). pkg install pakai pre-built binary → selesai < 10 detik.
    pkg install -y curl wget bash coreutils procps termux-tools \
        python android-tools tsu figlet sqlite python-pillow 2>&1 \
        | grep -E "^(Unpacking|Setting up|is already)" \
        | while read -r l; do echo "   $l"; done

    # rich dan pyfiglet = pure Python (tidak ada C extension) → pip aman dan cepat
    local pip_needed=""
    python -c "from rich.console import Console" 2>/dev/null || pip_needed="$pip_needed rich"
    python -c "import pyfiglet"                 2>/dev/null || pip_needed="$pip_needed pyfiglet"

    if [ -n "$pip_needed" ]; then
        echo "   📦 pip install$pip_needed..."
        pip install --quiet $pip_needed
    fi

    echo "✅ Dependency OK"
    echo ""
}

if [ "$(id -u)" != "0" ]; then
    echo "⚠️ Requesting root..."
    exec su -c "$0"
fi

ensure_deps

# Tulis Python dashboard script ke ~/rbx_dashboard.py
write_dashboard_script() {
    cat > "$HOME/rbx_dashboard.py" << 'DASHEOF'
#!/usr/bin/env python3
"""
RBX Monitor Dashboard — by Wardz
Jalankan di session Termux terpisah:
  python ~/rbx_dashboard.py com.roblox.client
"""
import json, os, sys, time
from datetime import datetime

try:
    from rich.console import Console
    from rich.live import Live
    from rich.table import Table
    from rich.panel import Panel
    from rich.columns import Columns
    from rich.text import Text
    from rich.align import Align
    from rich.rule import Rule
    from rich import box
    from rich.console import Group
except ImportError:
    print("Install: pip install rich"); sys.exit(1)

try:
    import pyfiglet
    HEADER = pyfiglet.figlet_format("RBX Monitor", font="small").rstrip()
except ImportError:
    HEADER = "  RBX MONITOR"

DASH_DIR = "/data/local/tmp/rbx_dash"
REFRESH  = 3

STATUS_STYLE = {
    "online":  ("bright_green", "●  INGAME"),
    "offline": ("yellow",       "○  OFFLINE"),
    "joining": ("cyan",         "⟳  JOINING"),
    "crashed": ("red",          "✗  CRASH"),
    "idle":    ("dim",          "–  IDLE"),
}

def read_state(pkg):
    sf = os.path.join(DASH_DIR, pkg.replace(".", "_") + ".json")
    try:
        with open(sf) as f: return json.load(f)
    except: return {}

def read_events(pkg, n=6):
    ef = os.path.join(DASH_DIR, pkg.replace(".", "_") + "_events.jsonl")
    try:
        lines = open(ef).readlines()
        return [json.loads(l) for l in lines[-n:]]
    except: return []

def sys_stats():
    cpu = ram = temp = "N/A"
    try:
        tok = open("/proc/stat").readline().split()[1:]
        vals = [int(x) for x in tok]
        idle = vals[3]; total = sum(vals)
        cpu = f"{max(0, round(100*(1-idle/total)))}%" if total else "N/A"
    except: pass
    try:
        mem = {}
        for l in open("/proc/meminfo"):
            if ":" in l:
                k, v = l.split(":", 1)
                mem[k.strip()] = int(v.split()[0])
        free  = mem.get("MemAvailable", 0) // 1024
        total = mem.get("MemTotal", 0) // 1024
        pct   = round(free / total * 100) if total else 0
        ram   = f"{free}MB ({pct}%)"
    except: pass
    for tz in ["/sys/class/thermal/thermal_zone0/temp",
               "/sys/class/thermal/thermal_zone1/temp"]:
        try:
            t = int(open(tz).read().strip())
            temp = f"{t//1000}°C"; break
        except: pass
    return cpu, ram, temp

def uptime_str(since_ts):
    try:
        s = int(time.time() - float(since_ts))
        h, r = divmod(s, 3600); m, sec = divmod(r, 60)
        return f"{h:02d}:{m:02d}:{sec:02d}"
    except: return "--:--:--"

def build(pkgs):
    hdr = Align.center(
        f"[bold cyan]{HEADER}[/bold cyan]\n"
        f"[dim]by Wardz  •  {datetime.now():%H:%M:%S}[/dim]"
    )

    panels = []
    for pkg in pkgs:
        st    = read_state(pkg)
        skey  = st.get("status", "idle")
        color, label = STATUS_STYLE.get(skey, ("white", skey.upper()))
        short = pkg.split(".")[-1] if "." in pkg else pkg

        info = Table.grid(padding=(0, 1))
        info.add_column(style="bold dim", min_width=10)
        info.add_column()
        info.add_row("Status",  f"[{color}]{label}[/{color}]")
        info.add_row("Uptime",  uptime_str(st.get("ts")) if skey == "online" else "–")
        info.add_row("Mode",    (st.get("mode") or "–").title())
        if st.get("cpu"): info.add_row("CPU", st["cpu"])
        if st.get("ram"): info.add_row("RAM", st["ram"])

        ctr = Table(box=None, show_header=True, header_style="bold",
                    padding=(0, 2))
        ctr.add_column("🔄 Reconnect", justify="center")
        ctr.add_column("💀 Crash",     justify="center")
        ctr.add_row(
            f"[cyan]{st.get('rc', 0)}[/cyan]",
            f"[red]{st.get('cr', 0)}[/red]",
        )

        panels.append(Panel(
            Group(info, "", ctr),
            title=f"[bold]{short}[/bold]",
            border_style=color, padding=(0, 1)
        ))

    pkg_cols = Columns(panels, equal=True, expand=True) if panels \
               else Panel("[dim]Menunggu data...[/dim]", border_style="dim")

    ev_lines = []
    for pkg in pkgs:
        for ev in read_events(pkg):
            t     = ev.get("t", "?")
            msg   = ev.get("ev", "")[:72]
            etype = ev.get("type", "info")
            c = {"success": "green", "error": "red",
                 "warning": "yellow"}.get(etype, "white")
            ev_lines.append(f"[dim]{t}[/dim]  [{c}]{msg}[/{c}]")
    ev_text = "\n".join(ev_lines[-7:]) if ev_lines \
              else "[dim]Belum ada event[/dim]"
    ev_panel = Panel(ev_text, title="📝 Events",
                     border_style="dim", padding=(0, 1))

    cpu, ram, temp = sys_stats()
    sg = Table.grid(padding=(0, 3))
    sg.add_column(); sg.add_column(); sg.add_column()
    sg.add_row(
        f"CPU  [bold cyan]{cpu}[/bold cyan]",
        f"RAM  [bold cyan]{ram}[/bold cyan]",
        f"Temp [bold cyan]{temp}[/bold cyan]",
    )
    sys_panel = Panel(sg, title="🖥️ System",
                      border_style="dim", padding=(0, 1))

    footer = Align.center(
        f"[dim]Refresh {REFRESH}s  •  Ctrl+C keluar[/dim]")

    return Group(hdr, Rule(style="dim"),
                 pkg_cols, ev_panel, sys_panel, footer)

if __name__ == "__main__":
    pkgs = sys.argv[1:] if len(sys.argv) > 1 else ["com.roblox.client"]
    console = Console()
    try:
        with Live(console=console, refresh_per_second=1/REFRESH,
                  screen=True) as live:
            while True:
                try: live.update(build(pkgs))
                except Exception: pass
                time.sleep(REFRESH)
    except KeyboardInterrupt:
        pass
DASHEOF
    chmod +x "$HOME/rbx_dashboard.py"
}
write_dashboard_script

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
AUTO_GRID_ENABLED="${AUTO_GRID:-0}"

# Create debug screenshot directory
mkdir -p "$SCREENSHOT_DIR" 2>/dev/null

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
log "Deteksi Error Code: $(show_toggle ${DETEKSI_ERROR_CODE:-1}) (stuck watchdog: ${STUCK_WATCHDOG_TIMEOUT}s)"
log "Auto Grid        : $(show_toggle $AUTO_GRID_ENABLED)"
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

# ── Cleanup stale lock files dari sesi sebelumnya ────────────────────────
# Kalau script di-kill paksa saat join (CTRL+C, reboot, OOM), join_lock
# dan crash_lock tertinggal → is_joining stuck true → monitor tidak aktif.
find "${STATE_BASE_DIR}" -name "join_lock_*" -delete 2>/dev/null
find "${STATE_BASE_DIR}" -name "crash_lock_*" -delete 2>/dev/null

# ── Generate Python dashboard script ─────────────────────────────────────
mkdir -p "$DASH_DIR" 2>/dev/null
cat > "${DASH_DIR}/dashboard.py" << 'PYEOF'
#!/usr/bin/env python3
import json, time, os, sys
from datetime import datetime
try:
    from rich.live        import Live
    from rich.table       import Table
    from rich.panel       import Panel
    from rich.layout      import Layout
    from rich.console     import Console
    from rich.text        import Text
    from rich.align       import Align
    from rich.columns     import Columns
    RICH = True
except ImportError:
    RICH = False

try:
    from pyfiglet import Figlet
    FIGLET = True
except ImportError:
    FIGLET = False

PKG      = sys.argv[1] if len(sys.argv) > 1 else ""
DASH_DIR = "/data/local/tmp/rbx_dash"
SAFE     = lambda p: ''.join(c if c.isalnum() else '_' for c in p)

def pkgs():
    files = [f for f in os.listdir(DASH_DIR) if f.endswith('.json') and not f.startswith('dashboard')]
    return [f[:-5] for f in files]

def state(pkg):
    try:
        with open(f"{DASH_DIR}/{pkg}.json") as f:
            return json.load(f)
    except:
        return {"pkg": pkg, "status": "unknown", "event": "-",
                "rc": 0, "cr": 0, "ts": 0, "cpu": "?", "ram": "?", "temp": "?"}

def events(pkg, n=10):
    try:
        with open(f"{DASH_DIR}/{pkg}_events.jsonl") as f:
            lines = f.readlines()
        result = []
        for line in reversed(lines):
            try: result.append(json.loads(line.strip()))
            except: pass
            if len(result) >= n: break
        return result
    except:
        return []

def uptime(ts):
    if not ts: return "?"
    s = max(0, int(time.time()) - int(ts))
    h, r = divmod(s, 3600)
    m, _ = divmod(r, 60)
    return f"{h}j {m}m"

STATUS_COLOR = {"online": "green", "offline": "red", "crashed": "red",
                "joining": "yellow", "unknown": "dim"}
STATUS_ICON  = {"online": "●", "offline": "○", "crashed": "✖",
                "joining": "◌", "unknown": "?"}
EVENT_ICON   = {"success": "✅", "error": "❌", "warning": "⚠️", "info": "ℹ️"}

def make_layout():
    all_pkgs = pkgs() or ([SAFE(PKG)] if PKG else ["unknown"])

    # Header
    if FIGLET:
        hdr = Figlet(font='small').renderText('SPHINX')
    else:
        hdr = 'SPHINX MONITOR'

    header_panel = Panel(
        Align.center(Text(hdr.rstrip(), style="bold cyan")),
        subtitle=f"[dim]Roblox Auto Reconnect  |  {datetime.now().strftime('%H:%M:%S')}",
        border_style="bright_blue", padding=(0, 2)
    )

    pkg_panels = []
    all_events = []

    for p in all_pkgs:
        s = state(p)
        st  = s.get("status", "unknown")
        col = STATUS_COLOR.get(st, "dim")
        ico = STATUS_ICON.get(st, "?")

        t = Table.grid(padding=(0, 2))
        t.add_column(style="bold dim", width=12)
        t.add_column()
        t.add_row("Status",   Text(f"{ico} {st.upper()}", style=f"bold {col}"))
        t.add_row("Package",  Text(s.get("pkg", p), style="dim", overflow="fold"))
        t.add_row("Uptime",   uptime(s.get("ts", 0)))
        t.add_row("Reconnect",Text(f"🔄 {s.get('rc',0)}x", style="cyan"))
        t.add_row("Crash",    Text(f"💥 {s.get('cr',0)}x", style="red"))
        t.add_row("",         "")
        t.add_row("CPU",      Text(s.get("cpu","?"), style="yellow"))
        t.add_row("RAM",      Text(s.get("ram","?"), style="yellow"))
        t.add_row("Suhu",     Text(s.get("temp","?"), style="yellow"))
        t.add_row("",         "")
        t.add_row("Last",     Text(s.get("event","-"), style="italic dim", overflow="fold"))

        pkg_panels.append(Panel(t, title=f"[bold]{s.get('pkg',p)[-25:]}",
                                border_style=col, padding=(0,1)))
        all_events.extend(events(p, 10))

    all_events.sort(key=lambda e: e.get("ts", 0), reverse=True)

    ev_table = Table(show_header=False, box=None, padding=(0,1), expand=True)
    ev_table.add_column(style="dim", width=9, no_wrap=True)
    ev_table.add_column(width=3,  no_wrap=True)
    ev_table.add_column(overflow="fold")
    for ev in all_events[:12]:
        tp = ev.get("type","info")
        ev_table.add_row(
            ev.get("t",""),
            EVENT_ICON.get(tp,"ℹ️"),
            Text(ev.get("ev","-"),
                 style=("green" if tp=="success" else "red" if tp=="error" else "dim"))
        )

    layout = Layout()
    layout.split_column(
        Layout(header_panel, name="header", size=6 if FIGLET else 4),
        Layout(name="main"),
        Layout(Panel(ev_table, title="[bold]Recent Events", border_style="dim"),
               name="events", size=min(len(all_events)+2, 14)),
    )
    layout["main"].update(Columns(pkg_panels, equal=True, expand=True))
    return layout

if __name__ == "__main__":
    if not RICH:
        print("Install rich dulu: pip install rich")
        sys.exit(1)
    console = Console()
    console.print(f"[dim]Dashboard: {DASH_DIR}  |  Ctrl+C untuk keluar[/dim]")
    try:
        with Live(make_layout(), refresh_per_second=1, screen=True, console=console) as live:
            while True:
                time.sleep(2)
                live.update(make_layout())
    except KeyboardInterrupt:
        console.print("\n[dim]Dashboard ditutup.[/dim]")
PYEOF
chmod +x "${DASH_DIR}/dashboard.py" 2>/dev/null

log "🚀 Ready untuk monitoring"
echo ""

# Abaikan SIGHUP
trap '' SIGHUP

# PID files agar keep-alive subshell bisa track + restart monitor
RBX_PID_DIR="/data/local/tmp/rbx_pids_${PKG1//[^a-zA-Z0-9]/_}"
mkdir -p "$RBX_PID_DIR" 2>/dev/null

_mon_start() {
    local name=$1; shift
    "$@" &
    echo $! > "$RBX_PID_DIR/$name"
}

_mon_alive() {
    local pid; pid=$(cat "$RBX_PID_DIR/$1" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Launch semua monitor
_mon_start monitor  monitor_events         "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
_mon_start crash    crash_monitor          "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
_mon_start logcat   logcat_crash_detector  "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
_mon_start errcode  error_code_monitor     "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
_mon_start watchdog stuck_watchdog         "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
_mon_start ocr      ocr_error_monitor      "$PKG1" "${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"

# Keep-alive di background — cek + restart monitor tiap CHECK_INTERVAL
(
    trap '' SIGHUP
    CFG="${CONFIG_BASE_DIR}/roblox_config_${PKG1}.cfg"
    while true; do
        _mon_alive monitor  || { log "⚠️ monitor_events mati — restart";        _mon_start monitor  monitor_events        "$PKG1" "$CFG"; }
        _mon_alive crash    || { log "⚠️ crash_monitor mati — restart";         _mon_start crash    crash_monitor         "$PKG1" "$CFG"; }
        _mon_alive logcat   || { log "⚠️ logcat_crash_detector mati — restart"; _mon_start logcat   logcat_crash_detector "$PKG1" "$CFG"; }
        _mon_alive errcode  || { log "⚠️ error_code_monitor mati — restart";    _mon_start errcode  error_code_monitor    "$PKG1" "$CFG"; }
        _mon_alive watchdog || { log "⚠️ stuck_watchdog mati — restart";        _mon_start watchdog stuck_watchdog        "$PKG1" "$CFG"; }
        _mon_alive ocr      || { log "⚠️ ocr_error_monitor mati — restart";     _mon_start ocr      ocr_error_monitor     "$PKG1" "$CFG"; }
        sleep "${CHECK_INTERVAL:-10}"
    done
) &
echo $! > "$RBX_PID_DIR/keepalive"

# Dashboard di foreground — tidak butuh session Termux kedua
sleep 1
if command -v python >/dev/null 2>&1; then
    log "📊 Buka dashboard: python ${DASH_DIR}/dashboard.py $PKG1"
    python "${DASH_DIR}/dashboard.py" "$PKG1"
    log "📊 Dashboard ditutup — monitoring tetap jalan"
fi

# JANGAN pernah exit — tetap di foreground agar script tidak return ke shell
# (background monitor processes bukan direct child, jadi wait tidak work)
log "🟢 Monitoring aktif — Ctrl+C dobel untuk stop total"
while true; do
    sleep 60
done