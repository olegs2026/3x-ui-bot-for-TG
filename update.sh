#!/usr/bin/env bash
# update.sh — обновление 3x-ui-bot на работающем сервере (v1.1)
# Совместимость: Ubuntu 22.04 / 24.04
#
# Возможности:
#   * автопоиск нового bot.sh ($PWD, dirname $0, /root, /tmp)
#   * sanity-check (bash -n) до замены
#   * md5-сравнение — пропуск если идентично
#   * атомарная замена через install
#   * бэкап в backups/update-YYYYMMDD-HHMMSS/
#   * graceful restart с health-check
#   * автоматический rollback при неудачном старте
#   * --rollback для отката
#
# Опции:
#   --yes / -y      без подтверждений
#   --diff          показать diff и спросить
#   --no-restart    заменить файл без рестарта
#   --rollback      откат на предыдущую версию
#   --keep N        хранить N последних бэкапов (default 10)
#   --dry-run       только показать план
#   --force         заменить даже если md5 совпадает
#
set -uo pipefail

VERSION="1.1"
BOT_DIR="${BOT_DIR:-/opt/3x-ui-bot}"
BOT_ENV="$BOT_DIR/bot.env"
BOT_SH="$BOT_DIR/bot.sh"
BOT_SH_NAME="bot.sh"
LOG_FILE="$BOT_DIR/logs/update.log"

INSTALLER_DIR="$(dirname "$(readlink -f "$0")")"
INVOKE_PWD="$PWD"

YES=0; SHOW_DIFF=0; NO_RESTART=0; ROLLBACK=0; KEEP=10; DRY=0; FORCE=0
HEALTH_TIMEOUT=15

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)     YES=1; shift ;;
        --diff)       SHOW_DIFF=1; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        --rollback)   ROLLBACK=1; shift ;;
        --keep)       KEEP="$2"; shift 2 ;;
        --dry-run)    DRY=1; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLU='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
CURRENT_OP=""

