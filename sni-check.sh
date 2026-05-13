#!/usr/bin/env bash
# sni-check.sh — детальная проверка пригодности доменов для Reality (v1.2)
# Совместимость: Ubuntu 22.04 / 24.04
#
# Опции:
#   --domains "host:p ..." — свой список
#   --retries N            — попыток TLS-handshake (default 5)
#   --verbose              — подробный вывод
#   --json                 — JSON для интеграций
#   --quick                — 1 попытка (быстро)
#
set -uo pipefail

VERSION="1.2"

DEFAULT_POOL=(
    "www.kvnos.ru:443"
    "imap.yandex.ru:993"
    "www.sberbank.ru:443"
    "www.tinkoff.ru:443"
    "www.yandex.ru:443"
    "dzen.ru:443"
    "www.kinopoisk.ru:443"
    "www.ozon.ru:443"
    "www.wildberries.ru:443"
    "www.mts.ru:443"
    "www.kommersant.ru:443"
    "ya.ru:443"
    "music.yandex.ru:443"
    "www.alfabank.ru:443"
    "passport.yandex.ru:443"
    "rbc.ru:443"
)

RETRIES=5
VERBOSE=0
JSON_OUT=0
QUICK=0
CUSTOM_DOMAINS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --domains)  CUSTOM_DOMAINS="$2"; shift 2 ;;
        --retries)  RETRIES="$2"; shift 2 ;;
        --verbose)  VERBOSE=1; shift ;;
        --json)     JSON_OUT=1; shift ;;
        --quick)    QUICK=1; RETRIES=1; shift ;;
        --pool)     shift ;;
        -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
        *)  echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -n "$CUSTOM_DOMAINS" ]; then
    read -ra TARGETS <<< "$CUSTOM_DOMAINS"
else
    TARGETS=("${DEFAULT_POOL[@]}")
fi

for t in openssl curl awk grep getent timeout tr; do
    command -v "$t" >/dev/null || { echo "Не установлено: $t"; exit 1; }
done

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; BLU='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

ms_since() {
    local end; end=$(date +%s%N)
    echo $(( (end - $1) / 1000000 ))
}

tcp_check() {
    local h="$1" p="$2"
    local start; start=$(date +%s%N)
    if timeout 3 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null; then
        echo "OK $(ms_since "$start")"
    else
        echo "FAIL"
    fi
}

tcp_avg() {
    local h="$1" p="$2"
    local sum=0 ok=0 r ms
    for _ in 1 2 3; do
        r=$(tcp_check "$h" "$p")
        if [[ "$r" =~ ^OK ]]; then
            ms="${r#OK }"; sum=$((sum+ms)); ok=$((ok+1))
        fi
    done
    [ "$ok" -eq 0 ] && echo "FAIL" || echo "OK $((sum/ok))"
}

tls_handshake() {
    local h="$1" p="$2" sni="$3" ver="${4:-tls1_3}"
    echo Q | timeout 7 openssl s_client \
        -connect "${h}:${p}" -servername "$sni" \
        -"${ver}" -alpn "h2,http/1.1" 2>&1 </dev/null | tr -d '\0' || true
}

is_tls13() {
    local out="$1"
    echo "$out" | grep -qE \
        '(Protocol[[:space:]]*:[[:space:]]*TLSv1\.3|^New,[[:space:]]+TLSv1\.3|TLS_AES_(128|256)_GCM|TLS_CHACHA20_POLY1305)'
}

