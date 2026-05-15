#!/usr/bin/env bash
# install.sh — 3x-ui-bot installer v2.12
# Совместимость: Ubuntu 22.04 / 24.04
#
# Изменения v2.12:
#   * Добавлен shellcheck в зависимости (необязательный лайв-линт bot.sh)
#   * Фикс гонки date() при бэкапе bot.env
#   * MISSING/BAD/SF инициализируются заранее (set -u safety)
#   * Авто-предупреждение, если после автосоздания остались missing inbound'ы
#   * Чистка по shellcheck (SC2155): split declare/assign в нескольких местах
#
# Изменения v2.11:
#   * Надёжная детекция 3x-ui (unit-file/binary/dir/db/docker, см. detect_xui)
#   * Default-ответ на отсутствие 3x-ui изменён на Y
#   * --no-pager во всех systemctl list-*
#
# Изменения v2.10:
#   * Верификация SERVER_DOMAIN через DNS + /etc/hosts + external IP
#   * Авто-фикс /etc/hosts при несоответствиях (с бэкапом)
#   * Опциональный chattr +i для защиты от изменений

set -uo pipefail

INSTALLER_VERSION="2.12"
INSTALLER_PATH="$(readlink -f "$0")"
INSTALLER_DIR="$(dirname "$INSTALLER_PATH")"
INVOKE_PWD="$PWD"

# Инициализация переменных, к которым обращаемся под set -u
MISSING=()
BAD=()
SF=0
AF=0
BOT_USER=""
XUI_FOUND=0
XUI_SIGNS=()

# Флаги
NO_UPDATE=0
NO_BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --no-update) NO_UPDATE=1 ;;
        --no-backup) NO_BACKUP=1 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--no-update] [--no-backup]
  --no-update   пропустить apt update/upgrade
  --no-backup   пропустить бэкап 3x-ui
EOF
            exit 0 ;;
    esac
done

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

XUI_BACKUP_DIR="${INVOKE_PWD}/3X-ui_backup"

REQUIRED_INBOUNDS=(
    "443|main-443|www.kvnos.ru:443|www.kvnos.ru"
    "993|fallback-993|imap.yandex.ru:993|imap.yandex.ru"
    "587|fallback-587|www.sberbank.ru:443|www.sberbank.ru"
    "465|fallback-465|www.tinkoff.ru:443|www.tinkoff.ru"
)

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'
BLU='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
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
log_raw "Flags: NO_UPDATE=$NO_UPDATE NO_BACKUP=$NO_BACKUP"

