#!/usr/bin/env bash
# healthcheck.sh — диагностика 3x-ui-bot (v1.2)
# Изменения v1.2:
#   * check_service / check_timer через systemctl show -p LoadState (надёжно)
#   * jq spaces (fromjson? // {})
#   * dest'ы синхронизированы с install.sh v2.8 (sberbank/tinkoff)
#
set -uo pipefail

VERSION="1.2"
BOT_DIR="${BOT_DIR:-/opt/3x-ui-bot}"
BOT_ENV="$BOT_DIR/bot.env"
BOT_SH="$BOT_DIR/bot.sh"

SEND_TG=0; VERBOSE=0; JSON_OUT=0
for arg in "$@"; do
    case "$arg" in
        --tg)      SEND_TG=1 ;;
        --verbose) VERBOSE=1 ;;
        --json)    JSON_OUT=1 ;;
        -h|--help) cat <<EOF
Usage: $0 [--tg] [--verbose] [--json]
EOF
            exit 0 ;;
    esac
done

[ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && { echo "Нужен bash >= 4"; exit 1; }

REQUIRED_INBOUNDS=(
    "443|main-443|www.kvnos.ru:443|www.kvnos.ru"
    "993|fallback-993|imap.yandex.ru:993|imap.yandex.ru"
    "587|fallback-587|www.sberbank.ru:443|www.sberbank.ru"
    "465|fallback-465|www.tinkoff.ru:443|www.tinkoff.ru"
)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLU='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

ge_int() {
    local v="${1:-}" t="${2:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [[ "$t" =~ ^[0-9]+$ ]] || return 1
    [ "$v" -ge "$t" ]
}

get_cpu_pct() {
    local a b cpu_a idle_a cpu_b idle_b dt di tot
    a=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8+$9, $5; exit}' /proc/stat 2>/dev/null)
    sleep 0.5
    b=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8+$9, $5; exit}' /proc/stat 2>/dev/null)
    [ -z "$a" ] || [ -z "$b" ] && { echo 0; return; }
    cpu_a=${a% *}; idle_a=${a#* }
    cpu_b=${b% *}; idle_b=${b#* }
    dt=$((cpu_b - cpu_a)); di=$((idle_b - idle_a)); tot=$((dt + di))
    [ "$tot" -le 0 ] && { echo 0; return; }
    echo $(( dt * 100 / tot ))
}
get_ram_pct() {
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%d", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null
}
get_disk_pct() {
    local v; v=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}')
    [[ "$v" =~ ^[0-9]+$ ]] || v=0; echo "$v"
}
truncate_tg() {
    local s="$1" max=3900
    [ "${#s}" -gt "$max" ] && echo "${s:0:$max}…(truncated)" || echo "$s"
}

RESULTS=(); PASS=0; WARN=0; FAIL=0
add() {
    local status="$1" cat="$2" check="$3" details="${4:-}"
    RESULTS+=("$status|$cat|$check|$details")
    case "$status" in PASS) PASS=$((PASS+1));; WARN) WARN=$((WARN+1));; FAIL) FAIL=$((FAIL+1));; esac
    if [ "$VERBOSE" = 1 ]; then
        local c="$NC"
        [ "$status" = "PASS" ] && c="$GRN"
        [ "$status" = "WARN" ] && c="$YLW"
        [ "$status" = "FAIL" ] && c="$RED"
        printf "  ${c}%-4s${NC} [%s] %s%s\n" "$status" "$cat" "$check" "${details:+ — $details}"
    fi
}
section() { [ "$VERBOSE" = 1 ] && echo -e "\n${BLU}━━━ $* ━━━${NC}"; }

# ===================================================================
section "Загрузка конфигурации"
if [ -r "$BOT_ENV" ]; then
    . "$BOT_ENV"; add PASS "config" ".env" "загружен ($BOT_ENV)"
else
    add FAIL "config" ".env" "не читается: $BOT_ENV"
    echo -e "${RED}Критично: $BOT_ENV недоступен.${NC}"
fi

