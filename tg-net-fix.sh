#!/usr/bin/env bash
# tg-net-fix.sh — диагностика и фикс сетевых проблем 3x-ui ↔ Telegram Bot API
# Версия: 1.2
# Совместимость: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
#
# Поддерживает оба backend'а netfilter:
#   • nftables (предпочтительно)
#   • iptables / ip6tables (если nft недоступен)
#
# Опции:
#   --dry-run        только диагностика (по умолчанию)
#   --apply          разрешить применение (спросит подтверждение)
#   --yes | -y       не спрашивать подтверждение (для автоматизации)
#   --force          применить всё, даже если диагностика «ок»
#   --firewall X     auto (default) | nft | iptables
#   --backup-dir D   куда складывать бэкапы (default: /var/backups/tg-net-fix)
#   --mss-v4 N       вручную задать MSS для IPv4 (default: автоподбор)
#   --mss-v6 N       вручную задать MSS для IPv6 (default: автоподбор)
#   --service NAME   сервис для рестарта/проверки логов (default: x-ui)
#   --no-restart     не перезапускать сервис после применения
#   -h | --help      справка
#
# Коды возврата:
#   0  — всё ок (нет проблем / фиксы применены и проверены)
#   1  — проблемы найдены, изменения не сделаны (dry-run / отказ)
#   2  — ошибка окружения (не root, нет зависимости и т.п.)
#   3  — фиксы применены, но верификация не прошла
#
set -uo pipefail
set -E

VERSION="1.2"

# ─── параметры ───────────────────────────────────────────────────────
DRY_RUN=1
FORCE=0
ASSUME_YES=0
FIREWALL="auto"
BACKUP_DIR="/var/backups/tg-net-fix"
MSS_V4=""
MSS_V6=""
SERVICE="x-ui"
DO_RESTART=1

# ─── Telegram подсети (AS62041) ──────────────────────────────────────
TG_V4_NETS=(
    "91.108.4.0/22"
    "91.108.8.0/22"
    "91.108.12.0/22"
    "91.108.16.0/22"
    "91.108.20.0/22"
    "91.108.56.0/22"
    "95.161.64.0/20"
    "149.154.160.0/20"
)
TG_V6_NETS=(
    "2001:67c:4e8::/48"
    "2001:b28:f23c::/46"
)
TG_TEST_IPS=("149.154.167.220" "149.154.175.50" "149.154.166.110")
REF_IPS=("1.1.1.1" "8.8.8.8")
TG_DOMAIN="api.telegram.org"

# ─── цвета ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
    BLU=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; GRN=""; YLW=""; BLU=""; BOLD=""; DIM=""; NC=""
fi

log()  { printf '%s[%s]%s %s\n' "$DIM" "$(date +'%F %T')" "$NC" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YLW" "$NC" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$NC" "$*"; }
hdr()  { printf '\n%s── %s ──%s\n' "$BOLD" "$*" "$NC"; }
die()  { err "$*"; exit 2; }

usage() { sed -n '2,36p' "$0"; exit 0; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Запустите от root"; }
need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Не установлено: $c"
    done
}

TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        [ -n "$f" ] && [ -e "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

# ─── аргументы ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --apply)       DRY_RUN=0; shift ;;
        --yes|-y)      ASSUME_YES=1; DRY_RUN=0; shift ;;
        --force)       FORCE=1; DRY_RUN=0; shift ;;
        --firewall)    FIREWALL="$2"; shift 2 ;;
        --backup-dir)  BACKUP_DIR="$2"; shift 2 ;;
        --mss-v4)      MSS_V4="$2"; shift 2 ;;
        --mss-v6)      MSS_V6="$2"; shift 2 ;;
        --service)     SERVICE="$2"; shift 2 ;;
        --no-restart)  DO_RESTART=0; shift ;;
        -h|--help)     usage ;;
        *)             die "Неизвестная опция: $1" ;;
    esac
done

case "$FIREWALL" in auto|nft|iptables) ;; *) die "--firewall: auto|nft|iptables" ;; esac

need_root
need_cmd ping curl awk grep getent timeout tr sed sysctl ip systemctl tar mktemp