ensure_dir() {
    local path="$1" mode="$2" owner="${3:-root}" group="${4:-root}"
    op "ensure_dir $path mode=$mode"
    if [ ! -d "$path" ]; then
        mkdir -p "$path" || { err "mkdir $path"; return 1; }
        ok "Создан: $path"
    fi
    chmod "$mode" "$path" || return 1
    chown "$owner:$group" "$path" || return 1
    local a
    a=$(stat -c '%a' "$path")
    [ "$a" = "$mode" ] || warn "  $path: $a ≠ $mode"
}
ensure_file() {
    local path="$1" mode="$2" initial="${3:-}" owner="${4:-root}" group="${5:-root}"
    op "ensure_file $path"
    if [ ! -e "$path" ]; then
        printf '%s' "$initial" > "$path" || return 1
        ok "Создан: $path"
    fi
    chmod "$mode" "$path" && chown "$owner:$group" "$path"
}
safe_write() {
    local path="$1" mode="$2"
    local tmp="${path}.new.$$"
    op "safe_write $path"
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" && chown root:root "$tmp"
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ===================================================================
# Детекция 3x-ui (несколько независимых признаков)
# ===================================================================
detect_xui() {
    XUI_FOUND=0
    XUI_SIGNS=()

    # 1) systemd unit (файл на диске)
    if [ -f /etc/systemd/system/x-ui.service ] \
       || [ -f /lib/systemd/system/x-ui.service ] \
       || [ -f /usr/lib/systemd/system/x-ui.service ]; then
        XUI_FOUND=1; XUI_SIGNS+=("unit-file")
    fi
    # 2) systemctl видит unit
    if systemctl list-unit-files --no-pager --type=service 2>/dev/null \
            | awk '{print $1}' | grep -qx 'x-ui.service'; then
        XUI_FOUND=1; XUI_SIGNS+=("list-unit-files")
    fi
    if systemctl cat x-ui.service >/dev/null 2>&1; then
        XUI_FOUND=1; XUI_SIGNS+=("systemctl-cat")
    fi
    # 3) бинарь
    if [ -x /usr/local/x-ui/x-ui ] || [ -x /usr/bin/x-ui ] || have_cmd x-ui; then
        XUI_FOUND=1; XUI_SIGNS+=("binary")
    fi
    # 4) каталоги
    if [ -d /usr/local/x-ui ] || [ -d /etc/x-ui ]; then
        XUI_FOUND=1; XUI_SIGNS+=("dir")
    fi
    # 5) база
    if [ -f /etc/x-ui/x-ui.db ]; then
        XUI_FOUND=1; XUI_SIGNS+=("db")
    fi
    # 6) docker
    if have_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -qiE '(^|[-_])(3?x-?ui)([-_]|$)'; then
        XUI_FOUND=1; XUI_SIGNS+=("docker")
    fi
}

# ===================================================================
# Верификация хоста (DNS + /etc/hosts + external IP)
# ===================================================================
verify_hostname() {
    local hostname="$1"

    echo
    info "Верификация хоста: ${BOLD}$hostname${NC}"

    if [[ "$hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        info "  Указан IP-адрес — проверка /etc/hosts не нужна"
        return 0
    fi

    if ! [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        warn "  Имя выглядит подозрительно (не похоже на FQDN)"
    fi

    local ext_ip=""
    for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ident.me; do
        ext_ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        [[ "$ext_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        ext_ip=""
    done
    if [ -n "$ext_ip" ]; then
        info "  Внешний IP сервера: ${BOLD}$ext_ip${NC}"
    else
        warn "  Не удалось определить внешний IP (нет интернета или все ip-сервисы недоступны)"
    fi

    local dns_ip
    dns_ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$dns_ip" ]; then
        info "  Резолвится в: ${BOLD}$dns_ip${NC}"
    else
        warn "  Имя НЕ резолвится (нет в DNS и нет в /etc/hosts)"
    fi

    local hosts_ip
    hosts_ip=$(awk -v h="$hostname" '
        !/^[[:space:]]*#/ {
            for (i=2; i<=NF; i++) if ($i==h) { print $1; exit }
        }' /etc/hosts 2>/dev/null | head -1)
    if [ -n "$hosts_ip" ]; then
        info "  /etc/hosts: $hosts_ip → $hostname"
    else
        info "  /etc/hosts: записи для $hostname нет"
    fi

    local needs_fix=0

    if [ -n "$hosts_ip" ]; then
        if [[ "$hosts_ip" =~ ^127\. ]]; then
            warn "  ❌ /etc/hosts указывает на localhost — клиенты НЕ смогут подключиться!"
            needs_fix=1
        elif [ -n "$ext_ip" ] && [ "$hosts_ip" != "$ext_ip" ]; then
            warn "  ⚠️  /etc/hosts: $hosts_ip ≠ внешний IP $ext_ip"
            needs_fix=1
        else
            ok "  ✓ /etc/hosts корректно"
        fi
    else
        if [ -z "$dns_ip" ]; then
            warn "  ⚠️  Имя нигде не резолвится — клиенты не подключатся"
            needs_fix=1
        elif [ -n "$ext_ip" ] && [ "$dns_ip" != "$ext_ip" ]; then
            warn "  ⚠️  DNS: $dns_ip ≠ внешний IP $ext_ip"
            warn "     Возможно DNS A-запись устарела или указывает на другой сервер"
            warn "     Рекомендуем поправить DNS, либо явно прописать в /etc/hosts"
            needs_fix=1
        else
            ok "  ✓ Хост корректно резолвится через DNS"
        fi
    fi

    if [ "$needs_fix" = "1" ] && [ -n "$ext_ip" ]; then
        echo
        warn "Предлагаю добавить/заменить запись в /etc/hosts:"
        echo -e "    ${BOLD}$ext_ip  $hostname${NC}"
        echo
        echo "    Это гарантирует, что:"
        echo "    • Локально (с самого сервера) имя резолвится правильно"
        echo "    • Клиенты в ссылках получат правильный адрес"
        echo
        read -rp "Применить изменение в /etc/hosts? (y/N): " a
        if [[ "$a" =~ ^[yY]$ ]]; then
            local ts
            ts=$(date +%Y%m%d-%H%M%S)
            local bkp="/etc/hosts.bak.${ts}"
            if ! cp -a /etc/hosts "$bkp" 2>/dev/null; then
                warn "  Не удалось сделать бэкап /etc/hosts"
                return 1
            fi
            ok "  Бэкап: $bkp"

            if command -v lsattr >/dev/null && lsattr /etc/hosts 2>/dev/null | head -1 | awk '{print $1}' | grep -q 'i'; then
                warn "  /etc/hosts помечен +i (immutable). Снимаю..."
                chattr -i /etc/hosts 2>/dev/null || warn "  Не удалось снять флаг (нужны права root и поддержка ФС)"
            fi

            awk -v h="$hostname" -v ts="$ts" '
                /^[[:space:]]*#/ { print; next }
                {
                    for (i=2; i<=NF; i++) {
                        if ($i==h) {
                            print "# auto-disabled by install.sh " ts ": " $0
                            next
                        }
                    }
                    print
                }' /etc/hosts > /etc/hosts.new && mv -f /etc/hosts.new /etc/hosts
            chmod 644 /etc/hosts
            chown root:root /etc/hosts

            echo "$ext_ip $hostname  # added by install.sh $ts" >> /etc/hosts
            ok "  /etc/hosts обновлён: $ext_ip $hostname"

            local new_ip
            new_ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1)
            if [ "$new_ip" = "$ext_ip" ]; then
                ok "  ✓ Проверка: $hostname → $new_ip"
            else
                warn "  Резолвится в $new_ip — что-то не так, посмотрите /etc/nsswitch.conf"
            fi

            read -rp "Поставить chattr +i на /etc/hosts (защита от случайных изменений)? (y/N): " a2
            if [[ "$a2" =~ ^[yY]$ ]]; then
                chattr +i /etc/hosts 2>/dev/null && ok "  /etc/hosts заморожен (+i)" || warn "  Не удалось"
            fi
        else
            warn "  /etc/hosts оставлен без изменений"
            warn "  Клиентские ссылки могут не работать корректно с этого сервера"
            hint "Поправьте вручную: $ext_ip $hostname"
        fi
    fi

    return 0
}

# ===================================================================
# Шаг 0: Чек-лист подготовки
# ===================================================================
clear
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              3x-ui-bot — Installer v${INSTALLER_VERSION}                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BOLD}📋 Перед установкой подготовьте следующее:${NC}"
echo
echo -e "${CYN}1. Telegram Bot Token${NC}"
echo "     ↳ Откройте @BotFather в Telegram → /newbot → следуйте инструкциям"
echo "     ↳ Скопируйте токен вида: 1234567890:ABCdef..."
echo
echo -e "${CYN}2. Telegram ID администратора(ов)${NC}"
echo "     ↳ Откройте @userinfobot в Telegram → отправьте /start"
echo "     ↳ Бот ответит вашим Telegram ID (число, например: 123456789)"
echo "     ↳ Можно несколько админов через пробел"
echo
echo -e "${CYN}3. 3x-ui API Token (Bearer)${NC}"
echo "     ↳ Откройте панель 3x-ui → Settings → Telegram Bot → Bot API Token"
echo "     ↳ Если поля нет — обновите 3x-ui до версии ≥3.0.1"
echo "     ↳ Скопируйте сгенерированную строку"
echo
echo -e "${CYN}4. Параметры панели 3x-ui (по умолчанию подхватятся из БД):${NC}"
echo "     ↳ URL: http(s)://<хост>:<порт><base_path>"
echo "     ↳ Обычно: https://127.0.0.1:2053/ (или ваш кастомный путь)"
echo
echo -e "${CYN}5. Полное имя хоста (видимое клиентам в ссылках)${NC}"
echo "     ↳ Это домен/поддомен сервера, к которому подключаются клиенты"
echo "     ↳ Примеры: vpn.example.com  •  msk3.mydomain.ru  •  myserver.org"
echo "     ↳ Должно резолвиться в ВНЕШНИЙ IP этого сервера"
echo "     ↳ Установщик ПРОВЕРИТ DNS и /etc/hosts, предложит исправить при ошибках"
echo "     ↳ По умолчанию: $(hostname -f 2>/dev/null || hostname)"
echo
echo -e "${DIM}   ⚠️  ВАЖНО: если в /etc/hosts указано неверное имя или 127.0.0.1 —${NC}"
echo -e "${DIM}      клиенты получат битые ссылки. Установщик это поймает.${NC}"

echo
echo -e "${YLW}⚠️  Что будет сделано:${NC}"
[ "$NO_BACKUP" = 0 ] && echo "  • Полный бэкап 3x-ui (БД + конфиги) → $XUI_BACKUP_DIR"
[ "$NO_UPDATE" = 0 ] && echo "  • Обновление системы (apt update + upgrade)"
echo "  • Установка зависимостей (curl, jq, sqlite3, gnuplot, openssl, shellcheck, etc.)"
echo "  • Создание /opt/3x-ui-bot/ с правильными правами"
echo "  • Автосоздание VLESS-Reality inbound'ов (если отсутствуют)"
echo "  • Создание защитных DUMMY-пользователей"
echo "  • Установка 4-х systemd-юнитов"
echo "  • Первичная диагностика"
echo
echo -e "${DIM}Бэкап позволит откатить ВСЁ к состоянию до установки бота через uninstall.sh${NC}"
echo
read -rp "▶ Готовы продолжить? (y/N): " ready
[[ "$ready" =~ ^[yY]$ ]] || { echo "Отменено. Подготовьте данные и запустите снова."; exit 0; }

# ===================================================================
# Шаг 1: Lock + базовые проверки
# ===================================================================
step "Lock + базовые проверки"
if [ -e "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        fail "Установщик уже запущен (pid $pid)"
    else
        warn "Старый lock pid $pid — удаляю"; rm -f "$LOCK_FILE"
    fi
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
# Шаг 2: Бэкап 3x-ui (ДО любых изменений)
# ===================================================================
if [ "$NO_BACKUP" = 1 ]; then
    step "Бэкап 3x-ui (пропущен по --no-backup)"
    warn "Бэкап НЕ создан — восстановление через uninstall.sh будет невозможно"
else
    step "Бэкап текущего состояния 3x-ui"

    op "create $XUI_BACKUP_DIR"
    mkdir -p "$XUI_BACKUP_DIR" || fail "Не могу создать $XUI_BACKUP_DIR"
    chmod 700 "$XUI_BACKUP_DIR"

    ts=$(date +%Y%m%d-%H%M%S)
    bkp_file="$XUI_BACKUP_DIR/3x-ui-pre-bot-${ts}.tar.gz"
    manifest="$XUI_BACKUP_DIR/manifest-${ts}.txt"

    BACKUP_PATHS=(
        /etc/x-ui
        /usr/local/x-ui
        /etc/systemd/system/x-ui.service
    )
    [ -d /etc/xray ] && BACKUP_PATHS+=(/etc/xray)
    [ -d /usr/local/etc/xray ] && BACKUP_PATHS+=(/usr/local/etc/xray)

    EXISTING=()
    for p in "${BACKUP_PATHS[@]}"; do
        [ -e "$p" ] && EXISTING+=("$p")
    done

    if [ ${#EXISTING[@]} -eq 0 ]; then
        warn "Файлы 3x-ui не найдены — создаю пустой манифест"
        echo "No 3x-ui files found on $(date)" > "$manifest"
    else
        info "Архивирую: ${EXISTING[*]}"
        op "tar czf $bkp_file"
        if tar czf "$bkp_file" "${EXISTING[@]}" 2>>"$INSTALL_LOG"; then
            ok "  Создан: $(basename "$bkp_file")"
        else
            fail "Не удалось создать архив бэкапа"
        fi

        op "tar -tzf verification"
        if tar -tzf "$bkp_file" >/dev/null 2>&1; then
            entries=$(tar -tzf "$bkp_file" | wc -l)
            size=$(du -h "$bkp_file" | cut -f1)
            ok "  Verification OK: $entries записей, $size"
        else
            fail "Архив повреждён, не проходит verification"
        fi

        chmod 600 "$bkp_file"

        cat > "$manifest" <<MANIFEST_EOF
3X-ui Backup Manifest
=====================
Created:           $(date)
Host:              $(hostname)
Installer version: $INSTALLER_VERSION
OS:                ${PRETTY_NAME:-unknown}
Kernel:            $(uname -r)

Files included:
$(printf '  %s\n' "${EXISTING[@]}")

Archive: $bkp_file
Size:    $(du -h "$bkp_file" | cut -f1)
Entries: $(tar -tzf "$bkp_file" | wc -l)
MD5:     $(md5sum "$bkp_file" | awk '{print $1}')

3x-ui version info:
$([ -f /usr/local/x-ui/x-ui ] && /usr/local/x-ui/x-ui -v 2>/dev/null || echo "  not detected")

x-ui database tables (at backup time):
$([ -f /etc/x-ui/x-ui.db ] && sqlite3 /etc/x-ui/x-ui.db ".tables" 2>/dev/null | tr ' ' '\n' | sed 's/^/  - /' || echo "  no DB")

Inbounds at backup time:
$([ -f /etc/x-ui/x-ui.db ] && sqlite3 /etc/x-ui/x-ui.db "SELECT id || ' | port=' || port || ' | ' || remark || ' | ' || protocol FROM inbounds;" 2>/dev/null | sed 's/^/  - /' || echo "  no DB")

==========================================
HOW TO RESTORE (если нужно откатить всё):
==========================================
  # 1. Остановить сервисы
  sudo systemctl stop x-ui 3x-ui-bot 3x-ui-bot-alerts 2>/dev/null

  # 2. Распаковать в корень
  sudo tar xzf "$bkp_file" -C /

  # 3. Перечитать systemd
  sudo systemctl daemon-reload

  # 4. Запустить x-ui
  sudo systemctl start x-ui

  # 5. Проверить
  sudo systemctl status x-ui --no-pager

ИЛИ просто:
  sudo /opt/3x-ui-bot/uninstall.sh
  # uninstall.sh сам предложит восстановление из этого бэкапа.
MANIFEST_EOF
        chmod 600 "$manifest"
        ok "  Manifest: $(basename "$manifest")"
    fi

    info "Бэкап сохранён в: $XUI_BACKUP_DIR"
    info "Размер: $(du -sh "$XUI_BACKUP_DIR" 2>/dev/null | cut -f1)"
fi

# ===================================================================
# Шаг 3: Обновление системы
# ===================================================================
if [ "$NO_UPDATE" = 1 ]; then
    step "Обновление системы (пропущено по --no-update)"
else
    step "Обновляем систему"
    op "apt update && upgrade"
    export DEBIAN_FRONTEND=noninteractive
    info "  Это может занять 1-3 минуты, прогресс пишется в лог..."
    {
        apt update -qq
        apt -y upgrade -qq
    } >> "$INSTALL_LOG" 2>&1 || warn "apt update/upgrade завершился с предупреждениями (см. лог)"
    ok "Система обновлена и готова к установке бота"
fi

# ===================================================================
# Шаг 4: Установка пакетов
# ===================================================================
step "Установка зависимостей"
op "apt install"
export DEBIAN_FRONTEND=noninteractive
PKGS=(curl jq sqlite3 gnuplot bc coreutils openssl ca-certificates tzdata
      iproute2 uuid-runtime python3 shellcheck)
apt install -y "${PKGS[@]}" >> "$INSTALL_LOG" 2>&1 || fail "apt install failed"
for t in curl jq sqlite3 gnuplot openssl ss uuidgen tar gzip awk sed grep date stat python3; do
    have_cmd "$t" || fail "Команда '$t' недоступна"
done
# Shell Check — некритичная зависимость (только для лайв-линта bot.sh)
if have_cmd shellcheck; then
    ok "${#PKGS[@]} пакетов в PATH (вкл. shellcheck $(shellcheck --version 2>/dev/null | awk '/version:/{print $2}'))"
else
    warn "shellcheck не установился — пропустим лайв-линт bot.sh"
    ok "${#PKGS[@]} пакетов в PATH"
fi

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
# Опциональный лайв-линт: только ERROR-уровень, чтобы не мешать warning-шумом
if have_cmd shellcheck; then
    if shellcheck -S error "$SRC_BOT_SH" >>"$INSTALL_LOG" 2>&1; then
        ok "shellcheck: ошибок не найдено"
    else
        warn "shellcheck нашёл проблемы в bot.sh (см. лог) — не критично, продолжаю"
    fi
fi
SRC_MD5=$(md5sum "$SRC_BOT_SH" | awk '{print $1}')

# ===================================================================
step "Каталоги"
for spec in "${DIR_SPEC[@]}"; do
    IFS='|' read -r p m <<< "$spec"
    ensure_dir "$p" "$m" || fail "Каталог $p"
done
ok "Каталоги готовы"

# ===================================================================
step "3x-ui"
detect_xui
if [ "$XUI_FOUND" = "1" ]; then
    ok "3x-ui обнаружен (признаки: ${XUI_SIGNS[*]})"
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        ok "x-ui сервис активен"
    elif have_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null \
            | grep -qiE '(^|[-_])(3?x-?ui)([-_]|$)'; then
        ok "x-ui работает в docker-контейнере"
    else
        warn "x-ui установлен, но сервис неактивен — продолжаю"
        hint "Запустить: systemctl start x-ui   (или docker start <name>)"
    fi
else
    warn "3x-ui не обнаружен ни одним из способов"
    hint "проверено: /etc/systemd/system/x-ui.service, /usr/local/x-ui, /etc/x-ui/x-ui.db, docker, бинарь x-ui"
    read -rp "Продолжить без 3x-ui? (Y/n): " a
    [[ "$a" =~ ^[nN]$ ]] && fail "Прервано пользователем"
fi

XRAY_BIN=""
for p in /usr/local/x-ui/bin/xray-linux-amd64 /usr/local/x-ui/bin/xray-linux-arm64 \
         /usr/local/x-ui/bin/xray /usr/local/bin/xray; do
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

echo; info "Reality dest/SNI:"
for spec in "${REQUIRED_INBOUNDS[@]}"; do
    IFS='|' read -r p r d s <<< "$spec"
    echo "    • $r → $d ($s)"
done

echo; info "Хост для клиентских ссылок:"
DEF_DOMAIN=$(hostname -f 2>/dev/null || hostname)
while :; do
    read -rp "  SERVER_DOMAIN (полное имя хоста) [$DEF_DOMAIN]: " SERVER_DOMAIN
    SERVER_DOMAIN="${SERVER_DOMAIN:-$DEF_DOMAIN}"

    if [[ "$SERVER_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || \
       [[ "$SERVER_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        verify_hostname "$SERVER_DOMAIN"
        echo
        read -rp "  Использовать '$SERVER_DOMAIN' для клиентских ссылок? (Y/n): " accept
        if [[ ! "$accept" =~ ^[nN]$ ]]; then
            break
        fi
        warn "Введите другое имя:"
        continue
    else
        warn "Некорректный формат имени хоста"
    fi
done

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
        if echo Q | timeout 5 openssl s_client -connect "${h}:${p}" -servername "$sni" -tls1_3 2>/dev/null \
                  | tr -d '\0' | grep -qE '(TLSv1\.3|TLS_AES_|TLS_CHACHA)'; then
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
        if [ -z "$is" ]; then
            ok "  ✅ $remark — vless+reality, net=$gn"
        else
            BAD+=("$remark:$is"); echo "  ⚠️  $remark —$is"
        fi
    done
}
check_inbounds "$api_resp"

# ===================================================================
if [ ${#MISSING[@]} -gt 0 ]; then
    step "Автосоздание недостающих inbound'ов"
    for spec in "${MISSING[@]}"; do
        IFS='|' read -r p r d s <<< "$spec"
        echo "    • $r → $d ($s)"
    done
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
                --arg d "$dest" --arg s "$sni" --arg priv "$REALITY_PRIV" \
                --arg pub "$REALITY_PUB" --arg sid "$SHORT_ID" '
                {network:"tcp",security:"reality",externalProxy:[],
                 realitySettings:{show:false,xver:0,dest:$d,serverNames:[$s],
                   privateKey:$priv,minClient:"",maxClient:"",maxTimediff:0,
                   shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},
                 tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}')
            local payload
            payload=$(jq -nc --arg r "$remark" --argjson port "$port" \
                --arg tag "inbound-${port}" --arg stream "$stream" '
                {up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,listen:"",port:$port,protocol:"vless",
                 settings:"{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}",streamSettings:$stream,tag:$tag,
                 sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
                 allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"}')
            local r
            r=$(xui_api POST "/panel/api/inbounds/add" "$payload" "add-${port}")
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
            create_inbound "$port" "$remark" "$dest" "$sni" \
                && CREATED=$((CREATED+1)) || FAILED=$((FAILED+1))
        done
        ok "Создано: $CREATED, ошибок: $FAILED"

        info "Перезапуск Xray..."
        rr=$(xui_api POST "/panel/api/inbounds/restartXray" "" "restart")
        if echo "$rr" | jq -e '.success==true' >/dev/null 2>&1; then
            ok "Xray перезапущен"
        else
            warn "API restartXray не сработал"
            systemctl restart x-ui >>"$INSTALL_LOG" 2>&1 || warn "systemctl restart x-ui тоже не помог"
        fi
        sleep 3

        step "Ретест"
        api_resp=$(xui_api GET "/panel/api/inbounds/list" "" "list2")
        echo "$api_resp" | jq -e '.success==true' >/dev/null 2>&1 || fail "API не отвечает"
        check_inbounds "$api_resp"
        if [ ${#MISSING[@]} -gt 0 ]; then
            warn "После автосоздания всё ещё нет: ${#MISSING[@]} inbound'ов"
            for spec in "${MISSING[@]}"; do
                IFS='|' read -r _ r _ _ <<< "$spec"
                echo "    ✗ $r"
            done
            hint "Создайте их вручную через панель и перезапустите установщик"
        fi

        info "TCP-прослушка:"
        for spec in "${REQUIRED_INBOUNDS[@]}"; do
            IFS='|' read -r port remark _ _ <<< "$spec"
            if timeout 2 bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
                ok "  :${port} ($remark)"
            else
                warn "  :${port} ($remark) НЕ слушается"
            fi
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
if [ ${#BAD[@]} -gt 0 ]; then
    step "Предупреждения по существующим"
    for b in "${BAD[@]}"; do echo "  ⚠️  $b"; done
    read -rp "Продолжить? (Y/n): " a
    [[ "$a" =~ ^[nN]$ ]] && fail "Прервано"
fi

# ===================================================================
step "Копирование bot.sh"
NEED=1
if [ -f "$BOT_SH" ]; then
    DST_MD5=$(md5sum "$BOT_SH" | awk '{print $1}')
    if [ "$DST_MD5" = "$SRC_MD5" ]; then
        ok "$BOT_SH идентичен — пропуск"; NEED=0
    else
        bk_ts=$(date +%Y%m%d-%H%M%S)
        bk="${BOT_SH}.bak.${bk_ts}"
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
for spec in "${FILE_SPEC[@]}"; do
    IFS='|' read -r p m i <<< "$spec"
    ensure_file "$p" "$m" "$i"
done

# ===================================================================
step "bot.env"
# ФИКС: один вычисленный timestamp, чтобы cp и chmod указывали на ОДИН и тот же файл
if [ -f "$BOT_ENV" ]; then
    env_bk_ts=$(date +%Y%m%d-%H%M%S)
    env_bk="${BOT_ENV}.bak.${env_bk_ts}"
    cp -a "$BOT_ENV" "$env_bk" && chmod 600 "$env_bk" && ok "Бэкап bot.env: $env_bk"
fi
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

# Где лежит бэкап 3x-ui ДО установки бота (для uninstall.sh)
XUI_PREBACKUP_DIR="$XUI_BACKUP_DIR"
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
    if systemctl is-active --quiet "$svc"; then
        ok "$svc активен"
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
    local m
    m=$(stat -c '%a' "$1")
    if [ "$m" = "$2" ]; then
        ok "  $1: $m"
    else
        warn "  $1: $m (≠$2)"; AF=$((AF+1))
    fi
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
if [ "$SF" -eq 0 ] && [ "$AF" -eq 0 ]; then
    ok "🎉 Установка успешно завершена!"
else
    warn "Завершено с предупреждениями (svc=$SF audit=$AF)"
fi

cat <<EOF

📂 $BOT_DIR
🔑 $BOT_ENV (600)
🤖 $BOT_SH (755)
🔐 $BOT_DIR/reality-keys.txt
📜 $INSTALL_LOG
EOF
[ "$NO_BACKUP" = 0 ] && echo "💾 $XUI_BACKUP_DIR (бэкап 3x-ui — НЕ удаляйте!)"

cat <<EOF

Inbound'ы:
EOF
for spec in "${REQUIRED_INBOUNDS[@]}"; do
    IFS='|' read -r p r d s <<< "$spec"
    echo "  • $r port=$p dest=$d SNI=$s"
done
cat <<EOF

Управление:
  systemctl {start|stop|restart|status} 3x-ui-bot 3x-ui-bot-alerts
  systemctl list-timers '3x-ui-bot-*'
  tail -f $BOT_DIR/logs/bot.log

Ручные:
  $BOT_SH summary    # сводка сейчас
  $BOT_SH snapshot   # снимок трафика
  $BOT_SH check      # разовая проверка алертов

Откатить всё (вернуть к состоянию ДО установки):
  sudo /opt/3x-ui-bot/uninstall.sh
  # → uninstall.sh найдёт бэкап в $XUI_BACKUP_DIR и предложит восстановление

Откройте бота в Telegram → /start (@$BOT_USER)
EOF

log_raw "=== installer v${INSTALLER_VERSION} OK ==="
exit 0