: "${BOT_TOKEN:=}"; : "${ADMIN_IDS:=}"
: "${XUI_SCHEME:=http}"; : "${XUI_HOST:=127.0.0.1}"; : "${XUI_PORT:=2053}"
: "${XUI_PATH:=/}"; : "${XUI_API_TOKEN:=}"
: "${XUI_DB:=/etc/x-ui/x-ui.db}"
: "${CPU_THRESHOLD:=85}"; : "${RAM_THRESHOLD:=85}"; : "${DISK_THRESHOLD:=90}"
: "${SUMMARY_HOUR:=10}"
API="${XUI_SCHEME}://${XUI_HOST}:${XUI_PORT}${XUI_PATH%/}"
CPU_TH_INT=${CPU_THRESHOLD%.*}; CPU_TH_INT=${CPU_TH_INT:-85}
RAM_TH_INT=${RAM_THRESHOLD%.*}; RAM_TH_INT=${RAM_TH_INT:-85}
DISK_TH_INT=${DISK_THRESHOLD%.*}; DISK_TH_INT=${DISK_TH_INT:-90}

# ===================================================================
section "Система"
[ -r /etc/os-release ] && . /etc/os-release && add PASS "system" "OS" "${PRETTY_NAME:-unknown}"
add PASS "system" "uptime" "$(uptime -p 2>/dev/null || echo '?')"
la=$(awk '{printf "%.2f %.2f %.2f", $1,$2,$3}' /proc/loadavg 2>/dev/null)
[ -n "$la" ] && add PASS "system" "load avg" "$la"
cpu_int=$(get_cpu_pct); [[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
ge_int "$cpu_int" "$CPU_TH_INT" && add WARN "system" "CPU usage" "${cpu_int}% ≥ ${CPU_TH_INT}%" || add PASS "system" "CPU usage" "${cpu_int}%"
ram_int=$(get_ram_pct); [[ "$ram_int" =~ ^[0-9]+$ ]] || ram_int=0
ge_int "$ram_int" "$RAM_TH_INT" && add WARN "system" "RAM usage" "${ram_int}% ≥ ${RAM_TH_INT}%" || add PASS "system" "RAM usage" "${ram_int}%"
disk_int=$(get_disk_pct); [[ "$disk_int" =~ ^[0-9]+$ ]] || disk_int=0
ge_int "$disk_int" "$DISK_TH_INT" && add WARN "system" "Disk /" "${disk_int}% ≥ ${DISK_TH_INT}%" || add PASS "system" "Disk /" "${disk_int}%"
if command -v timedatectl >/dev/null; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    case "${ntp:-?}" in
        yes) add PASS "system" "NTP sync" "synchronized" ;;
        no)  add WARN "system" "NTP sync" "не синхронизировано" ;;
        *)   add WARN "system" "NTP sync" "статус неизвестен (${ntp:-empty})" ;;
    esac
fi
add PASS "system" "bash" "${BASH_VERSION:-?}"

# ===================================================================
section "Файлы и права"
check_perm() {
    local path="$1" expected="$2" cat="$3"
    if [ ! -e "$path" ]; then add FAIL "files" "$cat" "$path отсутствует"; return; fi
    local actual; actual=$(stat -c '%a' "$path" 2>/dev/null || echo "?")
    [ "$actual" = "$expected" ] && add PASS "files" "$cat" "$path ($actual)" || add WARN "files" "$cat" "$path: $actual (≠$expected)"
}
check_perm "$BOT_DIR" "755" "BOT_DIR"
check_perm "$BOT_DIR/backups" "750" "backups dir"
check_perm "$BOT_DIR/logs" "750" "logs dir"
check_perm "$BOT_DIR/data" "755" "data dir"
check_perm "$BOT_DIR/data/pending" "755" "pending dir"
check_perm "$BOT_SH" "755" "bot.sh"
check_perm "$BOT_ENV" "600" "bot.env"
[ -f "$BOT_DIR/reality-keys.txt" ] && check_perm "$BOT_DIR/reality-keys.txt" "600" "reality-keys"
for u in 3x-ui-bot.service 3x-ui-bot-alerts.service 3x-ui-bot-snapshot.service \
         3x-ui-bot-snapshot.timer 3x-ui-bot-summary.service 3x-ui-bot-summary.timer; do
    check_perm "/etc/systemd/system/$u" "644" "unit $u"
done
if [ -f "$BOT_SH" ]; then
    bash -n "$BOT_SH" 2>/dev/null && add PASS "files" "bot.sh syntax" "OK" || add FAIL "files" "bot.sh syntax" "ошибки"