# ─── детектор backend'а ──────────────────────────────────────────────
detect_firewall() {
    if [ "$FIREWALL" = "nft" ]; then
        command -v nft >/dev/null 2>&1 || die "Запрошен --firewall nft, но nft не установлен"
        nft list tables >/dev/null 2>&1 || die "nft недоступен (kernel module?)"
        echo "nft"; return
    fi
    if [ "$FIREWALL" = "iptables" ]; then
        command -v iptables >/dev/null 2>&1 || die "Запрошен --firewall iptables, но iptables не установлен"
        echo "iptables"; return
    fi
    # auto
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        echo "nft"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

FW_BACKEND=$(detect_firewall)
[ "$FW_BACKEND" = "none" ] && die "Не найден ни nft, ни iptables — нечем применить MSS clamp"

# ─── состояние ──────────────────────────────────────────────────────
FOUND_ISSUES=()
NEED_MSS_CLAMP=0
NEED_PROBING=0
NEED_CONNTRACK_BUMP=0
PMTU_TG=1500
PMTU_REF=1500
TS=$(date +'%Y%m%d-%H%M%S')
HOST=$(hostname)

# ─── шапка ──────────────────────────────────────────────────────────
printf '%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$BOLD" "$NC"
printf '%s║  tg-net-fix v%-4s — диагностика и фикс маршрута до Telegram Bot API ║%s\n' "$BOLD" "$VERSION" "$NC"
printf '%s╠══════════════════════════════════════════════════════════════════════╣%s\n' "$BOLD" "$NC"
printf '%s║%s  Хост:     %-58s %s║%s\n' "$BOLD" "$NC" "$HOST" "$BOLD" "$NC"
printf '%s║%s  Backend:  %-58s %s║%s\n' "$BOLD" "$NC" "$FW_BACKEND" "$BOLD" "$NC"
printf '%s║%s  Режим:    %-58s %s║%s\n' "$BOLD" "$NC" \
    "$([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN' || echo 'APPLY (с подтверждением)')" "$BOLD" "$NC"
printf '%s║%s  Бэкап:    %-58s %s║%s\n' "$BOLD" "$NC" "$BACKUP_DIR" "$BOLD" "$NC"
printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$BOLD" "$NC"

mkdir -p "$BACKUP_DIR"

# ─── бэкап ──────────────────────────────────────────────────────────
backup_state() {
    local tag="$1"
    local dir="$BACKUP_DIR/${TS}-${tag}"
    mkdir -p "$dir"
    log "Бэкап состояния → $dir"

    command -v nft >/dev/null 2>&1 && \
        nft list ruleset > "$dir/nftables.ruleset" 2>/dev/null || true
    command -v iptables-save  >/dev/null 2>&1 && \
        iptables-save  > "$dir/iptables.rules"  2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && \
        ip6tables-save > "$dir/ip6tables.rules" 2>/dev/null || true

    sysctl -a 2>/dev/null \
        | grep -E '^(net\.ipv4|net\.ipv6|net\.netfilter|net\.core)\.' \
        > "$dir/sysctl.net.conf" || true

    cp -a /etc/sysctl.conf   "$dir/" 2>/dev/null || true
    cp -a /etc/sysctl.d      "$dir/" 2>/dev/null || true
    [ -f /etc/nftables.conf ] && cp -a /etc/nftables.conf "$dir/" 2>/dev/null || true
    [ -d /etc/nftables.d    ] && cp -a /etc/nftables.d    "$dir/" 2>/dev/null || true
    [ -d /etc/iptables      ] && cp -a /etc/iptables      "$dir/" 2>/dev/null || true
    [ -d /etc/netplan       ] && cp -a /etc/netplan       "$dir/" 2>/dev/null || true
    cp -a /etc/hosts         "$dir/" 2>/dev/null || true
    cp -a /etc/resolv.conf   "$dir/" 2>/dev/null || true
    [ -f /etc/systemd/system/tg-mss.service ] && \
        cp -a /etc/systemd/system/tg-mss.service "$dir/" 2>/dev/null || true
    [ -f /usr/local/sbin/tg-mss-apply ] && \
        cp -a /usr/local/sbin/tg-mss-apply "$dir/" 2>/dev/null || true

    ip -4 route show > "$dir/route.v4" 2>/dev/null || true
    ip -6 route show > "$dir/route.v6" 2>/dev/null || true
    ip addr show     > "$dir/ip.addr"  2>/dev/null || true
    ip link show     > "$dir/ip.link"  2>/dev/null || true
    {
        echo "nf_conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"
        echo "nf_conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max     2>/dev/null || echo N/A)"
    } > "$dir/conntrack.state"

    systemctl cat "$SERVICE" >"$dir/${SERVICE}.unit" 2>/dev/null || true

    if tar -C "$BACKUP_DIR" -czf "${dir}.tar.gz" "$(basename "$dir")" 2>/dev/null; then
        rm -rf "$dir"
        ok "Бэкап создан: ${dir}.tar.gz"
    else
        warn "Не упаковалось в tar.gz, оставляю каталог: $dir"
    fi
}

# ════════════════════════════════════════════════════════════════════
#                              ДИАГНОСТИКА
# ════════════════════════════════════════════════════════════════════
backup_state "pre"

# 1. DNS
hdr "1. DNS-резолвинг $TG_DOMAIN"
DNS_IPS=$(getent ahosts "$TG_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -10)
if [ -z "$DNS_IPS" ]; then
    err "DNS не резолвит $TG_DOMAIN"
    FOUND_ISSUES+=("DNS не работает")
else
    ok "DNS отвечает: $(echo "$DNS_IPS" | paste -sd, -)"
fi

# 2. TCP
hdr "2. TCP-доступность Telegram (порт 443)"
TG_TCP_OK=0; TG_TCP_TOTAL=${#TG_TEST_IPS[@]}
for ip in "${TG_TEST_IPS[@]}"; do
    if timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null; then
        ok "$ip: TCP OK"
        TG_TCP_OK=$((TG_TCP_OK+1))
    else
        err "$ip: TCP FAIL"
    fi
done
if [ "$TG_TCP_OK" -eq 0 ]; then
    FOUND_ISSUES+=("Полная блокировка TCP до Telegram")
elif [ "$TG_TCP_OK" -lt "$TG_TCP_TOTAL" ]; then
    FOUND_ISSUES+=("Частичная недоступность TCP ($TG_TCP_OK/$TG_TCP_TOTAL)")
fi

# 3. HTTPS
hdr "3. HTTPS до $TG_DOMAIN"
HTTP_CODE=$(curl -sk -o /dev/null --max-time 10 \
    -w '%{http_code}' "https://$TG_DOMAIN/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "200" ]; then
    ok "HTTPS: $HTTP_CODE (норма)"
else
    err "HTTPS: $HTTP_CODE (ожидался 302)"
    FOUND_ISSUES+=("HTTPS возвращает $HTTP_CODE")
fi

# 4. PMTU
hdr "4. Path MTU"
probe_pmtu() {
    local ip="$1" s
    for s in 1472 1452 1400 1372 1300 1252 1220 1200 1100 1000; do
        if ping -M do -s "$s" -c 1 -W 2 "$ip" >/dev/null 2>&1; then
            echo "$((s+28))"; return 0
        fi
    done
    echo "0"
}

PMTU_REF=$(probe_pmtu "${REF_IPS[0]}")
if [ "$PMTU_REF" = "0" ]; then
    warn "${REF_IPS[0]} не отвечает на ICMP — reference пропускаем"
    PMTU_REF=1500
else
    ok "Reference (${REF_IPS[0]}): PMTU = $PMTU_REF"
fi

TG_PMTU_MIN=9999
for ip in "${TG_TEST_IPS[@]}"; do
    p=$(probe_pmtu "$ip")
    if [ "$p" = "0" ]; then
        warn "$ip: не отвечает на ICMP"
        continue
    fi
    printf '  %s•%s %-18s PMTU = %s\n' "$BLU" "$NC" "$ip" "$p"
    [ "$p" -lt "$TG_PMTU_MIN" ] && TG_PMTU_MIN="$p"
done
[ "$TG_PMTU_MIN" = "9999" ] && PMTU_TG=1500 || PMTU_TG="$TG_PMTU_MIN"

if [ "$PMTU_TG" -lt 1500 ] && [ "$PMTU_REF" -ge 1500 ]; then
    err "PMTU до Telegram = $PMTU_TG (до reference = $PMTU_REF) — нужна MSS-clamping"
    FOUND_ISSUES+=("Низкий PMTU до Telegram ($PMTU_TG)")
    NEED_MSS_CLAMP=1
elif [ "$PMTU_TG" -lt 1500 ] && [ "$PMTU_REF" -lt 1500 ]; then
    warn "PMTU маленький везде ($PMTU_TG) — возможно, MTU интерфейса нестандартный"
else
    ok "PMTU до Telegram нормальный ($PMTU_TG)"
fi

if [ -z "$MSS_V4" ]; then
    if [ "$NEED_MSS_CLAMP" = 1 ]; then
        MSS_V4=$((PMTU_TG - 40))
        [ "$MSS_V4" -lt 536 ] && MSS_V4=1240
    else
        MSS_V4=1240
    fi
fi
if [ -z "$MSS_V6" ]; then
    MSS_V6=$((MSS_V4 - 20))
    [ "$MSS_V6" -lt 536 ] && MSS_V6=1220
fi

# 5. tcp_mtu_probing
hdr "5. TCP MTU probing"
CUR_PROBING=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "0")
if [ "$CUR_PROBING" = "0" ] && [ "$NEED_MSS_CLAMP" = 1 ]; then
    warn "tcp_mtu_probing=0 (рекомендуется 1)"
    NEED_PROBING=1
else
    ok "tcp_mtu_probing=$CUR_PROBING"
fi

# 6. conntrack
hdr "6. Conntrack"
if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    CT_CNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
    CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    if [ "$CT_MAX" -gt 0 ]; then
        CT_PCT=$(( CT_CNT * 100 / CT_MAX ))
        printf '  %s•%s count=%s / max=%s (%d%%)\n' "$BLU" "$NC" "$CT_CNT" "$CT_MAX" "$CT_PCT"
        if [ "$CT_PCT" -gt 70 ]; then
            warn "conntrack заполнен на ${CT_PCT}%"
            FOUND_ISSUES+=("conntrack заполнен на ${CT_PCT}%")
            NEED_CONNTRACK_BUMP=1
        else
            ok "conntrack в норме (${CT_PCT}%)"
        fi
    fi
else
    log "conntrack модуль не загружен — пропускаем"
fi

# 7. TCP retransmits
hdr "7. TCP-статистика"
if command -v nstat >/dev/null 2>&1; then
    RETRANS=$(nstat -az 2>/dev/null | awk '/^TcpRetransSegs/{print $2}')
    SEGS=$(nstat -az 2>/dev/null | awk '/^TcpOutSegs/{print $2}')
    if [ -n "${RETRANS:-}" ] && [ -n "${SEGS:-}" ] \
       && [[ "$SEGS" =~ ^[0-9]+$ ]] && [ "$SEGS" -gt 0 ]; then
        PCT=$(awk -v r="$RETRANS" -v s="$SEGS" 'BEGIN{printf "%.2f", r*100/s}')
        printf '  %s•%s Retransmits: %s / %s (%s%%)\n' "$BLU" "$NC" "$RETRANS" "$SEGS" "$PCT"
        if awk -v p="$PCT" 'BEGIN{exit !(p+0>1.0)}'; then
            warn "Высокий процент ретрансмитов — косвенный признак проблем MTU"
        fi
    fi
else
    log "nstat не установлен — пропускаем"
fi

# 8. логи сервиса
hdr "8. Журнал $SERVICE (Telegram-ошибки за 7 дней)"
if systemctl list-units --all "$SERVICE.service" --no-legend 2>/dev/null | grep -q "$SERVICE"; then
    TG_ERR=$(journalctl -u "$SERVICE" --since "7 days ago" 2>/dev/null \
        | grep -c 'Error sending telegram' 2>/dev/null || true)
    TG_ERR=${TG_ERR:-0}
    if [ "$TG_ERR" -gt 0 ]; then
        err "Найдено $TG_ERR ошибок отправки в Telegram"
        journalctl -u "$SERVICE" --since "7 days ago" 2>/dev/null \
            | grep 'Error sending telegram' | tail -3 | sed 's/^/    /'
        FOUND_ISSUES+=("$TG_ERR Telegram-ошибок в $SERVICE")
    else
        ok "Ошибок Telegram в логах нет"
    fi
else
    log "Сервис $SERVICE не найден — пропускаем"
fi

# 9. UFW
hdr "9. Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "UFW активен"
else
    log "UFW неактивен или не установлен"
fi
log "Backend для применения MSS: $FW_BACKEND"

# ════════════════════════════════════════════════════════════════════
#                              ИТОГ
# ════════════════════════════════════════════════════════════════════
hdr "ИТОГ ДИАГНОСТИКИ"
if [ "${#FOUND_ISSUES[@]}" -eq 0 ] && [ "$FORCE" = 0 ]; then
    ok "Проблем не обнаружено."
    log "Бэкап оставлен: $BACKUP_DIR/${TS}-pre.tar.gz"
    exit 0
fi

if [ "${#FOUND_ISSUES[@]}" -gt 0 ]; then
    err "Найдены проблемы:"
    for it in "${FOUND_ISSUES[@]}"; do
        printf '    %s•%s %s\n' "$RED" "$NC" "$it"
    done
fi

printf '\n%sПлан действий (%s):%s\n' "$BOLD" "$FW_BACKEND" "$NC"
if [ "$NEED_MSS_CLAMP" = 1 ] || [ "$FORCE" = 1 ]; then
    if [ "$FW_BACKEND" = "nft" ]; then
        printf '  • MSS-clamping в nftables (/etc/nftables.d/tg-mss.nft), MSS v4=%s v6=%s\n' "$MSS_V4" "$MSS_V6"
    else
        printf '  • MSS-clamping в iptables (systemd-unit tg-mss.service), MSS v4=%s v6=%s\n' "$MSS_V4" "$MSS_V6"
    fi
fi
if [ "$NEED_PROBING" = 1 ] || [ "$FORCE" = 1 ]; then
    printf '  • net.ipv4.tcp_mtu_probing = 1 в /etc/sysctl.d/99-tg-net-fix.conf\n'
fi
if [ "$NEED_CONNTRACK_BUMP" = 1 ]; then
    printf '  • net.netfilter.nf_conntrack_max = 262144 в /etc/sysctl.d/99-tg-net-fix.conf\n'
fi
if [ "$DO_RESTART" = 1 ]; then
    printf '  • перезапуск сервиса %s\n' "$SERVICE"
fi
printf '  • повторный бэкап после применения\n'

# DRY-RUN
if [ "$DRY_RUN" = 1 ]; then
    echo
    printf '%sDRY-RUN%s: ничего не меняем. Для применения: %s--apply%s\n' \
        "$YLW" "$NC" "$BOLD" "$NC"
    exit 1
fi

# ─── ПОДТВЕРЖДЕНИЕ ─────────────────────────────────────────────────
echo
if [ "$ASSUME_YES" = 1 ]; then
    log "Флаг --yes: применяю без подтверждения"
else
    if [ ! -t 0 ]; then
        err "Скрипт запущен без терминала, а подтверждение требуется."
        err "Запустите интерактивно или добавьте --yes"
        exit 1
    fi
    ANSWER=""
    printf '%sПрименить перечисленные фиксы? [y/N]: %s' "$BOLD" "$NC"
    read -r ANSWER || true
    case "${ANSWER,,}" in
        y|yes|да|д)
            log "Подтверждено пользователем"
            ;;
        *)
            warn "Отменено пользователем. Никаких изменений не сделано."
            log "Бэкап pre-fix оставлен: $BACKUP_DIR/${TS}-pre.tar.gz"
            exit 1
            ;;
    esac
fi

# ════════════════════════════════════════════════════════════════════
#                              ПРИМЕНЕНИЕ
# ════════════════════════════════════════════════════════════════════
hdr "ПРИМЕНЕНИЕ ФИКСОВ"
APPLY_ERRORS=0

# ─── A. MSS clamp ──────────────────────────────────────────────────
apply_mss_nft() {
    log "Создаём /etc/nftables.d/tg-mss.nft"
    mkdir -p /etc/nftables.d

    {
        echo "# Сгенерировано tg-net-fix.sh v$VERSION  $(date -Iseconds)"
        echo "# MSS clamp для подсетей Telegram (PMTU=$PMTU_TG)"
        echo "table inet tg-mss {"
        echo "    set tg_v4 {"
        echo "        type ipv4_addr; flags interval;"
        echo "        elements = {"
        for n in "${TG_V4_NETS[@]}"; do echo "            $n,"; done | sed '$ s/,$//'
        echo "        }"
        echo "    }"
        echo "    set tg_v6 {"
        echo "        type ipv6_addr; flags interval;"
        echo "        elements = {"
        for n in "${TG_V6_NETS[@]}"; do echo "            $n,"; done | sed '$ s/,$//'
        echo "        }"
        echo "    }"
        echo
        echo "    chain out {"
        echo "        type filter hook output priority -150; policy accept;"
        echo "        ip  daddr @tg_v4 tcp flags syn tcp option maxseg size set $MSS_V4 counter"
        echo "        ip6 daddr @tg_v6 tcp flags syn tcp option maxseg size set $MSS_V6 counter"
        echo "    }"
        echo "}"
    } > /etc/nftables.d/tg-mss.nft

    if [ -f /etc/nftables.conf ]; then
        if ! grep -q 'tg-mss.nft' /etc/nftables.conf; then
            echo 'include "/etc/nftables.d/tg-mss.nft"' >> /etc/nftables.conf
            ok "Добавлен include в /etc/nftables.conf"
        else
            ok "include уже есть в /etc/nftables.conf"
        fi
    else
        cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/tg-mss.nft"
EOF
        chmod +x /etc/nftables.conf
        ok "Создан /etc/nftables.conf"
    fi

    local nfterr; nfterr=$(mktemp); TMPFILES+=("$nfterr")
    if nft -f /etc/nftables.d/tg-mss.nft 2>"$nfterr"; then
        ok "Таблица inet tg-mss загружена"
    else
        err "Ошибка nft:"
        sed 's/^/    /' "$nfterr"
        return 1
    fi

    systemctl enable nftables >/dev/null 2>&1 && ok "nftables.service enabled" || true
    return 0
}

apply_mss_iptables() {
    local helper=/usr/local/sbin/tg-mss-apply
    local unit=/etc/systemd/system/tg-mss.service

    log "Создаём $helper и systemd-unit tg-mss.service"

    # helper-скрипт: разворачиваем все подсети как литералы (без массивов)
    {
        echo '#!/usr/bin/env bash'
        echo "# Auto-generated by tg-net-fix.sh v$VERSION  $(date -Iseconds)"
        echo "# MSS clamp для Telegram (PMTU=$PMTU_TG, MSS v4=$MSS_V4, v6=$MSS_V6)"
        echo 'set -u'
        echo ''
        echo 'flush() {'
        for n in "${TG_V4_NETS[@]}"; do
            echo "    while iptables -t mangle -D POSTROUTING -d $n -p tcp --tcp-flags SYN,RST SYN -m comment --comment tg-mss -j TCPMSS --set-mss $MSS_V4 2>/dev/null; do :; done"
        done
        for n in "${TG_V6_NETS[@]}"; do
            echo "    while ip6tables -t mangle -D POSTROUTING -d $n -p tcp --tcp-flags SYN,RST SYN -m comment --comment tg-mss -j TCPMSS --set-mss $MSS_V6 2>/dev/null; do :; done"
        done
        echo '}'
        echo ''
        echo 'apply() {'
        for n in "${TG_V4_NETS[@]}"; do
            echo "    iptables -t mangle -A POSTROUTING -d $n -p tcp --tcp-flags SYN,RST SYN -m comment --comment tg-mss -j TCPMSS --set-mss $MSS_V4"
        done
        for n in "${TG_V6_NETS[@]}"; do
            echo "    ip6tables -t mangle -A POSTROUTING -d $n -p tcp --tcp-flags SYN,RST SYN -m comment --comment tg-mss -j TCPMSS --set-mss $MSS_V6 2>/dev/null || true"
        done
        echo '}'
        echo ''
        echo 'case "${1:-start}" in'
        echo '    start) flush; apply ;;'
        echo '    stop)  flush ;;'
        echo '    *) echo "usage: $0 start|stop" >&2; exit 1 ;;'
        echo 'esac'
    } > "$helper"
    chmod +x "$helper"

    cat > "$unit" <<EOF
[Unit]
Description=MSS clamping for Telegram subnets (tg-net-fix)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$helper start
ExecStop=$helper stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if systemctl enable --now tg-mss.service >/dev/null 2>&1; then
        ok "tg-mss.service enabled и запущен"
    else
        err "Не удалось запустить tg-mss.service"
        return 1
    fi

    # быстрая проверка, что правило встало
    if iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q 'tg-mss'; then
        ok "Правила iptables установлены"
    else
        err "Правила iptables не обнаружены после запуска"
        return 1
    fi
    return 0
}

if [ "$NEED_MSS_CLAMP" = 1 ] || [ "$FORCE" = 1 ]; then
    case "$FW_BACKEND" in
        nft)      apply_mss_nft      || APPLY_ERRORS=$((APPLY_ERRORS+1)) ;;
        iptables) apply_mss_iptables || APPLY_ERRORS=$((APPLY_ERRORS+1)) ;;
    esac
