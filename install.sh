#!/usr/bin/env bash
# install.sh — 3x-ui-bot installer v2.8
# Совместимость: Ubuntu 22.04 / 24.04
# Изменения v2.8:
#   * jq-выражения с пробелами (jq 1.7 на Ubuntu 24 требует "? // {}")
#   * каждая Environment= в systemd-юнитах отдельной строкой
#   * settings/streamSettings формируются строго через --arg (без double-encoding)
#
set -uo pipefail

INSTALLER_VERSION="2.8"
INSTALLER_PATH="$(readlink -f "$0")"
INSTALLER_DIR="$(dirname "$INSTALLER_PATH")"
INVOKE_PWD="$PWD"

BOT_DIR="/opt/3x-ui-bot"
BOT_ENV="$BOT_DIR/bot.env"
BOT_SH="$BOT_DIR/bot.sh"
BOT_SH_NAME="bot.sh"

DIR_SPEC=(
    "$BOT_DIR|755"
    "$BOT_DIR/backups|750"
    "$BOT_DIR/logs|750"
    "$BOT_DIR/data|755"
    "$BOT_DIR/data/pending|755"
)
FILE_SPEC=(
    "$BOT_DIR/data/offset|644|0"
    "$BOT_DIR/data/alert_state.json|644|{}"
    "$BOT_DIR/data/traffic.csv|644|ts,total_bytes"
)

LOCK_FILE="/var/lock/3x-ui-bot-install.lock"
INSTALL_LOG="/tmp/3x-ui-bot-install-$(date +%Y%m%d-%H%M%S).log"

# Оптимальная раскладка по результатам check-dests.sh
REQUIRED_INBOUNDS=(
    "443|main-443|www.kvnos.ru:443|www.kvnos.ru"
    "993|fallback-993|imap.yandex.ru:993|imap.yandex.ru"
    "587|fallback-587|www.sberbank.ru:443|www.sberbank.ru"
    "465|fallback-465|www.tinkoff.ru:443|www.tinkoff.ru"
)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLU='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
STEP=0; CURRENT_STEP=""; CURRENT_OP=""

log_raw() { echo "[$(date '+%F %T')] $*" >> "$INSTALL_LOG"; }
info()    { echo -e "${CYN}[i]${NC} $*"; log_raw "INFO: $*"; }
ok()      { echo -e "${GRN}[✓]${NC} $*"; log_raw "OK:   $*"; }
warn()    { echo -e "${YLW}[!]${NC} $*"; log_raw "WARN: $*"; }
dbg()     { log_raw "DBG:  $*"; }
err()     { echo -e "${RED}[✗]${NC} $*" >&2; log_raw "ERR:  $*"; }
hint()    { echo -e "    ${DIM}↳ $*${NC}"; log_raw "HINT: $*"; }
fail()    { err "$*"; echo; err "Шаг: ${CURRENT_STEP:-?}"; [ -n "$CURRENT_OP" ] && err "Операция: $CURRENT_OP"; echo "Лог: $INSTALL_LOG"; exit 1; }
step()    { STEP=$((STEP+1)); CURRENT_STEP="$*"; CURRENT_OP=""; echo; echo -e "${BLU}━━━ Шаг ${STEP}: $* ━━━${NC}"; log_raw "===== STEP $STEP: $* ====="; }
op()      { CURRENT_OP="$*"; dbg "OP: $*"; }

on_error() {
    local line=$1 code=$2 cmd="${BASH_COMMAND:-?}"
    echo; err "Ошибка (exit=$code) на строке $line"
    err "Команда: $cmd"
    err "Шаг: ${CURRENT_STEP:-?}"
    [ -n "$CURRENT_OP" ] && err "Операция: $CURRENT_OP"
    echo; echo "Последние строки лога:"
    tail -40 "$INSTALL_LOG" 2>/dev/null | sed 's/^/  /'
    echo; echo "Артефакты: $INSTALL_LOG, /tmp/3x-ui-bot-api-*.res"
    exit "$code"
}
trap 'on_error $LINENO $?' ERR
cleanup() { rm -f "$LOCK_FILE" 2>/dev/null || true; log_raw "=== exit ==="; }
trap cleanup EXIT

log_raw "=== installer v${INSTALLER_VERSION} ==="
log_raw "Path:$INSTALLER_PATH PWD:$INVOKE_PWD User:$(id -un) Host:$(hostname) Uname:$(uname -sr)"

