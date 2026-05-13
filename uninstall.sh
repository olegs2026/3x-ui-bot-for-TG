#!/usr/bin/env bash
# uninstall.sh — корректное удаление 3x-ui-bot (v1.1)
# Совместимость: Ubuntu 22.04 / 24.04
#
# Опции:
#   --yes / -y         без подтверждений
#   --keep-backups     сохранить backups/
#   --keep-config      сохранить bot.env / reality-keys.txt
#   --keep-logs        сохранить logs/
#   --keep-all         оставить ВСЁ в /opt/3x-ui-bot/, только остановить
#   --purge            удалить + DUMMY-пользователей из 3x-ui
#   --dry-run          только показать, что будет сделано
#
set -uo pipefail

VERSION="1.1"
BOT_DIR="${BOT_DIR:-/opt/3x-ui-bot}"
BOT_ENV="$BOT_DIR/bot.env"
LOG_FILE="/tmp/3x-ui-bot-uninstall-$(date +%Y%m%d-%H%M%S).log"
SAVE_DIR="/root/3x-ui-bot-saved-$(date +%Y%m%d-%H%M%S)"

YES=0; KEEP_BACKUPS=0; KEEP_CONFIG=0; KEEP_LOGS=0; KEEP_ALL=0; PURGE=0; DRY=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y)       YES=1 ;;
        --keep-backups) KEEP_BACKUPS=1 ;;
        --keep-config)  KEEP_CONFIG=1 ;;
        --keep-logs)    KEEP_LOGS=1 ;;
        --keep-all)     KEEP_ALL=1 ;;
        --purge)        PURGE=1 ;;
        --dry-run)      DRY=1 ;;
        -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log_raw(){ echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
info(){ echo -e "${CYN}[i]${NC} $*"; log_raw "INFO: $*"; }
ok()  { echo -e "${GRN}[✓]${NC} $*"; log_raw "OK:   $*"; }
warn(){ echo -e "${YLW}[!]${NC} $*"; log_raw "WARN: $*"; }
err() { echo -e "${RED}[✗]${NC} $*" >&2; log_raw "ERR:  $*"; }
step(){ echo; echo -e "${BLU}━━━ $* ━━━${NC}"; log_raw "===== $* ====="; }
hint(){ echo -e "    ↳ $*"; }

run() {
    if [ "$DRY" = 1 ]; then echo "    [DRY] $*"; log_raw "DRY: $*"; return 0; fi
    log_raw "RUN: $*"
    "$@"
}

[[ $EUID -ne 0 ]] && { err "Запустите от root"; exit 1; }

log_raw "=== uninstall v${VERSION} ==="
log_raw "Flags: YES=$YES KEEP_BACKUPS=$KEEP_BACKUPS KEEP_CONFIG=$KEEP_CONFIG KEEP_LOGS=$KEEP_LOGS KEEP_ALL=$KEEP_ALL PURGE=$PURGE DRY=$DRY"

clear
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          3x-ui-bot — Uninstall v${VERSION}                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "Будет выполнено:"
echo "  • Остановка и отключение systemd-юнитов"
echo "  • Удаление файлов юнитов из /etc/systemd/system/"
if [ "$KEEP_ALL" = 1 ]; then
    echo "  • $BOT_DIR — НЕ удаляется (--keep-all)"
else
    echo "  • Удаление $BOT_DIR"
    [ "$KEEP_BACKUPS" = 1 ] && echo "      ⤷ кроме backups/ (сохраним в $SAVE_DIR)"
    [ "$KEEP_CONFIG" = 1 ]  && echo "      ⤷ кроме bot.env / reality-keys.txt"
    [ "$KEEP_LOGS" = 1 ]    && echo "      ⤷ кроме logs/"
fi
[ "$PURGE" = 1 ] && echo "  • PURGE: удалить DUMMY-пользователей из 3x-ui"
[ "$DRY" = 1 ] && echo "  • DRY-RUN: только показ, без изменений"
echo
echo "НЕ будет затронуто:"
echo "  • Сама панель 3x-ui (x-ui.service, /etc/x-ui)"
echo "  • Inbound'ы и реальные клиенты"
echo "  • Telegram-бот в @BotFather (токен останется)"
echo

if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
    echo -en "${YLW}Продолжить? Введите 'yes' для подтверждения: ${NC}"
    read -r a
    [ "$a" != "yes" ] && { echo "Отменено."; exit 0; }

    if [ "$KEEP_ALL" = 0 ] && [ "$KEEP_BACKUPS" = 0 ] && [ "$KEEP_CONFIG" = 0 ] && [ "$KEEP_LOGS" = 0 ]; then
        echo
        echo "Хотите что-то сохранить?"
        read -rp "  Сохранить бэкапы в $SAVE_DIR? (y/N): " x
        [[ "$x" =~ ^[yY]$ ]] && KEEP_BACKUPS=1
        read -rp "  Сохранить bot.env и reality-keys.txt? (y/N): " x
        [[ "$x" =~ ^[yY]$ ]] && KEEP_CONFIG=1
        read -rp "  Сохранить логи? (y/N): " x
        [[ "$x" =~ ^[yY]$ ]] && KEEP_LOGS=1
    fi

    if [ "$PURGE" = 0 ] && [ -f "$BOT_ENV" ]; then
        echo
        read -rp "  Удалить DUMMY-пользователей из 3x-ui? (y/N): " x
        [[ "$x" =~ ^[yY]$ ]] && PURGE=1
    fi
fi

# ===================================================================
step "Остановка systemd-юнитов"
UNITS=(
    3x-ui-bot.service
    3x-ui-bot-alerts.service
    3x-ui-bot-snapshot.timer
    3x-ui-bot-snapshot.service
    3x-ui-bot-summary.timer
    3x-ui-bot-summary.service
)

for u in "${UNITS[@]}"; do
    loaded=$(systemctl show -p LoadState --value "$u" 2>/dev/null)
    if [ -n "$loaded" ] && [ "$loaded" != "not-found" ]; then
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            run systemctl stop "$u" 2>>"$LOG_FILE" && ok "  stop $u"
        else
            info "  $u: уже не активен"
        fi
        if systemctl is-enabled --quiet "$u" 2>/dev/null; then
            run systemctl disable "$u" 2>>"$LOG_FILE" && ok "  disable $u"
        fi
    else
        info "  $u: не установлен"
    fi
done

op_pids=$(pgrep -f "$BOT_DIR/bot.sh" 2>/dev/null || true)
if [ -n "$op_pids" ]; then
    warn "Найдены процессы bot.sh: $op_pids"
    for p in $op_pids; do run kill "$p" 2>/dev/null || true; done
    sleep 1
    op_pids=$(pgrep -f "$BOT_DIR/bot.sh" 2>/dev/null || true)
    [ -n "$op_pids" ] && { warn "Жёсткое kill -9: $op_pids"; for p in $op_pids; do run kill -9 "$p" 2>/dev/null || true; done; }
fi

# ===================================================================
if [ "$PURGE" = 1 ] && [ -r "$BOT_ENV" ]; then
    step "Удаление DUMMY-пользователей из 3x-ui"

    if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
        warn "jq/curl недоступны — пропуск"
    else
        # shellcheck source=/dev/null
        . "$BOT_ENV"
        : "${XUI_SCHEME:=http}"
        : "${XUI_HOST:=127.0.0.1}"
        : "${XUI_PORT:=2053}"
        : "${XUI_PATH:=/}"
        : "${XUI_API_TOKEN:=}"
        API="${XUI_SCHEME}://${XUI_HOST}:${XUI_PORT}${XUI_PATH%/}"

        if [ -z "$XUI_API_TOKEN" ]; then
            warn "XUI_API_TOKEN пуст — пропуск"
        else
            xapi() {
                local m="$1" p="$2" d="${3:-}"
                if [ -n "$d" ]; then
                    curl -sk --max-time 15 -X "$m" "${API}${p}" \
                        -H "Authorization: Bearer ${XUI_API_TOKEN}" \
                        -H "Content-Type: application/json" \
                        -H "Accept: application/json" -d "$d"
                else
                    curl -sk --max-time 15 -X "$m" "${API}${p}" \
                        -H "Authorization: Bearer ${XUI_API_TOKEN}" \
                        -H "Accept: application/json"
                fi
            }

            list=$(xapi GET "/panel/api/inbounds/list")
            if echo "$list" | jq -e '.success==true' >/dev/null 2>&1; then
                pairs=$(echo "$list" | jq -r '
                    .obj[]? as $i
                    | ($i.settings|fromjson).clients[]?
                    | select(.email|startswith("DUMMY-"))
                    | "\($i.id) \(.id) \(.email)"')

                if [ -z "$pairs" ]; then
                    info "  DUMMY-пользователей не найдено"
                else
                    DEL_OK=0; DEL_FAIL=0
                    while IFS=' ' read -r ib uuid email; do
                        [ -z "$ib" ] && continue
                        if [ "$DRY" = 1 ]; then echo "    [DRY] delClient $email"; continue; fi
                        r=$(xapi POST "/panel/api/inbounds/${ib}/delClient/${uuid}")
                        if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then
                            ok "  - $email"; DEL_OK=$((DEL_OK+1))
                        else
                            err "  ✗ $email: $(echo "$r" | jq -r '.msg // "?"')"; DEL_FAIL=$((DEL_FAIL+1))
                        fi
                    done <<< "$pairs"
                    info "DUMMY: удалено=$DEL_OK, ошибок=$DEL_FAIL"
                    if [ "$DEL_OK" -gt 0 ] && [ "$DRY" = 0 ]; then
                        xapi POST "/panel/api/inbounds/restartXray" >/dev/null
                        info "  Xray перезапущен"
                    fi
                fi
            else
                warn "API не отвечает — DUMMY не удалены"
            fi
        fi
    fi
fi

# ===================================================================
if [ "$KEEP_ALL" = 0 ] && { [ "$KEEP_BACKUPS" = 1 ] || [ "$KEEP_CONFIG" = 1 ] || [ "$KEEP_LOGS" = 1 ]; }; then
    step "Сохранение → $SAVE_DIR"
    run mkdir -p "$SAVE_DIR"

    [ "$KEEP_BACKUPS" = 1 ] && [ -d "$BOT_DIR/backups" ] && run cp -a "$BOT_DIR/backups" "$SAVE_DIR/" && ok "  backups → $SAVE_DIR/backups"

    if [ "$KEEP_CONFIG" = 1 ]; then
        for f in bot.env reality-keys.txt; do
            [ -f "$BOT_DIR/$f" ] && run cp -a "$BOT_DIR/$f" "$SAVE_DIR/" && ok "  $f → $SAVE_DIR/"
        done
    fi

    [ "$KEEP_LOGS" = 1 ] && [ -d "$BOT_DIR/logs" ] && run cp -a "$BOT_DIR/logs" "$SAVE_DIR/" && ok "  logs → $SAVE_DIR/logs"

    if [ "$DRY" = 0 ] && [ -d "$SAVE_DIR" ]; then
        run chmod 700 "$SAVE_DIR"
        run chown root:root "$SAVE_DIR"
        ok "  $SAVE_DIR (chmod 700)"
    fi
fi

# ===================================================================
step "Удаление файлов юнитов"
for u in "${UNITS[@]}"; do
    f="/etc/systemd/system/$u"
    [ -e "$f" ] && run rm -f "$f" && ok "  - $f"
done

for d in /etc/systemd/system/multi-user.target.wants /etc/systemd/system/timers.target.wants; do
    for u in "${UNITS[@]}"; do
        l="$d/$u"
        [ -L "$l" ] && run rm -f "$l" && ok "  - $l"
    done
done

run systemctl daemon-reload
run systemctl reset-failed 2>/dev/null || true
ok "  daemon-reload"

# ===================================================================
if [ "$KEEP_ALL" = 1 ]; then
    step "Каталог $BOT_DIR оставлен (--keep-all)"
else
    step "Удаление $BOT_DIR"
    if [ ! -d "$BOT_DIR" ]; then
        info "  Каталог отсутствует"
    else
        run rm -rf "$BOT_DIR" && ok "  - $BOT_DIR удалён"
    fi
fi

# ===================================================================
step "Очистка временных файлов"
LOCK="/var/lock/3x-ui-bot-install.lock"
[ -e "$LOCK" ] && run rm -f "$LOCK" && ok "  - $LOCK"

api_dumps=$(ls /tmp/3x-ui-bot-api-*.{req,res} 2>/dev/null || true)
if [ -n "$api_dumps" ]; then
    cnt=$(echo "$api_dumps" | wc -l)
    if [ "$YES" = 1 ] || [ "$DRY" = 1 ]; then
        for f in $api_dumps; do run rm -f "$f"; done
        ok "  - $cnt временных API-дампов"
    else
        read -rp "  Удалить $cnt API-дампов из /tmp/? (y/N): " x
        if [[ "$x" =~ ^[yY]$ ]]; then
            for f in $api_dumps; do run rm -f "$f"; done
            ok "  - удалены"
        fi
    fi
fi

# ===================================================================
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
if [ "$DRY" = 1 ]; then
    echo -e "${BOLD}║                 DRY-RUN — изменений не было                  ║${NC}"
else
    echo -e "${BOLD}║                3x-ui-bot удалён успешно                       ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

LEFT=()
[ -d "$BOT_DIR" ] && [ "$KEEP_ALL" = 0 ] && LEFT+=("$BOT_DIR (не удалился)")
for u in "${UNITS[@]}"; do
    [ -e "/etc/systemd/system/$u" ] && LEFT+=("/etc/systemd/system/$u")
done
running=$(pgrep -f "$BOT_DIR/bot.sh" 2>/dev/null || true)
[ -n "$running" ] && LEFT+=("процессы bot.sh: $running")

if [ ${#LEFT[@]} -gt 0 ] && [ "$DRY" = 0 ]; then
    warn "Не до конца очищено:"
    for x in "${LEFT[@]}"; do echo "    • $x"; done
fi

echo "📜 Лог:         $LOG_FILE"
if [ -d "$SAVE_DIR" ] && [ "$DRY" = 0 ]; then
    echo "💾 Сохранено в: $SAVE_DIR"
    ls -la "$SAVE_DIR" 2>/dev/null | sed 's/^/      /' | head -20
fi

echo
echo "Не затронуто:"
echo "  • 3x-ui (x-ui.service, /etc/x-ui, /usr/local/x-ui)"
echo "  • Inbound'ы и реальные клиенты"
[ "$PURGE" = 0 ] && echo "  • DUMMY-пользователи (используйте --purge для удаления)"
echo "  • Telegram-бот у @BotFather (токен остался)"
echo
echo "ℹ️  Если хотите удалить установленные пакеты:"
echo "    sudo apt remove --purge gnuplot uuid-runtime"
echo

[ ${#LEFT[@]} -eq 0 ] && [ "$DRY" = 0 ] && exit 0
[ "$DRY" = 1 ] && exit 0
exit 2