fi

# ─── B. sysctl ─────────────────────────────────────────────────────
SYSCTL_FILE=/etc/sysctl.d/99-tg-net-fix.conf
if [ "$NEED_PROBING" = 1 ] || [ "$NEED_CONNTRACK_BUMP" = 1 ] || [ "$FORCE" = 1 ]; then
    log "Пишем $SYSCTL_FILE"
    {
        echo "# tg-net-fix.sh v$VERSION  $(date -Iseconds)"
        if [ "$NEED_PROBING" = 1 ] || [ "$FORCE" = 1 ]; then
            echo "net.ipv4.tcp_mtu_probing = 1"
            echo "net.ipv4.tcp_base_mss = 1024"
        fi
        if [ "$NEED_CONNTRACK_BUMP" = 1 ]; then
            echo "net.netfilter.nf_conntrack_max = 262144"
        fi
    } > "$SYSCTL_FILE"
    if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        ok "sysctl применён"
    else
        warn "sysctl применён с предупреждениями"
    fi
fi

# ─── C. рестарт ────────────────────────────────────────────────────
if [ "$DO_RESTART" = 1 ] && systemctl list-units --all "$SERVICE.service" --no-legend 2>/dev/null | grep -q "$SERVICE"; then
    log "Перезапуск $SERVICE..."
    if systemctl restart "$SERVICE"; then
        ok "$SERVICE перезапущен"
    else
        err "Не удалось перезапустить $SERVICE"
        APPLY_ERRORS=$((APPLY_ERRORS+1))
    fi