ensure_dir() {
    local path="$1" mode="$2" owner="${3:-root}" group="${4:-root}"
    op "ensure_dir $path mode=$mode"
    if [ ! -d "$path" ]; then mkdir -p "$path" || { err "mkdir $path"; return 1; }; ok "Создан: $path"; fi
    chmod "$mode" "$path" || return 1
    chown "$owner:$group" "$path" || return 1
    local a; a=$(stat -c '%a' "$path"); [ "$a" = "$mode" ] || warn "  $path: $a ≠ $mode"
}
ensure_file() {
    local path="$1" mode="$2" initial="${3:-}" owner="${4:-root}" group="${5:-root}"
    op "ensure_file $path"
    if [ ! -e "$path" ]; then printf '%s' "$initial" > "$path" || return 1; ok "Создан: $path"; fi
    chmod "$mode" "$path" && chown "$owner:$group" "$path"
}
safe_write() {
    local path="$1" mode="$2"
    local tmp; tmp="${path}.new.$$"
    op "safe_write $path"
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" && chown root:root "$tmp"
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ===================================================================
step "Lock + базовые проверки"
if [ -e "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then fail "Установщик уже запущен (pid $pid)"
    else warn "Старый lock pid $pid — удаляю"; rm -f "$LOCK_FILE"; fi
fi
echo $$ > "$LOCK_FILE"; chmod 644 "$LOCK_FILE"
ok "Lock: $LOCK_FILE (pid $$)"

[ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && fail "Нужен bash >= 4 (у вас ${BASH_VERSION})"
ok "bash $BASH_VERSION"
[[ $EUID -ne 0 ]] && fail "Запустите от root"
ok "root OK"
have_cmd apt || fail "Поддерживается Debian/Ubuntu"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    ok "OS: $PRETTY_NAME"
    case "${VERSION_ID:-}" in
        22.04|24.04) ok "Ubuntu LTS поддерживается" ;;
        *) warn "Версия не тестировалась официально" ;;
    esac
fi
have_cmd systemctl || fail "systemctl не найден"
[ -d /etc/systemd/system ] || fail "/etc/systemd/system отсутствует"
ok "systemd OK"

touch /tmp/.3xb-test.$$ 2>/dev/null && rm -f /tmp/.3xb-test.$$ || fail "/tmp не writable"
ok "/tmp writable"

free_opt=$(df -P /opt 2>/dev/null | awk 'NR==2{print $4}'); free_opt=${free_opt:-0}
free_tmp=$(df -P /tmp 2>/dev/null | awk 'NR==2{print $4}'); free_tmp=${free_tmp:-0}
[ "$free_opt" -lt 204800 ] && warn "Свободно в /opt: $((free_opt/1024)) МБ"
[ "$free_tmp" -lt 51200 ]  && warn "Свободно в /tmp: $((free_tmp/1024)) МБ"
ok "Диск OK"

if have_cmd timedatectl; then
    s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "n/a")
    [ "$s" = "yes" ] && ok "NTP синхронизация" || { warn "NTP=$s"; hint "timedatectl set-ntp true"; }
fi

if curl -s --max-time 5 -o /dev/null https://api.telegram.org 2>/dev/null; then
    ok "api.telegram.org доступен"
else
    warn "api.telegram.org недоступен"
    hint "Проверьте /etc/hosts и DNS"
fi

# ===================================================================
step "Установка пакетов"
op "apt update"
export DEBIAN_FRONTEND=noninteractive
apt update -qq >> "$INSTALL_LOG" 2>&1 || fail "apt update failed"
op "apt install"
PKGS=(curl jq sqlite3 gnuplot bc coreutils openssl ca-certificates tzdata iproute2 uuid-runtime python3)
apt install -y "${PKGS[@]}" >> "$INSTALL_LOG" 2>&1 || fail "apt install failed"
for t in curl jq sqlite3 gnuplot openssl ss uuidgen tar gzip awk sed grep date stat python3; do
    have_cmd "$t" || fail "Команда '$t' недоступна"
done
ok "${#PKGS[@]} пакетов в PATH"

# ===================================================================
step "Локация bot.sh"
SRC_BOT_SH=""
for c in "$INVOKE_PWD/$BOT_SH_NAME" "$INSTALLER_DIR/$BOT_SH_NAME" "$BOT_SH" "/root/$BOT_SH_NAME" "/tmp/$BOT_SH_NAME"; do
    if [ -f "$c" ]; then SRC_BOT_SH="$c"; break; fi