fi
if [ -r "$BOT_ENV" ]; then
    if (set -u; . "$BOT_ENV"; [ -n "${BOT_TOKEN:-}" ] && [ -n "${XUI_API_TOKEN:-}" ]) 2>/dev/null; then
        add PASS "files" ".env содержит" "BOT_TOKEN, XUI_API_TOKEN"
    else
        add FAIL "files" ".env пустые поля" "BOT_TOKEN или XUI_API_TOKEN не задан"
    fi
fi

# ===================================================================
section "Сервисы systemd"
check_service() {
    local svc="$1"
    local loaded; loaded=$(systemctl show -p LoadState --value "$svc" 2>/dev/null)
    if [ -z "$loaded" ] || [ "$loaded" = "not-found" ] || [ "$loaded" = "masked" ]; then
        add FAIL "services" "$svc" "юнит не установлен (LoadState=${loaded:-empty})"
        return
    fi
    local state enabled
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "?")
    if [ "$state" = "active" ]; then
        add PASS "services" "$svc" "active, $enabled"
    else
        local last; last=$(journalctl -u "$svc" -n 1 --no-pager 2>/dev/null | tail -1)
        add FAIL "services" "$svc" "state=$state, $enabled. last: ${last:0:80}"
    fi
}
check_service "x-ui.service"
check_service "3x-ui-bot.service"
check_service "3x-ui-bot-alerts.service"

check_timer() {
    local t="$1"
    local loaded; loaded=$(systemctl show -p LoadState --value "$t" 2>/dev/null)
    if [ -z "$loaded" ] || [ "$loaded" = "not-found" ]; then
        add FAIL "timers" "$t" "не установлен"
        return
    fi
    local state; state=$(systemctl is-active "$t" 2>/dev/null || echo "unknown")
    if [ "$state" = "active" ]; then
        local next_h; next_h=$(systemctl list-timers "$t" --no-pager 2>/dev/null | awk 'NR==2{print $1,$2}')
        add PASS "timers" "$t" "active, next: ${next_h:-?}"
    else
        add FAIL "timers" "$t" "не активен ($state)"
    fi
}
check_timer "3x-ui-bot-snapshot.timer"
check_timer "3x-ui-bot-summary.timer"

# ===================================================================
section "Telegram API"
if [ -z "$BOT_TOKEN" ]; then
    add FAIL "telegram" "Bot Token" "пуст"
else
    resp=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || echo "")
    if [ -n "$resp" ] && echo "$resp" | jq -e '.ok==true' >/dev/null 2>&1; then
        u=$(echo "$resp" | jq -r .result.username)
        add PASS "telegram" "getMe" "@${u}"
    else
        desc=$(echo "$resp" | jq -r '.description // "no response"' 2>/dev/null || echo "no response")
        add FAIL "telegram" "getMe" "$desc"
    fi
fi
if [ -z "$ADMIN_IDS" ]; then add FAIL "telegram" "ADMIN_IDS" "не задан"
else cnt=$(echo "$ADMIN_IDS" | wc -w); add PASS "telegram" "admins" "${cnt} id(s)"; fi

# ===================================================================
section "3x-ui API"
api_resp=""
if [ -z "$XUI_API_TOKEN" ]; then
    add FAIL "xui-api" "Bearer token" "пуст"
else
    api_resp=$(curl -sk --max-time 10 "${API}/panel/api/inbounds/list" \
        -H "Authorization: Bearer ${XUI_API_TOKEN}" -H "Accept: application/json" 2>/dev/null || echo "")
    if [ -n "$api_resp" ] && echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1; then
        n=$(echo "$api_resp" | jq '.obj|length')
        add PASS "xui-api" "inbounds/list" "${n} inbound(s)"
    else
        snippet=$(echo "$api_resp" | head -c 100 | tr '\n' ' ')
        add FAIL "xui-api" "inbounds/list" "${snippet:-no response}"
    fi
fi