log_raw(){ mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
info(){ echo -e "${CYN}[i]${NC} $*"; log_raw "INFO: $*"; }
ok()  { echo -e "${GRN}[✓]${NC} $*"; log_raw "OK:   $*"; }
warn(){ echo -e "${YLW}[!]${NC} $*"; log_raw "WARN: $*"; }
err() { echo -e "${RED}[✗]${NC} $*" >&2; log_raw "ERR:  $*"; }
step(){ echo; echo -e "${BLU}━━━ $* ━━━${NC}"; log_raw "===== $* ====="; }
hint(){ echo -e "    ${DIM}↳ $*${NC}"; }
op()  { CURRENT_OP="$*"; log_raw "OP: $*"; }
fail(){ err "$*"; err "Лог: $LOG_FILE"; exit 1; }

run() {
    if [ "$DRY" = 1 ]; then echo "    [DRY] $*"; log_raw "DRY: $*"; return 0; fi
    log_raw "RUN: $*"
    "$@"
}

[[ $EUID -ne 0 ]] && fail "Запустите от root (sudo $0)"

step "Pre-flight"
log_raw "=== update v${VERSION} (PWD=$INVOKE_PWD, script=$INSTALLER_DIR) ==="

[ -d "$BOT_DIR" ]  || fail "$BOT_DIR не существует — сначала install.sh"
[ -f "$BOT_SH" ]   || fail "$BOT_SH не найден"
[ -f "$BOT_ENV" ]  || warn "$BOT_ENV отсутствует"

for t in curl jq systemctl md5sum diff bash install; do
    command -v "$t" >/dev/null || fail "$t не найден"
done
ok "Окружение OK"

# ===================================================================
# ROLLBACK
# ===================================================================
if [ "$ROLLBACK" = 1 ]; then
    step "Rollback на предыдущую версию"
    last=$(ls -1dt "$BOT_DIR"/backups/update-* 2>/dev/null | head -1)
    if [ -z "$last" ]; then fail "Нет предыдущих обновлений в $BOT_DIR/backups/update-*"; fi
    info "Источник: $last"
    [ -f "$last/bot.sh" ] || fail "В $last нет bot.sh"

    if [ "$YES" != 1 ]; then
        read -rp "Откатить $BOT_SH на версию из $last? (y/N): " a
        [[ "$a" =~ ^[yY]$ ]] || { echo "Отменено."; exit 0; }
    fi

    op "rollback bot.sh"
    run cp -a "$BOT_SH" "$BOT_SH.before-rollback.$(date +%Y%m%d-%H%M%S)"
    run install -m 755 -o root -g root "$last/bot.sh" "$BOT_SH" || fail "install failed"
    ok "bot.sh восстановлен"

    if [ "$NO_RESTART" = 0 ]; then
        run systemctl restart 3x-ui-bot 3x-ui-bot-alerts
        sleep 3
        if systemctl is-active --quiet 3x-ui-bot; then
            ok "Сервисы перезапущены"
        else
            err "Сервисы не стартовали после отката"
            journalctl -u 3x-ui-bot -n 15 --no-pager | sed 's/^/  /'
            exit 1
        fi
    fi
    echo; ok "🔄 Rollback завершён"
    exit 0
fi

# ===================================================================
step "Поиск нового $BOT_SH_NAME"
SRC=""
CANDIDATES=("$INVOKE_PWD/$BOT_SH_NAME" "$INSTALLER_DIR/$BOT_SH_NAME" "/root/$BOT_SH_NAME" "/tmp/$BOT_SH_NAME")
for c in "${CANDIDATES[@]}"; do
    [ "$c" = "$BOT_SH" ] && continue
    if [ -f "$c" ]; then SRC="$c"; break; fi
done

[ -z "$SRC" ] && fail "Новый $BOT_SH_NAME не найден:
$(printf '    %s\n' "${CANDIDATES[@]}")"
ok "Источник: $SRC ($(stat -c '%s' "$SRC") байт)"

# ===================================================================
step "Анализ изменений"
SRC_MD5=$(md5sum "$SRC"    | awk '{print $1}')
DST_MD5=$(md5sum "$BOT_SH" | awk '{print $1}')

echo "  Текущий:  $DST_MD5  ($(stat -c '%s' "$BOT_SH") байт, изменён $(stat -c '%y' "$BOT_SH" | cut -d. -f1))"
echo "  Новый:    $SRC_MD5  ($(stat -c '%s' "$SRC") байт, изменён $(stat -c '%y' "$SRC" | cut -d. -f1))"

if [ "$SRC_MD5" = "$DST_MD5" ] && [ "$FORCE" = 0 ]; then
    ok "Версии идентичны — обновление не требуется"
    echo; echo "Если хотите всё равно переустановить: --force"
    exit 0
fi

if [ "$SHOW_DIFF" = 1 ] || [ "$YES" != 1 ]; then
    echo
    echo -e "${DIM}── diff (первые 80 строк) ──${NC}"
    diff -u "$BOT_SH" "$SRC" 2>/dev/null | head -80 | sed 's/^/  /'
    diff_lines=$(diff -u "$BOT_SH" "$SRC" 2>/dev/null | wc -l)
    [ "$diff_lines" -gt 80 ] && echo -e "  ${DIM}... ещё $((diff_lines-80)) строк ...${NC}"
    echo -e "${DIM}── /diff ──${NC}"
fi

# ===================================================================
step "Проверка нового bot.sh"
op "bash -n $SRC"
bash -n "$SRC" 2>>"$LOG_FILE" || fail "Новый bot.sh содержит синтаксические ошибки"
ok "Синтаксис: OK"

REQUIRED_SUBS=(run alerts-loop snapshot summary check)
for sub in "${REQUIRED_SUBS[@]}"; do
    grep -qE "^\s*${sub}\)" "$SRC" || warn "В новом bot.sh нет ветки '${sub})'"
done

if [ -f "$BOT_ENV" ]; then
    new_vars=$(grep -oE ': *"\$\{[A-Z_]+:=' "$SRC" | sed 's/.*\${//;s/:=.*//' | sort -u)
    missing=()
    for v in $new_vars; do
        grep -q "^${v}=" "$BOT_ENV" || missing+=("$v")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "В bot.env отсутствуют переменные:"
        for m in "${missing[@]}"; do echo "    • $m"; done
        hint "Бот использует дефолты, но проверьте"
    else
        ok "bot.env содержит все ожидаемые переменные"
    fi
fi

# ===================================================================
echo
echo "Будет выполнено:"
echo "  1. Бэкап $BOT_SH и $BOT_ENV → $BOT_DIR/backups/update-YYYYMMDD-HHMMSS/"
echo "  2. Замена $BOT_SH (атомарно через install)"
if [ "$NO_RESTART" = 0 ]; then
    echo "  3. Рестарт сервисов: 3x-ui-bot, 3x-ui-bot-alerts"
    echo "  4. Health-check (${HEALTH_TIMEOUT}с)"
    echo "  5. Авто-rollback при падении"
else
    echo "  3. Без рестарта (--no-restart)"
fi
[ "$DRY" = 1 ] && echo "  ⚠️  DRY-RUN: ничего не меняем"
echo

if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
    read -rp "Продолжить? (Y/n): " a
    [[ "$a" =~ ^[nN]$ ]] && { echo "Отменено."; exit 0; }
fi

# ===================================================================
step "Бэкап текущей версии"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BOT_DIR/backups/update-$TS"
run mkdir -p "$BACKUP_DIR"
run chmod 700 "$BACKUP_DIR"

run cp -a "$BOT_SH" "$BACKUP_DIR/bot.sh" && ok "  bot.sh"
[ -f "$BOT_ENV" ] && run cp -a "$BOT_ENV" "$BACKUP_DIR/bot.env" && run chmod 600 "$BACKUP_DIR/bot.env" && ok "  bot.env"

if [ "$DRY" = 0 ]; then
    cat > "$BACKUP_DIR/meta.json" <<EOF
{
  "ts": "$TS",
  "old_md5": "$DST_MD5",
  "new_md5": "$SRC_MD5",
  "old_size": $(stat -c '%s' "$BOT_SH"),
  "new_size": $(stat -c '%s' "$SRC"),
  "source": "$SRC",
  "updater_version": "$VERSION"
}
EOF
    chmod 600 "$BACKUP_DIR/meta.json"
fi
ok "  meta.json"
info "Бэкап: $BACKUP_DIR"

# ===================================================================
ROLLBACK_DONE=0
rollback_now() {
    [ "$ROLLBACK_DONE" = 1 ] && return
    ROLLBACK_DONE=1
    warn "Выполняю автоматический rollback..."
    if [ -f "$BACKUP_DIR/bot.sh" ]; then
        install -m 755 -o root -g root "$BACKUP_DIR/bot.sh" "$BOT_SH" 2>>"$LOG_FILE"
        ok "  bot.sh восстановлен"
    fi
    systemctl restart 3x-ui-bot 3x-ui-bot-alerts 2>>"$LOG_FILE" || true
    sleep 3
    if systemctl is-active --quiet 3x-ui-bot; then
        ok "Сервисы стартовали после отката"
    else
        err "Сервисы не стартовали даже после отката!"
        journalctl -u 3x-ui-bot -n 30 --no-pager | sed 's/^/    /'
    fi
}

# ===================================================================
if [ "$NO_RESTART" = 0 ]; then
    step "Остановка сервисов"
    for svc in 3x-ui-bot.service 3x-ui-bot-alerts.service; do
        if systemctl is-active --quiet "$svc"; then
            run systemctl stop "$svc" && ok "  stop $svc"
        else
            info "  $svc: уже не активен"
        fi
    done
    sleep 1
fi

# ===================================================================
step "Замена $BOT_SH"
op "install $SRC → $BOT_SH"
if ! run install -m 755 -o root -g root "$SRC" "$BOT_SH"; then
    err "install failed"
    rollback_now
    fail "Замена не удалась"
fi

if [ "$DRY" = 0 ]; then
    new_md5=$(md5sum "$BOT_SH" | awk '{print $1}')
    if [ "$new_md5" = "$SRC_MD5" ]; then
        ok "bot.sh обновлён (md5=$new_md5)"
    else
        err "md5 не совпадает! ($new_md5 ≠ $SRC_MD5)"
        rollback_now
        fail "Целостность нарушена"
    fi
fi

op "bash -n $BOT_SH (после замены)"
if [ "$DRY" = 0 ] && ! bash -n "$BOT_SH" 2>>"$LOG_FILE"; then
    err "Установленный bot.sh оказался битым"
    rollback_now
    fail "Синтаксис не прошёл"
fi

# ===================================================================
if [ "$NO_RESTART" = 0 ]; then
    step "Запуск сервисов"
    for svc in 3x-ui-bot.service 3x-ui-bot-alerts.service; do
        run systemctl start "$svc" || warn "  start $svc вернул ошибку"
    done

    step "Health-check (${HEALTH_TIMEOUT}с)"
    elapsed=0
    interval=2
    HEALTHY=0
    while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
        bot_ok=$(systemctl is-active 3x-ui-bot 2>/dev/null)
        alerts_ok=$(systemctl is-active 3x-ui-bot-alerts 2>/dev/null)
        if [ "$bot_ok" = "active" ] && [ "$alerts_ok" = "active" ]; then
            HEALTHY=1
            echo -e "  ${GRN}[${elapsed}s]${NC} bot=$bot_ok alerts=$alerts_ok"
            break
        fi
        echo -e "  ${DIM}[${elapsed}s]${NC} bot=$bot_ok alerts=$alerts_ok ... ждём"
        sleep "$interval"
        elapsed=$((elapsed+interval))
    done

    if [ "$HEALTHY" = 1 ]; then
        ok "Сервисы здоровы"
    else
        err "Сервисы не стали активны за ${HEALTH_TIMEOUT}с"
        echo
        echo "─── journalctl -u 3x-ui-bot -n 20 ───"
        journalctl -u 3x-ui-bot -n 20 --no-pager | sed 's/^/  /'
        echo "─── journalctl -u 3x-ui-bot-alerts -n 10 ───"
        journalctl -u 3x-ui-bot-alerts -n 10 --no-pager | sed 's/^/  /'
        echo
        if [ "$YES" = 1 ]; then
            rollback_now
            fail "Автоматический rollback выполнен"
        else
            read -rp "Откатить? (Y/n): " a
            if [[ ! "$a" =~ ^[nN]$ ]]; then
                rollback_now
                fail "Rollback выполнен"
            else
                warn "Оставляем новую версию (несмотря на проблемы)"
            fi
        fi
    fi

    sleep 2
    if [ -f "$BOT_DIR/logs/bot.log" ]; then
        recent_errors=$(tail -50 "$BOT_DIR/logs/bot.log" | grep -iE 'error|fatal|traceback' | wc -l)
        if [ "$recent_errors" -gt 3 ]; then
            warn "В последних 50 строках bot.log: $recent_errors ошибок"
            hint "tail -f $BOT_DIR/logs/bot.log"
        fi
    fi
fi

# ===================================================================
step "Ротация бэкапов"
old=$(ls -1dt "$BOT_DIR"/backups/update-* 2>/dev/null | tail -n "+$((KEEP+1))")
if [ -n "$old" ]; then
    cnt=$(echo "$old" | wc -l)
    info "Удаляю $cnt старых бэкапов (оставляю $KEEP)"
    for d in $old; do run rm -rf "$d" && echo "    - $(basename "$d")"; done
else
    info "Нечего ротировать (≤$KEEP бэкапов)"
fi

# ===================================================================
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
if [ "$DRY" = 1 ]; then
    echo -e "${BOLD}║              DRY-RUN — изменений не было                     ║${NC}"
elif [ "$ROLLBACK_DONE" = 1 ]; then
    echo -e "${BOLD}║           ⚠️  Обновление откатилось автоматически             ║${NC}"
else
    echo -e "${BOLD}║              ✅ Обновление завершено успешно                  ║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

echo "📦 Бэкап:  $BACKUP_DIR"
echo "📜 Лог:    $LOG_FILE"
echo "🔄 Откат:  sudo $0 --rollback"
echo
echo "Полезно:"
echo "  systemctl status 3x-ui-bot 3x-ui-bot-alerts"
echo "  tail -f $BOT_DIR/logs/bot.log"
[ "$NO_RESTART" = 1 ] && echo "  Не забудьте: systemctl restart 3x-ui-bot 3x-ui-bot-alerts"

[ "$ROLLBACK_DONE" = 1 ] && exit 2
exit 0