parse_tls() {
    local out="$1"
    PARSED_VER=""; PARSED_CIPHER=""; PARSED_KEX=""; PARSED_ALPN=""

    if echo "$out" | grep -qE 'TLSv1\.3'; then PARSED_VER="TLSv1.3"
    elif echo "$out" | grep -qE 'TLSv1\.2'; then PARSED_VER="TLSv1.2"
    else PARSED_VER="?"; fi

    PARSED_CIPHER=$(echo "$out" | awk '
        /^[[:space:]]*Cipher[[:space:]]*:/{
            sub(/^[^:]*:[[:space:]]*/,"")
            sub(/[[:space:]]*$/,"")
            print; exit
        }
        /^New,[[:space:]]+TLSv/{
            if (match($0,/Cipher is [A-Z0-9_-]+/)) {
                s=substr($0,RSTART+10,RLENGTH-10); print s; exit
            }
        }
    ')
    [ -z "$PARSED_CIPHER" ] && PARSED_CIPHER="?"

    PARSED_KEX=$(echo "$out" | awk '
        /Server Temp Key/{
            sub(/^[^:]*:[[:space:]]*/,"")
            sub(/[[:space:]]*,.*$/,"")
            sub(/[[:space:]]*$/,"")
            print; exit
        }')
    if [ -z "$PARSED_KEX" ]; then
        PARSED_KEX=$(echo "$out" | grep -oE 'X25519|P-256|P-384|P-521|secp[0-9]+r1' | head -1)
    fi
    [ -z "$PARSED_KEX" ] && PARSED_KEX="?"

    PARSED_ALPN=$(echo "$out" | awk '
        /ALPN protocol/{
            sub(/^[^:]*:[[:space:]]*/,"")
            sub(/[[:space:]]*$/,"")
            print; exit
        }')
    echo "$out" | grep -qi "No ALPN negotiated" && PARSED_ALPN="—"
    [ -z "$PARSED_ALPN" ] && PARSED_ALPN="—"
}

cert_info() {
    local h="$1" p="$2" sni="$3"
    local pem cn issuer enddate end now days san
    pem=$(echo Q | timeout 7 openssl s_client -connect "${h}:${p}" -servername "$sni" 2>/dev/null </dev/null \
        | tr -d '\0' \
        | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/')
    [ -z "$pem" ] && { echo "?|?|?|0"; return; }

    cn=$(echo "$pem" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | awk -F'CN=' 'NF>1{print $2}' | awk -F',' '{print $1}' | head -1)
    [ -z "$cn" ] && cn="?"

    issuer=$(echo "$pem" | openssl x509 -noout -issuer -nameopt RFC2253 2>/dev/null \
        | awk -F'CN=' 'NF>1{print $2}' | awk -F',' '{print $1}' | head -1)
    [ -z "$issuer" ] && issuer=$(echo "$pem" | openssl x509 -noout -issuer -nameopt RFC2253 2>/dev/null \
        | awk -F'O=' 'NF>1{print $2}' | awk -F',' '{print $1}' | head -1)
    [ -z "$issuer" ] && issuer="?"

    enddate=$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | awk -F'=' '{print $2}')
    if [ -n "$enddate" ]; then
        end=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        days=$([ "$end" -gt 0 ] && echo $(( (end - now) / 86400 )) || echo "?")
    else
        days="?"
    fi

    san=$(echo "$pem" | openssl x509 -noout -text 2>/dev/null \
        | grep -oE 'DNS:[^,[:space:]]+' | wc -l)
    [[ "$san" =~ ^[0-9]+$ ]] || san=0

    echo "${cn}|${issuer}|${days}|${san}"
}

http_check() {
    local h="$1" p="$2"
    local result
    result=$(curl -sk --max-time 10 --http2 -o /dev/null \
        -w "%{http_code}|%{http_version}|%header{server}" \
        "https://${h}:${p}/" 2>/dev/null || true)
    [ -z "$result" ] && result="—|—|—"
    echo "$result" | tr -d '\0\r'
}

ip_info() {
    local h="$1"
    local ips ip country
    ips=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u | head -3 | paste -sd, -)
    if [ -z "$ips" ] && command -v dig >/dev/null; then
        ips=$(timeout 5 dig +short "$h" 2>/dev/null | head -3 | paste -sd, -)
    fi
    [ -z "$ips" ] && ips="?"

    ip="${ips%%,*}"
    country="?"
    if [ "$ip" != "?" ]; then
        country=$(curl -s --max-time 4 "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\n[:space:]\0')
        if [ -z "$country" ] || [ "${#country}" -gt 4 ]; then country="?"; fi
    fi
    echo "${ips}|${country}"
}

RESULTS_JSON=()

check_target() {
    local target="$1"
    local h="${target%:*}"
    local p="${target##*:}"
    local sni="$h"

    [ "$VERBOSE" = 1 ] && echo -e "\n${BOLD}── $target ──${NC}"

    local ipres ips country
    ipres=$(ip_info "$h")
    ips="${ipres%|*}"; country="${ipres#*|}"
    [ "$VERBOSE" = 1 ] && echo "  IP/страна:   $ips ($country)"

    local tcp_r tcp_ok tcp_ms
    tcp_r=$(tcp_avg "$h" "$p")
    if [[ "$tcp_r" =~ ^OK ]]; then
        tcp_ok=1; tcp_ms="${tcp_r#OK }"
        [ "$VERBOSE" = 1 ] && echo "  TCP:         ✓ ${tcp_ms} ms (avg of 3)"
    else
        tcp_ok=0; tcp_ms=0
        [ "$VERBOSE" = 1 ] && echo "  TCP:         ✗ недоступен"
    fi

    if [ "$tcp_ok" = 0 ]; then
        RESULTS_JSON+=("$(printf '{"target":"%s","tcp":false,"score":0}' "$target")")
        echo "$target|✗|—|0|${RETRIES}|—|—|—|—|—|—|$country|0"
        return
    fi

    local tls13_ok=0 tls13_total=$RETRIES
    local sample_out=""
    local i
    for ((i=0; i<RETRIES; i++)); do
        local out; out=$(tls_handshake "$h" "$p" "$sni" "tls1_3")
        if is_tls13 "$out"; then
            tls13_ok=$((tls13_ok+1))
            [ -z "$sample_out" ] && sample_out="$out"
        fi
    done
    local tls13_pct=$((tls13_ok * 100 / tls13_total))
    [ "$VERBOSE" = 1 ] && echo "  TLS 1.3:     ${tls13_ok}/${tls13_total} (${tls13_pct}%)"

    if [ "$tls13_ok" = 0 ]; then
        local out12; out12=$(tls_handshake "$h" "$p" "$sni" "tls1_2")
        if echo "$out12" | grep -qE 'TLSv1\.2'; then
            sample_out="$out12"
            [ "$VERBOSE" = 1 ] && echo "               ⚠ работает только TLS 1.2"
        fi
    fi

    parse_tls "$sample_out"
    [ "$VERBOSE" = 1 ] && {
        echo "  Protocol:    ${PARSED_VER}"
        echo "  Cipher:      ${PARSED_CIPHER}"
        echo "  Key Group:   ${PARSED_KEX}"
        echo "  ALPN:        ${PARSED_ALPN}"
    }

    local certres cn issuer days san
    certres=$(cert_info "$h" "$p" "$sni")
    IFS='|' read -r cn issuer days san <<< "$certres"
    [ "$VERBOSE" = 1 ] && {
        echo "  Cert CN:     ${cn}"
        echo "  Issuer:      ${issuer}"
        echo "  Cert days:   ${days}, SAN: ${san}"
    }

    local http_r http_code http_ver http_server
    http_r=$(http_check "$h" "$p")
    IFS='|' read -r http_code http_ver http_server <<< "$http_r"
    [ -z "$http_code" ] && http_code="—"
    [ -z "$http_ver" ]  && http_ver="—"
    [ -z "$http_server" ] && http_server="—"
    [ "$VERBOSE" = 1 ] && echo "  HTTP:        ${http_code} (HTTP/${http_ver}), Server: ${http_server}"

    local score=0
    [ "$tls13_pct" -ge 80 ]              && score=$((score+3))
    [ "$tls13_pct" -ge 100 ]             && score=$((score+1))
    echo "${PARSED_KEX:-}" | grep -qi "X25519" && score=$((score+1))
    [ "${PARSED_ALPN:-}" = "h2" ]        && score=$((score+1))
    [ "$http_ver" = "2" ]                && score=$((score+1))
    [[ "$http_code" =~ ^(200|301|302|307|308|403)$ ]] && score=$((score+1))
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 30 ] && score=$((score+1))
    [[ "$san" =~ ^[0-9]+$ ]] && [ "$san" -ge 2 ]    && score=$((score+1))
    [ "$tcp_ms" -lt 50 ]                 && score=$((score+1))
    [ "$tls13_ok" -eq 0 ] && [ "$score" -gt 3 ] && score=3
    [ "$score" -gt 10 ] && score=10

    [ "$VERBOSE" = 1 ] && {
        local color="$RED"
        [ "$score" -ge 7 ] && color="$GRN"
        { [ "$score" -ge 4 ] && [ "$score" -lt 7 ]; } && color="$YLW"
        echo -e "  Score:       ${color}${BOLD}${score}/10${NC}"
    }

    echo "$target|✓|${tcp_ms}ms|${tls13_ok}|${tls13_total}|${PARSED_KEX}|${PARSED_ALPN}|${days}д|${http_code}|${http_ver}|${san}|${country}|${score}"

    RESULTS_JSON+=("$(printf '{"target":"%s","tcp_ms":%d,"tls13_success":%d,"tls13_attempts":%d,"kex":"%s","alpn":"%s","cert_days":"%s","http_code":"%s","http_version":"%s","san_count":"%s","country":"%s","cn":"%s","issuer":"%s","score":%d}' \
        "$target" "$tcp_ms" "$tls13_ok" "$tls13_total" \
        "${PARSED_KEX}" "${PARSED_ALPN}" \
        "${days}" "${http_code}" "${http_ver}" \
        "${san}" "${country}" "${cn}" "${issuer}" "$score")")
}

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  sni-check v${VERSION} — детальная проверка Reality dest                  ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  Доменов: %-3d  Попыток TLS: %-2d  Хост: %-28s ${BOLD}║${NC}\n" \
    "${#TARGETS[@]}" "$RETRIES" "$(hostname)"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"

ROWS=()
for t in "${TARGETS[@]}"; do
    ROWS+=("$(check_target "$t")")
done

if [ "$JSON_OUT" = 1 ]; then
    echo "{"
    echo "  \"version\": \"$VERSION\","
    echo "  \"host\": \"$(hostname)\","
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"retries\": $RETRIES,"
    echo "  \"results\": ["
    first=1
    for r in "${RESULTS_JSON[@]}"; do
        [ "$first" = 1 ] && first=0 || echo ","
        printf "    %s" "$r"
    done
    echo; echo "  ]"; echo "}"
    exit 0
fi

echo
printf "%-26s %-3s %-7s %-9s %-10s %-7s %-7s %-6s %-6s %-4s %-4s %s\n" \
    "TARGET" "TCP" "LATENC" "TLS1.3" "KEX" "ALPN" "CERT" "HTTP" "HTTPv" "SAN" "GEO" "SCORE"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

for row in "${ROWS[@]}"; do
    IFS='|' read -r target tcp ms tls_ok tls_total kex alpn certdays http httpver san country score <<< "$row"

    local_disp=""
    if [ "$tls_ok" = "$tls_total" ] && [ "$tls_total" != "0" ]; then
        local_disp="${GRN}${tls_ok}/${tls_total}${NC}"
    elif [ "$tls_ok" -gt 0 ] 2>/dev/null; then
        local_disp="${YLW}${tls_ok}/${tls_total}${NC}"
    else
        local_disp="${RED}0/${tls_total}${NC}"
    fi

    sc_col="$RED"
    [ "$score" -ge 7 ] && sc_col="$GRN"
    { [ "$score" -ge 4 ] && [ "$score" -lt 7 ]; } && sc_col="$YLW"

    kex_short="${kex:0:10}"
    alpn_short="${alpn:0:7}"

    printf "%-26s %-3b %-7s %b   %-10s %-7s %-7s %-6s %-6s %-4s %-4s ${sc_col}%s/10${NC}\n" \
        "$target" "$tcp" "$ms" "$local_disp" \
        "$kex_short" "$alpn_short" "$certdays" "$http" "$httpver" "$san" "$country" "$score"
done

echo
echo -e "${BOLD}── Рекомендации (сортировка по score) ──${NC}"

tmpf=$(mktemp)
trap 'rm -f "$tmpf"' EXIT
for row in "${ROWS[@]}"; do
    IFS='|' read -ra f <<< "$row"
    sc="${f[12]}"
    printf "%03d|%s\n" "$sc" "$row" >> "$tmpf"
done

i=0
while IFS='|' read -r _ target tcp ms tls_ok tls_total kex alpn certdays http httpver san country score; do
    i=$((i+1))
    [ "$i" -gt 15 ] && break
    color="$DIM"
    [ "$score" -ge 7 ] && color="$GRN"
    { [ "$score" -ge 4 ] && [ "$score" -lt 7 ]; } && color="$YLW"
    [ "$score" -lt 4 ] && color="$RED"
    printf "  ${color}%2d. %-26s — ${BOLD}%2s/10${NC} ${color}(TLS1.3: %s/%s, KEX: %-8s, ALPN: %-8s, geo: %s)${NC}\n" \
        "$i" "$target" "$score" "$tls_ok" "$tls_total" "${kex:0:10}" "${alpn:0:8}" "$country"
done < <(sort -rn -t'|' -k1 "$tmpf")

echo
echo -e "${BOLD}── Легенда ──${NC}"
printf "  ${GRN}7–10${NC}  отличный dest для Reality\n"
printf "  ${YLW}4–6${NC}   приемлемо (TLS1.2 fallback, нет h2 и т.п.)\n"
printf "  ${RED}0–3${NC}   не рекомендуется (нет TLS 1.3)\n"
echo
echo "  Идеальный профиль:"
echo "    • TLS 1.3 — 5/5 попыток"
echo "    • KEX     = X25519"
echo "    • ALPN    = h2"
echo "    • HTTPv   = 2"
echo "    • CERT    > 30 дней"
echo "    • SAN     ≥ 2"
echo "    • LATENC  < 50ms"

exit 0