# ===================================================================
section "Inbound'ы и DUMMY"
if [ -n "$api_resp" ] && echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1; then
    for spec in "${REQUIRED_INBOUNDS[@]}"; do
        IFS='|' read -r port remark dest sni <<< "$spec"
        node=$(echo "$api_resp" | jq -c --arg r "$remark" '.obj[]? | select(.remark==$r)')
        if [ -z "$node" ]; then add FAIL "inbounds" "$remark" "отсутствует"; continue; fi
        proto=$(echo "$node" | jq -r '.protocol // empty')
        en=$(echo "$node"    | jq -r '.enable // false')
        sec=$(echo "$node"   | jq -r '((.streamSettings|fromjson?) // {}) | .security // empty')
        flow_ok=$(echo "$node" | jq -r '((.settings|fromjson?).clients // []) | if length==0 then "empty" else (all(.flow=="xtls-rprx-vision"))|tostring end')
        issues=""
        [ "$proto" != "vless" ]   && issues+=" proto=${proto:-?};"
        [ "$en" != "true" ]       && issues+=" disabled;"
        [ "$sec" != "reality" ]   && issues+=" security=${sec:-?};"
        [ "$flow_ok" = "false" ]  && issues+=" non-vision client;"
        if [ -z "$issues" ]; then add PASS "inbounds" "$remark" "vless+reality"
        else add WARN "inbounds" "$remark" "$issues"; fi
        timeout 2 bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null \
            && add PASS "ports" ":${port}" "listening" \
            || add FAIL "ports" ":${port}" "не слушается"
        dummy_email="DUMMY-${remark}"
        dummy_exists=$(echo "$node" | jq -r --arg e "$dummy_email" '((.settings|fromjson?).clients // []) | map(select(.email==$e)) | length')
        [[ "$dummy_exists" =~ ^[0-9]+$ ]] || dummy_exists=0
        [ "$dummy_exists" -gt 0 ] && add PASS "dummy" "$dummy_email" "присутствует" || add WARN "dummy" "$dummy_email" "отсутствует"
    done
else
    add WARN "inbounds" "проверка" "пропущена (API недоступен)"
fi

# ===================================================================
section "Reality dest доступность"
declare -A SEEN; SEEN=()
for spec in "${REQUIRED_INBOUNDS[@]}"; do
    IFS='|' read -r port remark dest sni <<< "$spec"
    [ -n "${SEEN[$dest]:-}" ] && continue
    SEEN[$dest]=1
    h="${dest%:*}"; p="${dest##*:}"
    if timeout 5 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null; then
        if echo Q | timeout 5 openssl s_client -connect "${h}:${p}" -servername "$sni" -tls1_3 2>/dev/null | tr -d '\0' | grep -qE '(TLSv1\.3|TLS_AES_|TLS_CHACHA)'; then
            add PASS "reality-dest" "$dest" "TCP+TLS1.3 OK"
        else
            add WARN "reality-dest" "$dest" "TLS 1.3 не подтверждён"
        fi
    else
        add FAIL "reality-dest" "$dest" "TCP недоступен"
    fi
done

# ===================================================================
section "База 3x-ui"
if [ -f "$XUI_DB" ]; then
    sz=$(stat -c '%s' "$XUI_DB" 2>/dev/null || echo 0)
    add PASS "db" "x-ui.db" "${sz} байт"
    if command -v sqlite3 >/dev/null; then
        integ=$(sqlite3 "$XUI_DB" "PRAGMA integrity_check;" 2>/dev/null | head -1)
        [ "$integ" = "ok" ] && add PASS "db" "integrity" "ok" || add WARN "db" "integrity" "${integ:-проверка не прошла}"
        cli_total=$(sqlite3 "$XUI_DB" "SELECT COUNT(*) FROM client_traffics;" 2>/dev/null || echo "?")
        add PASS "db" "client_traffics" "${cli_total} записей"
    fi
else
    add FAIL "db" "x-ui.db" "не найден"
fi