done
[ -z "$SRC_BOT_SH" ] && fail "$BOT_SH_NAME не найден ($INVOKE_PWD, $INSTALLER_DIR, $BOT_SH, /root, /tmp)"
ok "Источник: $SRC_BOT_SH ($(stat -c '%s' "$SRC_BOT_SH") байт)"
bash -n "$SRC_BOT_SH" 2>>"$INSTALL_LOG" || fail "Синтаксис bot.sh битый"
ok "Синтаксис OK"
SRC_MD5=$(md5sum "$SRC_BOT_SH" | awk '{print $1}')

# ===================================================================
step "Каталоги"
for spec in "${DIR_SPEC[@]}"; do IFS='|' read -r p m <<< "$spec"; ensure_dir "$p" "$m" || fail "Каталог $p"; done
ok "Каталоги готовы"

# ===================================================================
step "3x-ui"
if ! systemctl list-unit-files | grep -q '^x-ui\.service'; then
    warn "x-ui не найден"
    read -rp "Продолжить без 3x-ui? (y/N): " a
    [[ "$a" =~ ^[yY]$ ]] || fail "Прервано"
else
    systemctl is-active --quiet x-ui && ok "x-ui запущен" || warn "x-ui не активен"
fi

XRAY_BIN=""
for p in /usr/local/x-ui/bin/xray-linux-amd64 /usr/local/x-ui/bin/xray-linux-arm64 /usr/local/x-ui/bin/xray /usr/local/bin/xray; do
    [[ -x "$p" ]] && { XRAY_BIN="$p"; break; }
done
[ -n "$XRAY_BIN" ] && ok "xray: $XRAY_BIN" || warn "xray не найден"

XUI_DB="/etc/x-ui/x-ui.db"
[ -f "$XUI_DB" ] && ok "БД: $XUI_DB" || warn "БД не найдена"

db_get(){ sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null || true; }
DEF_PORT=$(db_get webPort);     DEF_PORT="${DEF_PORT:-2053}"
DEF_PATH=$(db_get webBasePath); DEF_PATH="${DEF_PATH:-/}"
DEF_CERT=$(db_get webCertFile)
DEF_SCHEME="http"; [ -n "$DEF_CERT" ] && DEF_SCHEME="https"

# ===================================================================
step "Параметры"
while :; do
    read -rp "Telegram Bot Token: " BOT_TOKEN
    [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] && break
    warn "Некорректный формат"
done
while :; do
    read -rp "Admin Telegram IDs (через пробел): " ADMIN_IDS
    [ -z "$ADMIN_IDS" ] && { warn "Пусто"; continue; }
    bad=0
    for id in $ADMIN_IDS; do [[ "$id" =~ ^[0-9]+$ ]] || { warn "Не число: $id"; bad=1; }; done
    [ "$bad" -eq 0 ] && break
done