fi

# ════════════════════════════════════════════════════════════════════
#                              ВЕРИФИКАЦИЯ
# ════════════════════════════════════════════════════════════════════
hdr "ВЕРИФИКАЦИЯ"
VERIFY_OK=1

# 1. SYN с правильным MSS
if [ "$NEED_MSS_CLAMP" = 1 ] || [ "$FORCE" = 1 ]; then
    if command -v tcpdump >/dev/null 2>&1; then
        log "Проверяем фактический MSS в SYN-пакетах..."
        TCPFILE=$(mktemp); TMPFILES+=("$TCPFILE")
        timeout 8 tcpdump -i any -nn -c 4 \
            "tcp[tcpflags] & tcp-syn != 0 and host ${TG_TEST_IPS[0]}" \
            > "$TCPFILE" 2>/dev/null &
        TCPDPID=$!
        sleep 1
        curl -sk --max-time 6 -o /dev/null "https://$TG_DOMAIN/" 2>/dev/null || true
        wait "$TCPDPID" 2>/dev/null || true
        if grep -q "mss $MSS_V4" "$TCPFILE"; then
            ok "В SYN установлен mss=$MSS_V4"
        else
            warn "Не удалось подтвердить MSS через tcpdump (проверьте вручную)"
        fi
    else
        log "tcpdump не установлен — проверка MSS пропущена"
    fi

    # счётчик в правиле
    sleep 1
    if [ "$FW_BACKEND" = "nft" ]; then
        CNT=$(nft list table inet tg-mss 2>/dev/null \
            | awk -v m="$MSS_V4" '
                $0 ~ ("maxseg size set " m) {
                    for(i=1;i<=NF;i++) if($i=="packets"){print $(i+1); exit}
                }')
        CNT=${CNT:-0}
        if [ "$CNT" -gt 0 ]; then
            ok "nft counter = $CNT"
        else
            warn "nft counter не растёт"
        fi
    else
        CNT=$(iptables -t mangle -L POSTROUTING -n -v 2>/dev/null \
            | awk '/tg-mss/ {pkts+=$1} END{print pkts+0}')
        if [ "${CNT:-0}" -gt 0 ]; then
            ok "iptables counter = $CNT пакетов"
        else
            warn "iptables counter не растёт"
        fi
    fi
fi

# 2. HTTPS-стабильность
log "Проверяем стабильность HTTPS (5 запросов)..."
PASS=0
for i in 1 2 3 4 5; do
    CODE=$(curl -sk -o /dev/null --max-time 8 \
        -w '%{http_code}' "https://$TG_DOMAIN/" 2>/dev/null || echo "000")
    [ "$CODE" = "302" ] && PASS=$((PASS+1))
done
if [ "$PASS" -eq 5 ]; then
    ok "HTTPS: 5/5 успешных"
elif [ "$PASS" -ge 3 ]; then
    warn "HTTPS: $PASS/5 успешных"
else
    err "HTTPS: $PASS/5 успешных"
    VERIFY_OK=0
fi

# 3. логи сервиса
if systemctl list-units --all "$SERVICE.service" --no-legend 2>/dev/null | grep -q "$SERVICE"; then
    log "Ждём 30 секунд, проверяем свежие логи $SERVICE..."
    sleep 30
    NEW_ERR=$(journalctl -u "$SERVICE" --since "1 min ago" 2>/dev/null \
        | grep -c 'Error sending telegram' 2>/dev/null || true)
    NEW_ERR=${NEW_ERR:-0}
    if [ "$NEW_ERR" = "0" ]; then
        ok "Telegram-ошибок в свежих логах нет"
    else
        err "В свежих логах $SERVICE: $NEW_ERR ошибок"
        VERIFY_OK=0
    fi
fi

# post-бэкап
backup_state "post"

# ═══ ФИНАЛ ═══
echo
if [ "$APPLY_ERRORS" -eq 0 ] && [ "$VERIFY_OK" = 1 ]; then
    printf '%s%s✓ ВСЁ ОК — фиксы применены и работают (backend: %s)%s\n' "$GRN" "$BOLD" "$FW_BACKEND" "$NC"
    echo
    log "Бэкапы:"
    echo "  pre:  $BACKUP_DIR/${TS}-pre.tar.gz"
    echo "  post: $BACKUP_DIR/${TS}-post.tar.gz"
    echo
    log "Команда отката:"
    if [ "$FW_BACKEND" = "nft" ]; then
        cat <<EOF
  nft delete table inet tg-mss 2>/dev/null
  rm -f /etc/nftables.d/tg-mss.nft /etc/sysctl.d/99-tg-net-fix.conf
  sed -i '/tg-mss.nft/d' /etc/nftables.conf
  sysctl --system && systemctl restart $SERVICE
EOF
    else
        cat <<EOF
  systemctl disable --now tg-mss.service
  rm -f /etc/systemd/system/tg-mss.service /usr/local/sbin/tg-mss-apply
  rm -f /etc/sysctl.d/99-tg-net-fix.conf
  systemctl daemon-reload
  sysctl --system && systemctl restart $SERVICE
EOF
    fi
    exit 0
else
    printf '%s%s⚠ Применение завершилось с замечаниями%s\n' "$YLW" "$BOLD" "$NC"
    [ "$APPLY_ERRORS" -gt 0 ] && err "Ошибок применения: $APPLY_ERRORS"
    [ "$VERIFY_OK" = 0 ]      && err "Верификация не прошла"
    log "Пред-фикс бэкап: $BACKUP_DIR/${TS}-pre.tar.gz"
    exit 3
fi