# ===================================================================
section "Логи бота"
check_log() {
    local path="$1" name="$2"
    if [ ! -f "$path" ]; then add WARN "logs" "$name" "отсутствует"; return; fi
    local sz mtime age errs
    sz=$(stat -c '%s' "$path" 2>/dev/null || echo 0)
    mtime=$(stat -c '%Y' "$path" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    errs=$(tail -500 "$path" 2>/dev/null | grep -ciE 'error|fatal|fail' || true)
    [[ "$errs" =~ ^[0-9]+$ ]] || errs=0
    local detail="${sz}B, обновлён $((age/60)) мин назад"
    [ "$errs" -gt 0 ] && add WARN "logs" "$name" "$detail, ошибок: $errs (в 500 строк)" || add PASS "logs" "$name" "$detail"
}
check_log "$BOT_DIR/logs/bot.log" "bot.log"
check_log "$BOT_DIR/logs/alerts.log" "alerts.log"

# ===================================================================
section "Состояние данных"
TRAFFIC_CSV="$BOT_DIR/data/traffic.csv"
if [ -f "$TRAFFIC_CSV" ]; then
    total_lines=$(wc -l < "$TRAFFIC_CSV" 2>/dev/null || echo 1)
    [[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=1
    rows=$((total_lines - 1)); [ "$rows" -lt 0 ] && rows=0
    if [ "$rows" -lt 2 ]; then
        add WARN "data" "traffic.csv" "${rows} снапшот(ов)"
    else
        last_ts=$(tail -1 "$TRAFFIC_CSV" 2>/dev/null | cut -d, -f1)
        if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
            age=$(( $(date +%s) - last_ts ))
            [ "$age" -gt 7200 ] && add WARN "data" "traffic.csv" "${rows} снапш., последний $((age/60)) мин назад (>2ч)" \
                                || add PASS "data" "traffic.csv" "${rows} снапш., последний $((age/60)) мин назад"
        else
            add WARN "data" "traffic.csv" "${rows} снапш., некорректная строка"
        fi
    fi
else
    add WARN "data" "traffic.csv" "отсутствует"
fi
ALERT_STATE="$BOT_DIR/data/alert_state.json"
if [ -f "$ALERT_STATE" ]; then
    if jq empty "$ALERT_STATE" 2>/dev/null; then
        fired=$(jq -r '[.[] | select(.==true)] | length' "$ALERT_STATE" 2>/dev/null || echo 0)
        [[ "$fired" =~ ^[0-9]+$ ]] || fired=0
        if [ "$fired" -eq 0 ]; then add PASS "data" "alert_state" "все алерты в норме"
        else flags=$(jq -r 'to_entries | map(select(.value==true) | .key) | join(", ")' "$ALERT_STATE" 2>/dev/null)
             add WARN "data" "alert_state" "активные: ${flags:-?}"; fi
    else add WARN "data" "alert_state" "невалидный JSON"; fi
else add WARN "data" "alert_state" "отсутствует"; fi
bkp_cnt=$(ls -1 "$BOT_DIR"/backups/x-ui-backup-*.tar.gz 2>/dev/null | wc -l)
[[ "$bkp_cnt" =~ ^[0-9]+$ ]] || bkp_cnt=0
if [ "$bkp_cnt" -eq 0 ]; then add WARN "data" "backups" "нет бэкапов"
else
    last_bkp=$(ls -1t "$BOT_DIR"/backups/x-ui-backup-*.tar.gz 2>/dev/null | head -1)
    if [ -f "$last_bkp" ]; then
        m=$(stat -c '%Y' "$last_bkp" 2>/dev/null || echo 0)
        days=$(( ($(date +%s) - m) / 86400 ))
        add PASS "data" "backups" "${bkp_cnt} шт., последний ${days} дн. назад"
    fi
fi
if [ -d "$BOT_DIR/data/pending" ]; then
    pending_files=$(ls -1 "$BOT_DIR/data/pending" 2>/dev/null | wc -l)
    [[ "$pending_files" =~ ^[0-9]+$ ]] || pending_files=0
    [ "$pending_files" -gt 0 ] && add WARN "data" "pending" "${pending_files} висячих сессий" || add PASS "data" "pending" "пусто"
fi

# ===================================================================
section "Сеть"
tg_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" https://api.telegram.org/ 2>/dev/null || echo "000")
case "$tg_code" in
    200|301|302|400|401|403|404) add PASS "network" "api.telegram.org" "HTTP ${tg_code}" ;;
    000) add FAIL "network" "api.telegram.org" "недоступен" ;;
    *)   add WARN "network" "api.telegram.org" "HTTP ${tg_code}" ;;
esac

# ===================================================================
total=$((PASS+WARN+FAIL))
ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
host=$(hostname)

if [ "$JSON_OUT" = 1 ]; then
    echo "{"
    echo "  \"version\": \"$VERSION\","
    echo "  \"host\": $(echo -n "$host" | jq -Rs .),"
    echo "  \"timestamp\": \"$ts\","
    echo "  \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL, \"total\": $total},"
    echo "  \"results\": ["
    first=1
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r st cat chk det <<< "$r"
        [ "$first" = 1 ] && first=0 || echo ","
        printf '    {"status":"%s","category":"%s","check":%s,"details":%s}' \
            "$st" "$cat" "$(echo -n "$chk" | jq -Rs .)" "$(echo -n "$det" | jq -Rs .)"
    done
    echo; echo "  ]"; echo "}"
    [ "$FAIL" -gt 0 ] && exit 1
    [ "$WARN" -gt 0 ] && exit 2
    exit 0