echo; info "3x-ui панель:"
read -rp "  Схема [$DEF_SCHEME]: " XUI_SCHEME; XUI_SCHEME="${XUI_SCHEME:-$DEF_SCHEME}"
read -rp "  Хост [127.0.0.1]: " XUI_HOST; XUI_HOST="${XUI_HOST:-127.0.0.1}"
read -rp "  Порт [$DEF_PORT]: " XUI_PORT; XUI_PORT="${XUI_PORT:-$DEF_PORT}"
[[ "$XUI_PORT" =~ ^[0-9]+$ ]] || fail "Порт — число"
read -rp "  Path [$DEF_PATH]: " XUI_PATH; XUI_PATH="${XUI_PATH:-$DEF_PATH}"
[[ "$XUI_PATH" != /* ]] && XUI_PATH="/$XUI_PATH"

echo; echo "  Bearer API Token: Settings → Telegram Bot → Bot API Token"
read -rp "  XUI_API_TOKEN: " XUI_API_TOKEN
[ -z "$XUI_API_TOKEN" ] && fail "API token обязателен"

echo
read -rp "INBOUND_FILTER [regex:^(main-|fallback-)]: " INBOUND_FILTER
INBOUND_FILTER="${INBOUND_FILTER:-regex:^(main-|fallback-)}"

echo; info "Reality dest/SNI (оптимально по check-dests.sh):"
for spec in "${REQUIRED_INBOUNDS[@]}"; do IFS='|' read -r p r d s <<< "$spec"; echo "    • $r → $d ($s)"; done

echo; info "Внешка:"
DEF_DOMAIN=$(hostname -f 2>/dev/null || hostname)
read -rp "  SERVER_DOMAIN [$DEF_DOMAIN]: " SERVER_DOMAIN; SERVER_DOMAIN="${SERVER_DOMAIN:-$DEF_DOMAIN}"
read -rp "  NGINX_PREFIX [subs]: " NGINX_PREFIX; NGINX_PREFIX="${NGINX_PREFIX:-subs}"
read -rp "  NGINX_PORT [8443]: " NGINX_PORT; NGINX_PORT="${NGINX_PORT:-8443}"
[[ "$NGINX_PORT" =~ ^[0-9]+$ ]] || fail "NGINX_PORT — число"

echo; info "Логи Xray:"
read -rp "  ACCESS_LOG [/usr/local/x-ui/access.log]: " XRAY_ACCESS_LOG
XRAY_ACCESS_LOG="${XRAY_ACCESS_LOG:-/usr/local/x-ui/access.log}"
read -rp "  ERROR_LOG [/usr/local/x-ui/error.log]: " XRAY_ERROR_LOG
XRAY_ERROR_LOG="${XRAY_ERROR_LOG:-/usr/local/x-ui/error.log}"

echo; info "Алертинг:"
read -rp "  CPU% [85]: "  CPU_TH;   CPU_TH="${CPU_TH:-85}"
read -rp "  RAM% [85]: "  RAM_TH;   RAM_TH="${RAM_TH:-85}"
read -rp "  Disk% [90]: " DISK_TH;  DISK_TH="${DISK_TH:-90}"
read -rp "  Интервал, сек [60]: " CHECK_INT; CHECK_INT="${CHECK_INT:-60}"
read -rp "  Час сводки [10]: " SUM_HOUR; SUM_HOUR="${SUM_HOUR:-10}"
[[ "$SUM_HOUR" =~ ^[0-9]+$ ]] && [ "$SUM_HOUR" -lt 24 ] || fail "Час 0-23"
read -rp "  TZ [Europe/Moscow]: " TZ_VAL; TZ_VAL="${TZ_VAL:-Europe/Moscow}"
[ -f "/usr/share/zoneinfo/$TZ_VAL" ] || warn "TZ $TZ_VAL не найден"

API="${XUI_SCHEME}://${XUI_HOST}:${XUI_PORT}${XUI_PATH%/}"

echo
echo "─── Сводка ────────────────────────"
echo " Папка:  $BOT_DIR"
echo " Bot.sh: $SRC_BOT_SH"
echo " Админы: $ADMIN_IDS"
echo " API:    $API"
echo " Алерты: CPU≥${CPU_TH}% RAM≥${RAM_TH}% Disk≥${DISK_TH}%"
echo " Сводка: ${SUM_HOUR}:00 ($TZ_VAL)"
echo "───────────────────────────────────"
read -rp "Всё верно? (Y/n): " a
[[ "$a" =~ ^[nN]$ ]] && fail "Отменено"

# ===================================================================
step "Проверка Reality dest'ов"
declare -A SEEN_DEST=()
for spec in "${REQUIRED_INBOUNDS[@]}"; do
    IFS='|' read -r port remark dest sni <<< "$spec"
    [ -n "${SEEN_DEST[$dest]:-}" ] && continue
    SEEN_DEST[$dest]=1
    h="${dest%:*}"; p="${dest##*:}"
    if timeout 5 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null; then
        if echo Q | timeout 5 openssl s_client -connect "${h}:${p}" -servername "$sni" -tls1_3 2>/dev/null | tr -d '\0' | grep -qE '(TLSv1\.3|TLS_AES_|TLS_CHACHA)'; then
            ok "  $dest (SNI $sni) — TCP+TLS1.3 OK"
        else
            warn "  $dest — TCP OK, TLS 1.3 не подтверждён"
        fi
    else
        warn "  $dest — TCP недоступен"
    fi
done

# ===================================================================
step "Bot Token (getMe)"
resp=$(curl -s --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" || true)
if echo "$resp" | jq -e '.ok==true' >/dev/null 2>&1; then
    BOT_USER=$(echo "$resp" | jq -r .result.username)
    ok "Бот: @$BOT_USER"
else
    err "Bot token невалиден"; echo "$resp" | jq . 2>/dev/null || echo "$resp"
    fail "Создайте корректный токен у @BotFather"
fi

# ===================================================================
step "3x-ui API"
xui_api() {
    local m="$1" path="$2" data="${3:-}" tag="${4:-call}"
    local req="/tmp/3x-ui-bot-api-${tag}.req" res="/tmp/3x-ui-bot-api-${tag}.res"
    op "API $m $path tag=$tag"
    local resp http_code
    if [ -n "$data" ]; then
        echo "$data" > "$req"; chmod 600 "$req" 2>/dev/null || true
        resp=$(curl -sk --max-time 20 -w "\n__HTTP__%{http_code}" -X "$m" "${API}${path}" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" -H "Content-Type: application/json" \
            -H "Accept: application/json" -d "$data" 2>>"$INSTALL_LOG" || true)
    else
        resp=$(curl -sk --max-time 20 -w "\n__HTTP__%{http_code}" -X "$m" "${API}${path}" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" -H "Accept: application/json" 2>>"$INSTALL_LOG" || true)
    fi
    http_code=$(echo "$resp" | tail -1 | sed 's/^__HTTP__//')
    resp=$(echo "$resp" | sed '$d')
    echo "$resp" > "$res"; chmod 600 "$res" 2>/dev/null || true
    dbg "  HTTP=$http_code → $res"
    echo "$resp"
}

api_resp=$(xui_api GET "/panel/api/inbounds/list" "" "list1")
if echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1; then
    inb=$(echo "$api_resp" | jq '.obj|length')
    ok "API OK, inbound'ов: $inb"
else
    err "API не отвечает"; echo "$api_resp" | head -c 500
    fail "Проверьте XUI_API_TOKEN/URL/path"
fi

# ===================================================================
step "Проверка inbound'ов"
check_inbounds() {
    local resp="$1"
    MISSING=(); BAD=()
    for spec in "${REQUIRED_INBOUNDS[@]}"; do
        IFS='|' read -r port remark dest sni <<< "$spec"
        node=$(echo "$resp" | jq -c --arg r "$remark" '
            .obj[]? | select(.remark==$r)
            | {id, port, protocol, enable,
               stream: ((.streamSettings|fromjson?) // {}),
               clients: (((.settings|fromjson?).clients) // [])}')
        if [ -z "$node" ]; then
            MISSING+=("$spec"); echo "  ❌ $remark — отсутствует"; continue
        fi
        gp=$(echo "$node"|jq -r '.port'); gpr=$(echo "$node"|jq -r '.protocol')
        ge=$(echo "$node"|jq -r '.enable'); gs=$(echo "$node"|jq -r '.stream.security // empty')
        gn=$(echo "$node"|jq -r '.stream.network // empty')
        fo=$(echo "$node"|jq -r 'if (.clients|length)==0 then "empty" else (.clients|all(.flow=="xtls-rprx-vision"))|tostring end')
        is=""
        [ "$gp" != "$port" ]    && is+=" port=${gp}≠${port};"
        [ "$gpr" != "vless" ]   && is+=" proto=${gpr};"
        [ "$gs" != "reality" ]  && is+=" sec=${gs};"
        [ "$ge" != "true" ]     && is+=" disabled;"
        [ "$fo" = "false" ]     && is+=" non-vision;"
        if [ -z "$is" ]; then ok "  ✅ $remark — vless+reality, net=$gn"
        else BAD+=("$remark:$is"); echo "  ⚠️  $remark —$is"; fi
    done
}
check_inbounds "$api_resp"

# ===================================================================
if [ ${#MISSING[@]} -gt 0 ]; then
    step "Автосоздание недостающих inbound'ов"
    for spec in "${MISSING[@]}"; do IFS='|' read -r p r d s <<< "$spec"; echo "    • $r → $d ($s)"; done
    read -rp "Создать? (Y/n): " a
    if [[ ! "$a" =~ ^[nN]$ ]]; then
        [ -z "$XRAY_BIN" ] && fail "Нужен xray для x25519"
        keys=$("$XRAY_BIN" x25519 2>>"$INSTALL_LOG")
        REALITY_PRIV=$(echo "$keys" | awk -F': ' '/Private/{print $2}' | tr -d '\r')
        REALITY_PUB=$( echo "$keys" | awk -F': ' '/Public/{print $2}'  | tr -d '\r')
        [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ] && fail "x25519 не сгенерировались"
        ok "x25519: pub=${REALITY_PUB:0:12}…"
        SHORT_ID=$(openssl rand -hex 8)

        create_inbound() {
            local port="$1" remark="$2" dest="$3" sni="$4"
            op "create $remark"
            local stream
            stream=$(jq -nc \
                --arg d "$dest" --arg s "$sni" --arg priv "$REALITY_PRIV" --arg pub "$REALITY_PUB" --arg sid "$SHORT_ID" '
                {network:"tcp",security:"reality",externalProxy:[],
                 realitySettings:{show:false,xver:0,dest:$d,serverNames:[$s],privateKey:$priv,minClient:"",maxClient:"",maxTimediff:0,shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},
                 tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}')
            local payload
            payload=$(jq -nc --arg r "$remark" --argjson port "$port" --arg tag "inbound-${port}" --arg stream "$stream" '
                {up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,listen:"",port:$port,protocol:"vless",
                 settings:"{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}",streamSettings:$stream,tag:$tag,
                 sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
                 allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"}')
            local r; r=$(xui_api POST "/panel/api/inbounds/add" "$payload" "add-${port}")
            if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then
                ok "  + $remark (port $port)"; return 0
            else
                err "  ✗ $remark: $(echo "$r"|jq -r '.msg//"?"')"; return 1
            fi
        }

        for spec in "${MISSING[@]}"; do
            IFS='|' read -r port _ _ _ <<< "$spec"
            if ss -ltn "sport = :${port}" 2>/dev/null | tail -n +2 | grep -q .; then
                warn "Порт ${port} занят:"
                ss -ltnp "sport = :${port}" 2>/dev/null | tail -n +2 | sed 's/^/    /'
            fi
        done

        CREATED=0; FAILED=0
        for spec in "${MISSING[@]}"; do
            IFS='|' read -r port remark dest sni <<< "$spec"
            create_inbound "$port" "$remark" "$dest" "$sni" && CREATED=$((CREATED+1)) || FAILED=$((FAILED+1))
        done
        ok "Создано: $CREATED, ошибок: $FAILED"

        info "Перезапуск Xray..."
        rr=$(xui_api POST "/panel/api/inbounds/restartXray" "" "restart")
        echo "$rr" | jq -e '.success==true' >/dev/null 2>&1 \
            && ok "Xray перезапущен" \
            || { warn "API restartXray не сработал"; systemctl restart x-ui >>"$INSTALL_LOG" 2>&1; }
        sleep 3

        step "Ретест"
        api_resp=$(xui_api GET "/panel/api/inbounds/list" "" "list2")
        echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1 || fail "API не отвечает"
        check_inbounds "$api_resp"

        info "TCP-прослушка:"
        for spec in "${REQUIRED_INBOUNDS[@]}"; do
            IFS='|' read -r port remark _ _ <<< "$spec"
            timeout 2 bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null \
                && ok "  :${port} ($remark)" \
                || warn "  :${port} ($remark) НЕ слушается"
        done

        {
            echo "Reality keys — installer v${INSTALLER_VERSION} on $(date)"
            echo "Private: $REALITY_PRIV"
            echo "Public:  $REALITY_PUB"
            echo "ShortID: $SHORT_ID"
            echo
            for spec in "${REQUIRED_INBOUNDS[@]}"; do
                IFS='|' read -r p r d s <<< "$spec"
                echo "  $r port=$p dest=$d SNI=$s"
            done
        } | safe_write "$BOT_DIR/reality-keys.txt" 600
        ok "Reality-ключи: $BOT_DIR/reality-keys.txt"
    fi
fi

# ===================================================================
step "DUMMY-пользователи"
api_resp=$(xui_api GET "/panel/api/inbounds/list" "" "list-d")
if ! echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1; then
    warn "API не отвечает, пропуск DUMMY"
else
    DA=0; DS=0; DF=0
    for spec in "${REQUIRED_INBOUNDS[@]}"; do
        IFS='|' read -r port remark _ _ <<< "$spec"
        de="DUMMY-${remark}"
        node=$(echo "$api_resp" | jq -c --arg r "$remark" '.obj[]?|select(.remark==$r)')
        [ -z "$node" ] && { warn "  $remark не найден"; DF=$((DF+1)); continue; }
        ib=$(echo "$node"|jq -r '.id')
        ex=$(echo "$node"|jq -r --arg e "$de" '((.settings|fromjson?).clients // []) | map(select(.email==$e)) | length')
        if [ "$ex" -gt 0 ]; then ok "  $de уже есть"; DS=$((DS+1)); continue; fi
        du=$(uuidgen)
        cl=$(jq -nc --arg id "$du" --arg e "$de" --arg s "DUMMY" --arg f "xtls-rprx-vision" \
             '{clients:[{id:$id,flow:$f,email:$e,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$s,comment:"protective dummy",reset:0}]}')
        pl=$(jq -nc --argjson id "$ib" --arg s "$cl" '{id:$id,settings:$s}')
        r=$(xui_api POST "/panel/api/inbounds/addClient" "$pl" "dummy-${port}")
        if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then
            ok "  + $de"; DA=$((DA+1))
        else
            err "  ✗ $de: $(echo "$r"|jq -r '.msg//"?"')"; DF=$((DF+1))
        fi
    done
    info "DUMMY: добавлено=$DA, уже=$DS, ошибок=$DF"
    [ "$DA" -gt 0 ] && { xui_api POST "/panel/api/inbounds/restartXray" "" "restart-d" >/dev/null; sleep 2; }
fi

# ===================================================================
[ ${#BAD[@]} -gt 0 ] && {
    step "Предупреждения по существующим"
    for b in "${BAD[@]}"; do echo "  ⚠️  $b"; done
    read -rp "Продолжить? (Y/n): " a
    [[ "$a" =~ ^[nN]$ ]] && fail "Прервано"
}

# ===================================================================
step "Копирование bot.sh"
NEED=1
if [ -f "$BOT_SH" ]; then
    DST_MD5=$(md5sum "$BOT_SH" | awk '{print $1}')
    if [ "$DST_MD5" = "$SRC_MD5" ]; then
        ok "$BOT_SH идентичен — пропуск"; NEED=0
    else
        bk="${BOT_SH}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$BOT_SH" "$bk" && ok "Бэкап: $bk"
    fi
fi
if [ "$NEED" = "1" ]; then
    install -m 755 -o root -g root "$SRC_BOT_SH" "$BOT_SH" || fail "install failed"
    ok "Установлен: $BOT_SH"
fi
bash -n "$BOT_SH" 2>>"$INSTALL_LOG" || fail "Битый bot.sh"

# ===================================================================
step "Файлы данных"
for spec in "${FILE_SPEC[@]}"; do IFS='|' read -r p m i <<< "$spec"; ensure_file "$p" "$m" "$i"; done

# ===================================================================
step "bot.env"
[ -f "$BOT_ENV" ] && cp -a "$BOT_ENV" "${BOT_ENV}.bak.$(date +%Y%m%d-%H%M%S)" && chmod 600 "${BOT_ENV}.bak.$(date +%Y%m%d-%H%M%S)"
safe_write "$BOT_ENV" 600 <<EOF
# 3x-ui-bot config (installer v${INSTALLER_VERSION}, $(date))
BOT_TOKEN="$BOT_TOKEN"
ADMIN_IDS="$ADMIN_IDS"

XUI_SCHEME="$XUI_SCHEME"
XUI_HOST="$XUI_HOST"
XUI_PORT="$XUI_PORT"
XUI_PATH="$XUI_PATH"
XUI_API_TOKEN="$XUI_API_TOKEN"
INBOUND_FILTER="$INBOUND_FILTER"

SERVER_DOMAIN="$SERVER_DOMAIN"
NGINX_PREFIX="$NGINX_PREFIX"
NGINX_PORT="$NGINX_PORT"

XRAY_ACCESS_LOG="$XRAY_ACCESS_LOG"
XRAY_ERROR_LOG="$XRAY_ERROR_LOG"

BOT_DIR="$BOT_DIR"
XUI_DB="$XUI_DB"

CPU_THRESHOLD="$CPU_TH"
RAM_THRESHOLD="$RAM_TH"
DISK_THRESHOLD="$DISK_TH"
CHECK_INTERVAL="$CHECK_INT"
SUMMARY_HOUR="$SUM_HOUR"
TZ="$TZ_VAL"
EOF
(set -u; . "$BOT_ENV"; [ -n "$BOT_TOKEN" ] && [ -n "$ADMIN_IDS" ] && [ -n "$XUI_API_TOKEN" ]) 2>/dev/null \
    || fail "bot.env невалиден"
ok "bot.env OK (600)"

# ===================================================================
step "systemd-юниты"
write_unit() { echo "$2" | safe_write "/etc/systemd/system/$1" 644 && ok "  $1"; }

write_unit "3x-ui-bot.service" "[Unit]
Description=3x-ui Telegram Bot
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
Environment=TZ=$TZ_VAL
Environment=LC_ALL=C.UTF-8
ExecStart=/bin/bash $BOT_SH run
Restart=always
RestartSec=5
StandardOutput=append:$BOT_DIR/logs/bot.log
StandardError=append:$BOT_DIR/logs/bot.log

[Install]
WantedBy=multi-user.target"

write_unit "3x-ui-bot-alerts.service" "[Unit]
Description=3x-ui Bot Alerts
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
Environment=TZ=$TZ_VAL
Environment=LC_ALL=C.UTF-8
ExecStart=/bin/bash $BOT_SH alerts-loop
Restart=always
RestartSec=10
StandardOutput=append:$BOT_DIR/logs/alerts.log
StandardError=append:$BOT_DIR/logs/alerts.log

[Install]
WantedBy=multi-user.target"

write_unit "3x-ui-bot-snapshot.service" "[Unit]
Description=3x-ui Bot — traffic snapshot
[Service]
Type=oneshot
WorkingDirectory=$BOT_DIR
Environment=TZ=$TZ_VAL
Environment=LC_ALL=C.UTF-8
ExecStart=/bin/bash $BOT_SH snapshot"

write_unit "3x-ui-bot-snapshot.timer" "[Unit]
Description=Hourly snapshot
[Timer]
OnCalendar=hourly
Persistent=true
Unit=3x-ui-bot-snapshot.service
[Install]
WantedBy=timers.target"

write_unit "3x-ui-bot-summary.service" "[Unit]
Description=3x-ui Bot — daily summary
[Service]
Type=oneshot
WorkingDirectory=$BOT_DIR
Environment=TZ=$TZ_VAL
Environment=LC_ALL=C.UTF-8
ExecStart=/bin/bash $BOT_SH summary"

write_unit "3x-ui-bot-summary.timer" "[Unit]
Description=Daily summary at ${SUM_HOUR}:00 ($TZ_VAL)
[Timer]
OnCalendar=*-*-* ${SUM_HOUR}:00:00
Persistent=true
Unit=3x-ui-bot-summary.service
[Install]
WantedBy=timers.target"

systemctl daemon-reload
ok "daemon-reload"

# ===================================================================
step "Запуск"
systemctl enable --now 3x-ui-bot.service 3x-ui-bot-alerts.service \
    3x-ui-bot-snapshot.timer 3x-ui-bot-summary.timer >>"$INSTALL_LOG" 2>&1 || warn "enable warning"
sleep 3
SF=0
for svc in 3x-ui-bot 3x-ui-bot-alerts; do
    if systemctl is-active --quiet "$svc"; then ok "$svc активен"
    else
        SF=$((SF+1)); warn "$svc НЕ активен"
        journalctl -u "$svc" -n 15 --no-pager 2>&1 | sed 's/^/    /'
    fi
done
info "Таймеры:"
systemctl list-timers --no-pager 2>/dev/null | grep 3x-ui-bot | sed 's/^/  /' || true

# ===================================================================
step "Первый snapshot"
/bin/bash "$BOT_SH" snapshot >>"$INSTALL_LOG" 2>&1 && ok "OK" || warn "snapshot error"

# ===================================================================
step "Аудит прав"
AF=0
audit() {
    if [ ! -e "$1" ]; then err "  MISSING: $1"; AF=$((AF+1)); return; fi
    local m; m=$(stat -c '%a' "$1")
    [ "$m" = "$2" ] && ok "  $1: $m" || { warn "  $1: $m (≠$2)"; AF=$((AF+1)); }
}
audit "$BOT_DIR" "755"
audit "$BOT_DIR/backups" "750"
audit "$BOT_DIR/logs" "750"
audit "$BOT_DIR/data" "755"
audit "$BOT_DIR/data/pending" "755"
audit "$BOT_SH" "755"
audit "$BOT_ENV" "600"
[ -f "$BOT_DIR/reality-keys.txt" ] && audit "$BOT_DIR/reality-keys.txt" "600"
audit "/etc/systemd/system/3x-ui-bot.service" "644"
audit "/etc/systemd/system/3x-ui-bot-alerts.service" "644"
[ "$AF" -eq 0 ] && ok "Аудит OK" || warn "Расхождений: $AF"

# ===================================================================
echo
[ "$SF" -eq 0 ] && [ "$AF" -eq 0 ] && ok "🎉 Установка успешно завершена!" || warn "Завершено с предупреждениями (svc=$SF audit=$AF)"

cat <<EOF

📂 $BOT_DIR
🔑 $BOT_ENV (600)
🤖 $BOT_SH (755)
🔐 $BOT_DIR/reality-keys.txt
📜 $INSTALL_LOG

Inbound'ы:
EOF
for spec in "${REQUIRED_INBOUNDS[@]}"; do IFS='|' read -r p r d s <<< "$spec"; echo "  • $r port=$p dest=$d SNI=$s"; done
cat <<EOF

Управление:
  systemctl {start|stop|restart|status} 3x-ui-bot 3x-ui-bot-alerts
  systemctl list-timers '3x-ui-bot-*'
  tail -f $BOT_DIR/logs/bot.log

Ручные:
  $BOT_SH summary    # сводка сейчас
  $BOT_SH snapshot   # снимок трафика
  $BOT_SH check      # разовая проверка алертов

Откройте бота в Telegram → /start (@$BOT_USER)
EOF

log_raw "=== installer v${INSTALLER_VERSION} OK ==="
exit 0