fi

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          3x-ui-bot — Health Check Report v${VERSION}                              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  Host:  %-69s ${BOLD}║${NC}\n" "$host"
printf "${BOLD}║${NC}  Time:  %-69s ${BOLD}║${NC}\n" "$ts"
printf "${BOLD}║${NC}  API:   %-69s ${BOLD}║${NC}\n" "$API"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
echo

CATS_ORDER_KEYS=()
declare -A CATS_SEEN; CATS_SEEN=()
for r in "${RESULTS[@]}"; do
    IFS='|' read -r _ cat _ _ <<< "$r"
    [ -z "${CATS_SEEN[$cat]:-}" ] && { CATS_SEEN[$cat]=1; CATS_ORDER_KEYS+=("$cat"); }
done

for cat in "${CATS_ORDER_KEYS[@]}"; do
    cat_label=$(echo "$cat" | tr 'a-z' 'A-Z')
    echo -e "${BLU}── ${cat_label} ──${NC}"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r st c chk det <<< "$r"
        [ "$c" = "$cat" ] || continue
        case "$st" in
            PASS) icon="${GRN}✓${NC} ";;
            WARN) icon="${YLW}!${NC} ";;
            FAIL) icon="${RED}✗${NC} ";;
            *)    icon="? ";;
        esac
        printf "  %b %-30s %s\n" "$icon" "$chk" "${det:+— $det}"
    done
    echo
done

sum_line="Итого: ${PASS} PASS, ${WARN} WARN, ${FAIL} FAIL (из ${total} проверок)"
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
printf "${BOLD}║${NC}  ${GRN}%d PASS${NC}, ${YLW}%d WARN${NC}, ${RED}%d FAIL${NC} (из %d проверок) %*s${BOLD}║${NC}\n" \
    "$PASS" "$WARN" "$FAIL" "$total" \
    "$(( 50 - ${#sum_line} > 0 ? 50 - ${#sum_line} : 1 ))" ""
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

if [ "$FAIL" -gt 0 ]; then
    echo; echo -e "${RED}${BOLD}⛔ Есть критические проблемы — требуется вмешательство.${NC}"
elif [ "$WARN" -gt 0 ]; then
    echo; echo -e "${YLW}${BOLD}⚠️  Есть предупреждения, но критики нет.${NC}"
else
    echo; echo -e "${GRN}${BOLD}✅ Всё работает штатно.${NC}"
fi

if [ "$SEND_TG" = 1 ] && [ -n "$BOT_TOKEN" ] && [ -n "$ADMIN_IDS" ]; then
    {
        echo "🩺 <b>Health Check</b> — $host"
        echo "🕐 $ts"
        echo
        echo "📊 <b>Итого:</b> ✓${PASS} ⚠${WARN} ✗${FAIL} (из ${total})"
        echo
        if [ "$FAIL" -gt 0 ]; then
            echo "❌ <b>Критичные:</b>"
            for r in "${RESULTS[@]}"; do IFS='|' read -r st c chk det <<< "$r"; [ "$st" = "FAIL" ] && echo "• [$c] $chk${det:+ — $det}"; done
            echo
        fi
        if [ "$WARN" -gt 0 ]; then
            echo "⚠️ <b>Предупреждения:</b>"
            for r in "${RESULTS[@]}"; do IFS='|' read -r st c chk det <<< "$r"; [ "$st" = "WARN" ] && echo "• [$c] $chk${det:+ — $det}"; done
        fi
        [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ] && echo "✅ Все проверки пройдены"
    } > /tmp/3x-ui-bot-hc-report.txt
    chmod 600 /tmp/3x-ui-bot-hc-report.txt
    msg=$(truncate_tg "$(cat /tmp/3x-ui-bot-hc-report.txt)")
    for uid in $ADMIN_IDS; do
        curl -s --max-time 15 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d "chat_id=${uid}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
            --data-urlencode "text=${msg}" > /dev/null
    done
    echo; echo "📤 Отчёт отправлен админам ($ADMIN_IDS)"
fi

[ "$FAIL" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 2
exit 0
