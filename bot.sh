#!/bin/bash
# /opt/3x-ui-bot/bot.sh — v2.2
# Совместимость: Ubuntu 22.04 / 24.04
# Субкоманды: run | alerts-loop | snapshot | summary | check
set -u

BOT_DIR="${BOT_DIR:-/opt/3x-ui-bot}"
[ -f "$BOT_DIR/bot.env" ] && . "$BOT_DIR/bot.env"

: "${BOT_TOKEN:=}"
: "${ADMIN_IDS:=}"
: "${XUI_SCHEME:=https}"
: "${XUI_HOST:=127.0.0.1}"
: "${XUI_PORT:=2053}"
: "${XUI_PATH:=/}"
: "${XUI_API_TOKEN:=}"
: "${INBOUND_FILTER:=regex:^(main-|fallback-)}"
: "${SERVER_DOMAIN:=}"
: "${NGINX_PREFIX:=subs}"
: "${NGINX_PORT:=8443}"
: "${XRAY_ACCESS_LOG:=/usr/local/x-ui/access.log}"
: "${XRAY_ERROR_LOG:=/usr/local/x-ui/error.log}"
: "${XUI_DB:=/etc/x-ui/x-ui.db}"
: "${CPU_THRESHOLD:=85}"
: "${RAM_THRESHOLD:=85}"
: "${DISK_THRESHOLD:=90}"
: "${CHECK_INTERVAL:=60}"
: "${SUMMARY_HOUR:=10}"

RUN_DIR="$BOT_DIR/data"
LOG_DIR="$BOT_DIR/logs"
BACKUP_DIR="$BOT_DIR/backups"
PENDING_DIR="$RUN_DIR/pending"
OFFSET_FILE="$RUN_DIR/offset"
ALERT_STATE="$RUN_DIR/alert_state.json"
TRAFFIC_CSV="$RUN_DIR/traffic.csv"
LOG_FILE="$LOG_DIR/bot.log"
ALERTS_LOG="$LOG_DIR/alerts.log"
mkdir -p "$RUN_DIR" "$LOG_DIR" "$BACKUP_DIR" "$PENDING_DIR"
[ -f "$TRAFFIC_CSV" ]  || echo "ts,total_bytes" > "$TRAFFIC_CSV"
[ -f "$ALERT_STATE" ]  || echo '{}' > "$ALERT_STATE"

API="${XUI_SCHEME}://${XUI_HOST}:${XUI_PORT}${XUI_PATH%/}"

log()        { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }
log_alerts() { echo "[$(date '+%F %T')] $*" >> "$ALERTS_LOG"; }
get_offset() { cat "$OFFSET_FILE" 2>/dev/null || echo 0; }
set_offset() { echo "$1" > "$OFFSET_FILE"; }

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

sys_cpu()    { get_cpu_pct; }
sys_ram()    { get_ram_pct; }
sys_disk()   { get_disk_pct; }
xui_active() { systemctl is-active --quiet x-ui; }

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b !~ /^[0-9]+$/) b=0
        u="B KB MB GB TB PB"; split(u,a," ");
        for(i=1;b>=1024 && i<6;i++) b/=1024;
        printf("%.2f %s", b, a[i])
    }'
}

tg_api() {
    local method="$1"; shift
    curl -s --max-time 20 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@"
}

send_msg() {
    local chat_id="$1" text="$2" reply_markup="${3:-}"
    local args=( -d "chat_id=${chat_id}" -d "parse_mode=HTML"
                 -d "disable_web_page_preview=true"
                 --data-urlencode "text=${text}" )
    [ -n "$reply_markup" ] && args+=( --data-urlencode "reply_markup=${reply_markup}" )
    tg_api sendMessage "${args[@]}" > /dev/null
}

send_link() { sleep 0.25; send_msg "$1" "$2"$'\n'"<code>$3</code>"; }

send_photo() {
    local chat_id="$1" file="$2" caption="${3:-}"
    curl -s --max-time 30 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=${chat_id}" -F "parse_mode=HTML" \
        -F "caption=${caption}" -F "photo=@${file}" > /dev/null
}

send_doc() {
    local chat_id="$1" file="$2" caption="${3:-}"
    curl -s --max-time 60 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F "chat_id=${chat_id}" -F "parse_mode=HTML" \
        -F "caption=${caption}" -F "document=@${file}" > /dev/null
}

answer_callback() {
    tg_api answerCallbackQuery -d "callback_query_id=$1" \
        --data-urlencode "text=${2:-}" > /dev/null
}

is_admin() {
    local uid="$1"
    for a in $ADMIN_IDS; do [ "$a" = "$uid" ] && return 0; done
    return 1
}

broadcast_admins() {
    local text="$1"
    for a in $ADMIN_IDS; do send_msg "$a" "$text"; done
}

xui_call() {
    local method="$1" path="$2" data="${3:-}"
    if [ -n "$data" ]; then
        curl -sk --max-time 20 -X "$method" "${API}${path}" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" -d "$data"
    else
        curl -sk --max-time 20 -X "$method" "${API}${path}" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" \
            -H "Accept: application/json"
    fi
}

xui_inbounds_list() { xui_call GET  "/panel/api/inbounds/list"; }
xui_onlines()       { xui_call POST "/panel/api/inbounds/onlines"; }
xui_client_traffic(){ xui_call GET  "/panel/api/inbounds/getClientTraffics/$1"; }

xui_target_inbounds() {
    local data; data=$(xui_inbounds_list)
    case "$INBOUND_FILTER" in
        all)    echo "$data" | jq -r '.obj[]? | select(.enable==true) | .id' | tr '\n' ' ' ;;
        vless)  echo "$data" | jq -r '.obj[]? | select(.enable==true and .protocol=="vless") | .id' | tr '\n' ' ' ;;
        list:*) echo "${INBOUND_FILTER#list:}" | tr ',' ' ' ;;
        regex:*) echo "$data" | jq -r --arg re "${INBOUND_FILTER#regex:}" \
                  '.obj[]? | select(.enable==true and (.remark|test($re))) | .id' | tr '\n' ' ' ;;
        *) echo "$INBOUND_FILTER" ;;
    esac
}

xui_add_client() {
    local name="$1" days="$2" gb="$3"
    local ids; ids=$(xui_target_inbounds)
    if [ -z "$(echo "$ids" | tr -d ' ')" ]; then
        echo '{"success":false,"msg":"no target inbounds"}'; return 1
    fi

    local uuid expiry_ms total_b
    uuid=$(cat /proc/sys/kernel/random/uuid)
    [ "$days" -gt 0 ] 2>/dev/null && expiry_ms=$(( ($(date +%s) + days*86400) * 1000 )) || expiry_ms=0
    [ "$gb"   -gt 0 ] 2>/dev/null && total_b=$(( gb * 1024 * 1024 * 1024 ))             || total_b=0

    local proto_map; proto_map=$(xui_inbounds_list | jq -c '[.obj[]? | {id, protocol, remark}]')

    local added=() failed=()
    local id proto remark flow email clients payload r

    for id in $ids; do
        proto=$(echo  "$proto_map" | jq -r --argjson i "$id" '.[] | select(.id==$i) | .protocol')
        remark=$(echo "$proto_map" | jq -r --argjson i "$id" '.[] | select(.id==$i) | .remark')
        [ -z "$proto" ] && { failed+=("$id:not-found"); continue; }
        [ "$proto" = "vless" ] && flow="xtls-rprx-vision" || flow=""
        email="${name}-${remark}"

        clients=$(jq -nc \
            --arg id "$uuid" --arg email "$email" --arg sub "$name" \
            --arg flow "$flow" \
            --argjson exp "$expiry_ms" --argjson tot "$total_b" '
            { clients: [{ id:$id, flow:$flow, email:$email,
                          limitIp:0, totalGB:$tot, expiryTime:$exp,
                          enable:true, tgId:"", subId:$sub, comment:"", reset:0 }]}')
        payload=$(jq -nc --argjson id "$id" --arg s "$clients" '{id:$id, settings:$s}')

        r=$(xui_call POST "/panel/api/inbounds/addClient" "$payload")
        if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then
            added+=("$email")
        else
            failed+=("${email}:$(echo "$r" | jq -r '.msg // "err"')")
        fi
    done

    jq -nc --arg uuid "$uuid" --arg sub "$name" \
        --argjson added  "$(printf '%s\n' "${added[@]:-}"  | jq -R . | jq -s .)" \
        --argjson failed "$(printf '%s\n' "${failed[@]:-}" | jq -R . | jq -s .)" '
        {success:($failed|map(select(.!=""))|length==0),
         uuid:$uuid, subId:$sub,
         added: ($added |map(select(.!=""))),
         failed:($failed|map(select(.!="")))}'
}

xui_del_client() {
    local name="$1"
    local pairs; pairs=$(xui_inbounds_list | jq -r --arg n "$name" '
        .obj[]? as $i | ($i.settings|fromjson).clients[]?
        | select(.subId == $n or .email == $n or (.email|startswith($n + "-")))
        | "\($i.id) \(.id) \(.email)"')
    [ -z "$pairs" ] && { echo '{"success":false,"msg":"not found"}'; return 1; }

    local deleted=() failed=() r
    while IFS=' ' read -r ib uuid email; do
        [ -z "$ib" ] && continue
        r=$(xui_call POST "/panel/api/inbounds/${ib}/delClient/${uuid}")
        if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then deleted+=("$email")
        else failed+=("$email"); fi
    done <<< "$pairs"

    jq -nc \
        --argjson deleted "$(printf '%s\n' "${deleted[@]:-}" | jq -R . | jq -s .)" \
        --argjson failed  "$(printf '%s\n' "${failed[@]:-}"  | jq -R . | jq -s .)" '
        {success:($failed|map(select(.!=""))|length==0),
         deleted:($deleted|map(select(.!=""))),
         failed: ($failed |map(select(.!="")))}'
}

db_get() { sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='$1';" 2>/dev/null; }

run_check() {
    local cpu ram disk xok state new_state
    cpu=$(get_cpu_pct); ram=$(get_ram_pct); disk=$(get_disk_pct)
    xui_active && xok=1 || xok=0
    state=$(cat "$ALERT_STATE")
    new_state="$state"

    fire() {
        local key="$1" bad="$2" msg="$3"
        local prev; prev=$(echo "$state" | jq -r --arg k "$key" '.[$k] // false')
        if [ "$bad" = "1" ] && [ "$prev" != "true" ]; then
            broadcast_admins "🚨 <b>ALERT</b>: $msg"
            log_alerts "FIRE $key: $msg"
            new_state=$(echo "$new_state" | jq --arg k "$key" '.[$k]=true')
        elif [ "$bad" = "0" ] && [ "$prev" = "true" ]; then
            broadcast_admins "✅ <b>RECOVERED</b>: $msg"
            log_alerts "RECOVER $key"
            new_state=$(echo "$new_state" | jq --arg k "$key" '.[$k]=false')
        fi
    }

    local cth=${CPU_THRESHOLD%.*};  cth=${cth:-85}
    local rth=${RAM_THRESHOLD%.*};  rth=${rth:-85}
    local dth=${DISK_THRESHOLD%.*}; dth=${dth:-90}

    if ge_int "$cpu" "$cth"; then fire cpu 1 "CPU ${cpu}% ≥ ${cth}%"; else fire cpu 0 "CPU ${cpu}%"; fi
    if ge_int "$ram" "$rth"; then fire ram 1 "RAM ${ram}% ≥ ${rth}%"; else fire ram 0 "RAM ${ram}%"; fi
    if ge_int "$disk" "$dth"; then fire disk 1 "Disk ${disk}% ≥ ${dth}%"; else fire disk 0 "Disk ${disk}%"; fi
    if [ "$xok" = "0" ]; then fire xui 1 "Сервис x-ui НЕ активен"; else fire xui 0 "x-ui активен"; fi

    local api_ok; api_ok=$(xui_inbounds_list | jq -r '.success // "false"' 2>/dev/null)
    if [ "$api_ok" = "true" ]; then fire api 0 "API OK"; else fire api 1 "3x-ui API недоступен"; fi

    echo "$new_state" > "$ALERT_STATE"
}

alerts_loop() {
    log_alerts "Alerts daemon started (interval=${CHECK_INTERVAL}s)"
    while true; do
        run_check 2>>"$ALERTS_LOG" || log_alerts "check error"
        sleep "$CHECK_INTERVAL"
    done
}

snapshot_traffic() {
    local total; total=$(xui_inbounds_list | jq '[.obj[]?.clientStats[]? | (.up+.down)] | add // 0')
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    echo "$(date +%s),$total" >> "$TRAFFIC_CSV"
    local cutoff=$(( $(date +%s) - 35*86400 ))
    awk -F, -v c="$cutoff" 'NR==1 || $1>=c' "$TRAFFIC_CSV" > "${TRAFFIC_CSV}.tmp" \
        && mv "${TRAFFIC_CSV}.tmp" "$TRAFFIC_CSV"
    log "snapshot total=$total"
}

build_chart() {
    local hours="$1" out="$2"
    local since=$(( $(date +%s) - hours*3600 ))
    local data="$RUN_DIR/chart.dat"
    awk -F, -v s="$since" 'NR>1 && $1>=s {print $1","$2}' "$TRAFFIC_CSV" > "$data"
    local rows; rows=$(wc -l < "$data"); [[ "$rows" =~ ^[0-9]+$ ]] || rows=0

    if [ "$rows" -lt 2 ]; then
        gnuplot <<EOF 2>/dev/null
set terminal pngcairo size 900,400
set output "$out"
set title "Недостаточно данных (нужно ≥ 2 снимка)"
unset key
plot [0:1][0:1] 2 with lines
EOF
        return
    fi

    local delta="$RUN_DIR/chart_delta.dat"
    awk -F, 'NR==1{pv=$2;next} {d=$2-pv; if(d<0)d=0; printf "%d %.4f\n",$1,d/1073741824; pv=$2}' "$data" > "$delta"

    gnuplot <<EOF 2>/dev/null
set terminal pngcairo size 1000,420 font "DejaVu Sans,10"
set output "$out"
set title "Трафик за последние $hours ч (ГБ за интервал)"
set xdata time
set timefmt "%s"
set format x "%d.%m\n%H:%M"
set ylabel "ГБ"
set grid
set style fill transparent solid 0.3 noborder
set key off
plot "$delta" using 1:2 with filledcurves x1 lc rgb "#3b82f6", \
     "$delta" using 1:2 with linespoints lw 2 pt 7 ps 0.6 lc rgb "#1d4ed8"
EOF
}

send_summary() {
    local out="$RUN_DIR/summary.png"
    build_chart 24 "$out"

    local top
    top=$(xui_inbounds_list | jq -r '
        [.obj[]?.clientStats[]?]
        | map(select(.email|test("^DUMMY-")|not))
        | group_by(.email | split("-")[0])
        | map({sub:(.[0].email|split("-")[0]),
               bytes:(map(.up+.down)|add)})
        | sort_by(-.bytes) | .[0:5]
        | .[] | "\(.sub)|\(.bytes)"' 2>/dev/null)

    local top_text=""
    if [ -n "$top" ]; then
        top_text=$(echo "$top" | awk -F'|' '{
            b=$2; u="B KB MB GB TB"; split(u,a," ");
            for(i=1;b>=1024 && i<5;i++) b/=1024;
            printf "%d. %-20s %.2f %s\n", NR, $1, b, a[i]
        }')
    fi

    local inb_cnt cli_cnt total
    inb_cnt=$(xui_inbounds_list | jq '.obj|length')
    cli_cnt=$(xui_inbounds_list | jq '[.obj[]? | (.settings|fromjson).clients[]?] | length')
    total=$(xui_inbounds_list  | jq '[.obj[]?.clientStats[]? | (.up+.down)] | add // 0')

    local since=$(( $(date +%s) - 86400 ))
    local d24
    d24=$(awk -F, -v s="$since" 'NR==1{next} { if(!f && $1>=s){f=$2}; l=$2 } END{ if(f) print l-f; else print 0 }' "$TRAFFIC_CSV")
    [[ "$d24" =~ ^[0-9]+$ ]] || d24=0
    local d24h totalh; d24h=$(human_bytes "$d24"); totalh=$(human_bytes "$total")

    local caption="📅 <b>Сводка за сутки</b> — $(date '+%Y-%m-%d')
🖥 Сервер: <code>$(hostname)</code>
📡 Inbound'ов: <b>${inb_cnt}</b>
👥 Клиентов: <b>${cli_cnt}</b>

📊 Трафик за 24ч: <b>${d24h}</b>
📈 Всего накоплено: <b>${totalh}</b>

🏆 <b>Топ-5 клиентов:</b>
<pre>${top_text:-нет данных}</pre>

🩺 CPU: $(sys_cpu)%  RAM: $(sys_ram)%  Disk: $(sys_disk)%"

    for a in $ADMIN_IDS; do send_photo "$a" "$out" "$caption"; done
    log "summary sent (24h=${d24h})"
}

handle_command() {
    local chat_id="$1" user_id="$2" text="$3"

    if ! is_admin "$user_id"; then
        log "UNAUTH: $user_id $text"
        send_msg "$chat_id" "⛔ Нет прав. Ваш ID: <code>${user_id}</code>"
        return
    fi
    log "CMD $user_id: $text"

    if [ -f "$PENDING_DIR/$user_id" ] && [[ "$text" != /* ]] && [[ "$text" != ui:* ]]; then
        local state; state=$(cat "$PENDING_DIR/$user_id")
        rm -f "$PENDING_DIR/$user_id"
        case "$state" in
            adduser)
                local name days gb
                name=$(echo "$text" | awk '{print $1}')
                days=$(echo "$text" | awk '{print $2}'); days=${days:-0}
                gb=$(echo   "$text" | awk '{print $3}'); gb=${gb:-0}
                [ -z "$name" ] && { send_msg "$chat_id" "❌ Пустое имя. /menu"; return; }
                send_msg "$chat_id" "🆕 Создаю <code>${name}</code>..."
                local r ok uuid
                r=$(xui_add_client "$name" "$days" "$gb")
                ok=$(echo "$r" | jq -r '.success'); uuid=$(echo "$r" | jq -r '.uuid // ""')
                if [ "$ok" = "true" ]; then
                    local sp st added_list
                    sp=$(db_get subPort); st=$(db_get subPath)
                    added_list=$(echo "$r" | jq -r '.added[]?' | sed 's/^/• /')
                    send_msg "$chat_id" "✅ <code>${name}</code> создан
UUID: <code>${uuid}</code>
subId: <code>${name}</code>
${days} дн • ${gb} ГБ

<pre>${added_list}</pre>"
                    [ -n "$sp" ] && send_link "$chat_id" "📱 base64:" "https://${SERVER_DOMAIN}:${sp}${st}${name}"
                    send_link "$chat_id" "🍎 JSON (prio 443):" "https://${SERVER_DOMAIN}:${NGINX_PORT}/${NGINX_PREFIX}/${name}.json"
                else
                    send_msg "$chat_id" "⚠️ <pre>$(echo "$r" | jq -r '.failed[]?')</pre>"
                fi
                return
                ;;
        esac
    fi

    local cmd; cmd=$(echo "$text" | awk '{print $1}' | sed 's/@.*$//')

    case "$cmd" in

    /start|/help|/menu)
        rm -f "$PENDING_DIR/$user_id"
        local kb='{"inline_keyboard":[
[{"text":"➕ Добавить клиента","callback_data":"ui:add"},{"text":"🗑 Удалить клиента","callback_data":"ui:dellist"}],
[{"text":"👥 Клиенты","callback_data":"/listusers"},{"text":"🟢 Онлайн","callback_data":"/online"}],
[{"text":"📊 Статус","callback_data":"/status"},{"text":"📡 Inbounds","callback_data":"/inbounds"}],
[{"text":"📈 Трафик","callback_data":"/clientstats"},{"text":"🩺 Порты","callback_data":"/check"}],
[{"text":"📅 Сводка","callback_data":"/summary"},{"text":"🚨 Алерты","callback_data":"/alerts"}],
[{"text":"🔄 Restart x-ui","callback_data":"ui:restart_ask"},{"text":"⚡ Restart Xray","callback_data":"ui:xray_ask"}],
[{"text":"📦 Бэкап","callback_data":"/backup"},{"text":"💻 Сервер","callback_data":"/sysinfo"}]
]}'
        send_msg "$chat_id" "🤖 <b>3x-ui Admin Bot v2.2</b>
🖥 <code>$(hostname)</code>
🔗 API: <code>${API}</code>
🎯 Filter: <code>${INBOUND_FILTER}</code>

<i>Управление кнопками. Опасные действия требуют подтверждения.</i>

Текст: /adduser /deluser /listusers /getsubs /clientinfo /resettraffic /inbounds /setfilter /check /checkdest /online /lastconn /xraylog /xrayerr /clientstats /portstats /summary /alerts /status /restart /xrayrestart /logs /backup /backups /uptime /disk /mem /sysinfo" "$kb"
        ;;

    ui:add)
        echo "adduser" > "$PENDING_DIR/$user_id"
        local kb='{"inline_keyboard":[[{"text":"❌ Отмена","callback_data":"ui:cancel"}]]}'
        send_msg "$chat_id" "➕ <b>Новый клиент</b>

Отправьте: <code>имя [дней] [ГБ]</code>

Примеры:
<code>vasya</code>          — без лимитов
<code>vasya 30</code>       — на 30 дней
<code>vasya 30 100</code>   — 30 дней, 100 ГБ" "$kb"
        ;;

    ui:cancel)
        rm -f "$PENDING_DIR/$user_id"
        send_msg "$chat_id" "❌ Отменено. /menu"
        ;;

    ui:dellist)
        local subs
        subs=$(xui_inbounds_list | jq -r '
            [.obj[]? | (.settings|fromjson).clients[]? | (.subId // .email)]
            | unique | .[]' 2>/dev/null | grep -v '^$' | grep -v '^DUMMY$' | head -50)
        if [ -z "$subs" ]; then send_msg "$chat_id" "👥 Клиентов нет."; return; fi
        local rows="" row="" i=0
        while IFS= read -r s; do
            [ -z "$s" ] && continue
            local btn; btn=$(printf '{"text":"🗑 %s","callback_data":"ui:delask:%s"}' "$s" "$s")
            [ -z "$row" ] && row="$btn" || row="$row,$btn"
            i=$((i+1))
            if [ $((i%2)) -eq 0 ]; then rows="${rows:+$rows,}[$row]"; row=""; fi
        done <<< "$subs"
        [ -n "$row" ] && rows="${rows:+$rows,}[$row]"
        rows="${rows},[{\"text\":\"⬅️ Назад\",\"callback_data\":\"/menu\"}]"
        send_msg "$chat_id" "🗑 <b>Выберите клиента:</b>" "{\"inline_keyboard\":[$rows]}"
        ;;

    ui:delask:*)
        local name="${cmd#ui:delask:}"
        local kb; kb=$(printf '{"inline_keyboard":[[{"text":"✅ Да, удалить","callback_data":"ui:delyes:%s"},{"text":"❌ Отмена","callback_data":"ui:dellist"}]]}' "$name")
        send_msg "$chat_id" "⚠️ Удалить <b>${name}</b> из <b>всех</b> inbound'ов?" "$kb"
        ;;

    ui:delyes:*)
        local name="${cmd#ui:delyes:}"
        send_msg "$chat_id" "🗑 Удаляю <code>${name}</code>..."
        local r del fail
        r=$(xui_del_client "$name")
        del=$(echo  "$r" | jq -r '.deleted[]?' | paste -sd, -)
        fail=$(echo "$r" | jq -r '.failed[]?'  | paste -sd, -)
        [ -n "$del" ] && send_msg "$chat_id" "✅ Удалён: <b>${del}</b>${fail:+
❌ Ошибки: ${fail}}" || send_msg "$chat_id" "⚠️ Клиент не найден"
        ;;

    ui:restart_ask)
        local kb='{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:restart_yes"},{"text":"❌ Отмена","callback_data":"/menu"}]]}'
        send_msg "$chat_id" "⚠️ Перезапустить x-ui?
Активные соединения порвутся на ~3 сек." "$kb"
        ;;

    ui:restart_yes)
        send_msg "$chat_id" "🔄 Перезапускаю x-ui..."
        systemctl restart x-ui && sleep 3
        systemctl is-active --quiet x-ui && send_msg "$chat_id" "✅ x-ui перезапущен" || send_msg "$chat_id" "❌ Сервис не активен"
        ;;

    ui:xray_ask)
        local kb='{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:xray_yes"},{"text":"❌ Отмена","callback_data":"/menu"}]]}'
        send_msg "$chat_id" "⚠️ Перезапустить <b>Xray</b>?" "$kb"
        ;;

    ui:xray_yes)
        send_msg "$chat_id" "⚡ Перезапуск Xray..."
        local r; r=$(xui_call POST "/panel/api/inbounds/restartXray")
        if echo "$r" | jq -e '.success==true' >/dev/null 2>&1; then send_msg "$chat_id" "✅ Xray перезапущен (API)"
        else systemctl restart x-ui && send_msg "$chat_id" "✅ Перезапущен (systemd fallback)" || send_msg "$chat_id" "❌ Ошибка"
        fi
        ;;

    ui:reset_ask:*)
        local name="${cmd#ui:reset_ask:}"
        local kb; kb=$(printf '{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:reset_yes:%s"},{"text":"❌ Отмена","callback_data":"/menu"}]]}' "$name")
        send_msg "$chat_id" "⚠️ Сбросить трафик <b>${name}</b>?" "$kb"
        ;;

    ui:reset_yes:*)
        local name="${cmd#ui:reset_yes:}"
        local pairs; pairs=$(xui_inbounds_list | jq -r --arg n "$name" '
            .obj[]? as $i | ($i.settings|fromjson).clients[]?
            | select(.subId == $n or .email == $n or (.email|startswith($n + "-")))
            | "\($i.id) \(.email)"')
        [ -z "$pairs" ] && { send_msg "$chat_id" "❌ <code>${name}</code> не найден"; return; }
        local ok=0 fail=0 r
        while IFS=' ' read -r ib email; do
            [ -z "$ib" ] && continue
            r=$(xui_call POST "/panel/api/inbounds/${ib}/resetClientTraffic/${email}")
            echo "$r" | jq -e '.success==true' >/dev/null 2>&1 && ok=$((ok+1)) || fail=$((fail+1))
        done <<< "$pairs"
        send_msg "$chat_id" "✅ Сброшено: ${ok}${fail:+ (ошибок: $fail)}"
        ;;

    /status)
        local s; s=$(systemctl status x-ui --no-pager 2>&1 | head -8)
        send_msg "$chat_id" "📊 <b>x-ui</b>
<pre>${s}</pre>"
        ;;

    /logs)
        local l; l=$(journalctl -u x-ui -n 20 --no-pager 2>&1 | tail -20)
        send_msg "$chat_id" "📜 <pre>${l:0:3500}</pre>"
        ;;

    /restart)
        local kb='{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:restart_yes"},{"text":"❌ Отмена","callback_data":"/menu"}]]}'
        send_msg "$chat_id" "⚠️ Перезапустить x-ui?" "$kb"
        ;;

    /xrayrestart)
        local kb='{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:xray_yes"},{"text":"❌ Отмена","callback_data":"/menu"}]]}'
        send_msg "$chat_id" "⚠️ Перезапустить Xray?" "$kb"
        ;;

    /adduser)
        local name days gb
        name=$(echo "$text" | awk '{print $2}')
        days=$(echo "$text" | awk '{print $3}'); days=${days:-0}
        gb=$(echo   "$text" | awk '{print $4}'); gb=${gb:-0}
        if [ -z "$name" ] || [ "$name" = "/adduser" ]; then
            send_msg "$chat_id" "ℹ️ <code>/adduser имя [дней] [ГБ]</code>
Или нажмите ➕ в /menu"
            return
        fi
        send_msg "$chat_id" "🆕 Создаю <code>${name}</code>..."
        local r ok uuid
        r=$(xui_add_client "$name" "$days" "$gb")
        ok=$(echo "$r" | jq -r '.success'); uuid=$(echo "$r" | jq -r '.uuid // ""')
        if [ "$ok" = "true" ]; then
            local sp st added_list
            sp=$(db_get subPort); st=$(db_get subPath)
            added_list=$(echo "$r" | jq -r '.added[]?' | sed 's/^/• /')
            send_msg "$chat_id" "✅ <code>${name}</code> создан
UUID: <code>${uuid}</code>
${days} дн • ${gb} ГБ

<pre>${added_list}</pre>"
            [ -n "$sp" ] && send_link "$chat_id" "📱 base64:" "https://${SERVER_DOMAIN}:${sp}${st}${name}"
            send_link "$chat_id" "🍎 JSON:" "https://${SERVER_DOMAIN}:${NGINX_PORT}/${NGINX_PREFIX}/${name}.json"
        else
            send_msg "$chat_id" "⚠️ <pre>$(echo "$r" | jq -r '.failed[]?')</pre>"
        fi
        ;;

    /deluser)
        local name; name=$(echo "$text" | awk '{print $2}')
        if [ -z "$name" ] || [ "$name" = "/deluser" ]; then send_msg "$chat_id" "ℹ️ /deluser имя"; return; fi
        local kb; kb=$(printf '{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:delyes:%s"},{"text":"❌ Отмена","callback_data":"/menu"}]]}' "$name")
        send_msg "$chat_id" "⚠️ Удалить <b>${name}</b>?" "$kb"
        ;;

    /listusers)
        send_msg "$chat_id" "📋 Загружаю..."
        local list
        list=$(xui_inbounds_list | jq -r '
            .obj[]? as $i | ($i.settings|fromjson).clients[]?
            | "\(.subId // .email)|\($i.remark)|\(.enable)"' \
          | awk -F'|' '
              { key=$1; inb[key]=inb[key]$2" "; if($3=="true")on[key]++; cnt[key]++ }
              END { for(k in cnt) printf "%-22s %d/%d  [%s]\n",k,on[k],cnt[k],inb[k] }' \
          | sort)
        send_msg "$chat_id" "👥 <pre>${list:0:3800}</pre>"
        ;;

    /getsubs)
        local name; name=$(echo "$text" | awk '{print $2}')
        if [ -z "$name" ] || [ "$name" = "/getsubs" ]; then send_msg "$chat_id" "ℹ️ /getsubs имя"; return; fi
        local sp st sj
        sp=$(db_get subPort); st=$(db_get subPath); sj=$(db_get subJsonPath)
        send_msg "$chat_id" "🔗 <b><code>${name}</code></b>:"
        send_link "$chat_id" "📱 base64:"  "https://${SERVER_DOMAIN}:${sp}${st}${name}"
        send_link "$chat_id" "📄 Xray:"     "https://${SERVER_DOMAIN}:${sp}${sj}${name}"
        send_link "$chat_id" "🍎 sing-box:" "https://${SERVER_DOMAIN}:${NGINX_PORT}/${NGINX_PREFIX}/${name}.json"
        ;;

    /clientinfo)
        local name; name=$(echo "$text" | awk '{print $2}')
        if [ -z "$name" ] || [ "$name" = "/clientinfo" ]; then send_msg "$chat_id" "ℹ️ /clientinfo имя"; return; fi
        local rows
        rows=$(xui_inbounds_list | jq -r --arg n "$name" '
            .obj[]? as $i | ($i.settings|fromjson).clients[]?
            | select(.subId == $n or .email == $n or (.email|startswith($n + "-")))
            | "\(.email)|\($i.remark)|\(.enable)|\(.expiryTime)|\(.totalGB)"')
        [ -z "$rows" ] && { send_msg "$chat_id" "❌ <code>${name}</code> не найден"; return; }

        local info="📛 <b>${name}</b>"
        local tu=0 td=0 lim=0 exp_first=""
        while IFS='|' read -r email remark enable exp l; do
            [ -z "$email" ] && continue
            local t up dn
            t=$(xui_client_traffic "$email")
            up=$(echo "$t" | jq -r '.obj.up // 0'); dn=$(echo "$t" | jq -r '.obj.down // 0')
            tu=$((tu+up)); td=$((td+dn))
            lim=$((lim + ${l:-0}))
            [ -z "$exp_first" ] && exp_first="$exp"
            local en="✓"; [ "$enable" != "true" ] && en="✗"
            info+="
${en} ${remark} (<code>${email}</code>)  ↑$((up/1048576))MB ↓$((dn/1048576))MB"
        done <<< "$rows"

        local tot_mb=$(( (tu+td)/1048576 ))
        local exp_str="∞"
        [ "${exp_first:-0}" != "0" ] && [ -n "${exp_first}" ] \
            && exp_str=$(date -d "@$((exp_first/1000))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$exp_first")
        local lim_str="∞"
        [ "$lim" -gt 0 ] && lim_str="$((lim/1073741824)) GB"
        info+="

📊 Итого: ${tot_mb} MB
🎯 Лимит: ${lim_str}
⏰ Срок:  ${exp_str}"

        local kb; kb=$(printf '{"inline_keyboard":[[{"text":"♻️ Сбросить","callback_data":"ui:reset_ask:%s"},{"text":"🗑 Удалить","callback_data":"ui:delask:%s"}],[{"text":"⬅️ Меню","callback_data":"/menu"}]]}' "$name" "$name")
        send_msg "$chat_id" "$info" "$kb"
        ;;

    /resettraffic)
        local name; name=$(echo "$text" | awk '{print $2}')
        if [ -z "$name" ] || [ "$name" = "/resettraffic" ]; then send_msg "$chat_id" "ℹ️ /resettraffic имя"; return; fi
        local kb; kb=$(printf '{"inline_keyboard":[[{"text":"✅ Да","callback_data":"ui:reset_yes:%s"},{"text":"❌ Отмена","callback_data":"/menu"}]]}' "$name")
        send_msg "$chat_id" "⚠️ Сбросить трафик <b>${name}</b>?" "$kb"
        ;;

    /inbounds)
        local list
        list=$(xui_inbounds_list | jq -r '.obj[]? |
            "\(.port)|\(.remark)|\(.protocol)|\(if .enable then "✓" else "✗" end)|ID:\(.id)"' \
            | awk -F'|' '{printf "%-6s %-22s %-7s %s  %s\n",$1,$2,$3,$4,$5}')
        send_msg "$chat_id" "📡 <pre>${list:-нет}</pre>"
        ;;

    /setfilter)
        local f; f=$(echo "$text" | cut -d' ' -f2-)
        if [ -z "$f" ] || [ "$f" = "/setfilter" ]; then
            send_msg "$chat_id" "Текущий: <code>${INBOUND_FILTER}</code>

<code>/setfilter all</code>
<code>/setfilter vless</code>
<code>/setfilter regex:^(main-|fallback-)</code>
<code>/setfilter list:1,2,3</code>"; return
        fi
        if grep -q '^INBOUND_FILTER=' "$BOT_DIR/bot.env" 2>/dev/null; then
            sed -i "s|^INBOUND_FILTER=.*|INBOUND_FILTER=\"${f}\"|" "$BOT_DIR/bot.env"
        else
            echo "INBOUND_FILTER=\"${f}\"" >> "$BOT_DIR/bot.env"
        fi
        INBOUND_FILTER="$f"
        send_msg "$chat_id" "✅ Фильтр: <code>${f}</code>"
        ;;

    /check)
        local out=""
        for p in 443 993 587 465; do
            timeout 3 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null && out+="✅ :${p}
" || out+="❌ :${p}
"
        done
        send_msg "$chat_id" "<pre>${out}</pre>"
        ;;

    /checkdest)
        local dest
        dest=$(xui_inbounds_list | jq -r '.obj[]? | select(.protocol=="vless") |
            (.streamSettings|fromjson).realitySettings.dest // empty' | head -1)
        [ -z "$dest" ] && { send_msg "$chat_id" "❌ Reality dest не найден"; return; }
        local h="${dest%:*}" p="${dest##*:}" tcp tls http
        timeout 5 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null && tcp="✅" || tcp="❌"
        echo Q | timeout 5 openssl s_client -connect "${h}:${p}" -servername "$h" -tls1_3 2>&1 \
            | tr -d '\0' | grep -qE '(TLSv1\.3|TLS_AES_|TLS_CHACHA)' && tls="✅" || tls="❌"
        http=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "https://${h}:${p}/")
        send_msg "$chat_id" "📡 <code>${dest}</code>
TCP ${tcp}  TLS1.3 ${tls}  HTTP <code>${http}</code>"
        ;;

    /online)
        local r emails count
        r=$(xui_onlines)
        emails=$(echo "$r" | jq -r '.obj[]? // empty' 2>/dev/null)
        if [ -z "$emails" ] && [ -f "$XRAY_ACCESS_LOG" ]; then
            local now prev
            now=$(date '+%Y/%m/%d %H:%M')
            prev=$(date '+%Y/%m/%d %H:%M' --date='1 minute ago')
            emails=$(tail -2000 "$XRAY_ACCESS_LOG" | grep -E "($now|$prev)" \
                | awk -F 'email: ' '/email:/ {print $2}' | awk '{print $1}' | sort -u)
        fi
        if [ -z "$emails" ]; then send_msg "$chat_id" "😴 Нет активных подключений"
        else count=$(echo "$emails" | wc -l); send_msg "$chat_id" "🟢 <b>Онлайн: ${count}</b>
<pre>${emails}</pre>"
        fi
        ;;

    /lastconn)
        [ ! -f "$XRAY_ACCESS_LOG" ] && { send_msg "$chat_id" "❌ access.log нет"; return; }
        local name; name=$(echo "$text" | awk '{print $2}')
        if [ -z "$name" ] || [ "$name" = "/lastconn" ]; then send_msg "$chat_id" "ℹ️ /lastconn имя"; return; fi
        local last; last=$(grep "email: ${name}" "$XRAY_ACCESS_LOG" 2>/dev/null | tail -10)
        [ -z "$last" ] && send_msg "$chat_id" "😴 Нет данных" || send_msg "$chat_id" "📜 <pre>${last:0:3500}</pre>"
        ;;

    /xraylog)
        [ ! -f "$XRAY_ACCESS_LOG" ] && { send_msg "$chat_id" "❌ access.log нет"; return; }
        send_msg "$chat_id" "📜 <pre>$(tail -20 "$XRAY_ACCESS_LOG" | head -c 3500)</pre>"
        ;;

    /xrayerr)
        [ ! -f "$XRAY_ERROR_LOG" ] && { send_msg "$chat_id" "❌ error.log нет"; return; }
        local l; l=$(tail -20 "$XRAY_ERROR_LOG")
        [ -z "$l" ] && send_msg "$chat_id" "✅ Ошибок нет" || send_msg "$chat_id" "🚨 <pre>${l:0:3500}</pre>"
        ;;

    /clientstats)
        local stats
        stats=$(xui_inbounds_list | jq -r '
            [.obj[]?.clientStats[]?] | sort_by(-(.up+.down)) |
            map(select((.up+.down)>0 and (.email|startswith("DUMMY-")|not))) |
            .[0:15] | .[] |
            "\(.email)|\(((.up+.down)/1024/1024*10|floor)/10) MB"' \
            | awk -F'|' '{printf "%-28s %s\n",$1,$2}')
        send_msg "$chat_id" "📊 <b>TOP-15:</b>
<pre>${stats:-нет}</pre>"
        ;;

    /portstats)
        [ ! -f "$XRAY_ACCESS_LOG" ] && { send_msg "$chat_id" "❌ access.log нет"; return; }
        local stats
        stats=$(tail -5000 "$XRAY_ACCESS_LOG" | awk -F '[][]' '/inbound-/ {print $2}' \
            | awk '{print $1}' | sort | uniq -c | sort -rn \
            | awk '{printf "%-25s %s conn.\n",$2,$1}')
        send_msg "$chat_id" "📡 <pre>${stats:-нет}</pre>"
        ;;

    /summary)
        send_msg "$chat_id" "📅 Готовлю сводку..."
        send_summary
        ;;

    /alerts)
        local state cpu ram disk x_st
        state=$(cat "$ALERT_STATE")
        cpu=$(get_cpu_pct); ram=$(get_ram_pct); disk=$(get_disk_pct)
        xui_active && x_st="🟢 active" || x_st="🔴 down"
        send_msg "$chat_id" "🚨 <b>Алертинг</b>

Текущее:
• CPU:  <b>${cpu}%</b>  (порог ${CPU_THRESHOLD}%)
• RAM:  <b>${ram}%</b>  (порог ${RAM_THRESHOLD}%)
• Disk: <b>${disk}%</b> (порог ${DISK_THRESHOLD}%)
• x-ui: ${x_st}
• Интервал: ${CHECK_INTERVAL}s

Флаги:
<pre>$(echo "$state" | jq .)</pre>"
        ;;

    /backup)
        local f="$BACKUP_DIR/x-ui-backup-$(date +%F-%H%M).tar.gz"
        send_msg "$chat_id" "📦 Бэкап..."
        if tar czf "$f" /etc/x-ui /usr/local/x-ui/bin "$BOT_DIR/bot.env" 2>/dev/null; then
            ls -1t "$BACKUP_DIR"/x-ui-backup-*.tar.gz 2>/dev/null | tail -n +21 | xargs -r rm -f
            local sz; sz=$(du -h "$f" | cut -f1)
            send_doc "$chat_id" "$f" "✅ $(basename "$f") (${sz})"
        else
            send_msg "$chat_id" "❌ tar error"
        fi
        ;;

    /backups)
        local list cnt
        list=$(ls -lht "$BACKUP_DIR"/x-ui-backup-*.tar.gz 2>/dev/null | head -10 \
            | awk '{print $5, $NF}' | awk '{n=split($2,a,"/"); printf "%-8s %s\n",$1,a[n]}')
        cnt=$(ls -1 "$BACKUP_DIR"/x-ui-backup-*.tar.gz 2>/dev/null | wc -l)
        send_msg "$chat_id" "📦 <b>Локально (${cnt}):</b>
<pre>${list:-нет}</pre>"
        ;;

    /uptime)
        send_msg "$chat_id" "⏰ <b>Uptime:</b> $(uptime -p)
📈 <b>Load:</b>$(awk '{printf " %.2f %.2f %.2f", $1,$2,$3}' /proc/loadavg)"
        ;;

    /disk)
        send_msg "$chat_id" "💽 <pre>$(df -hP / | tail -1 | awk '{print "Всего: "$2"\nЗанято: "$3" ("$5")\nСвободно: "$4}')</pre>"
        ;;

    /mem)
        send_msg "$chat_id" "💾 <pre>$(awk '
            /^MemTotal:/{t=$2}
            /^MemAvailable:/{a=$2}
            END{ printf "Всего:    %.1f GB\nДоступно: %.1f GB\nЗанято:   %.1f%%", t/1048576, a/1048576, (t-a)*100/t }
        ' /proc/meminfo)</pre>"
        ;;

    /sysinfo)
        send_msg "$chat_id" "💻 <pre>Host:   $(hostname)
Kernel: $(uname -r)
Uptime: $(uptime -p)
Load:  $(awk '{printf "%.2f %.2f %.2f", $1,$2,$3}' /proc/loadavg)
Disk:   $(get_disk_pct)% used /
Mem:    $(get_ram_pct)% used
CPU:    $(get_cpu_pct)% used
x-ui:   $(systemctl is-active x-ui)
bot:    $(systemctl is-active 3x-ui-bot)
alerts: $(systemctl is-active 3x-ui-bot-alerts)</pre>"
        ;;

    *)
        send_msg "$chat_id" "❓ Неизвестно: <code>${cmd}</code>
/menu — главное меню"
        ;;
    esac
}

main_loop() {
    if [ -z "$BOT_TOKEN" ] || [ -z "$XUI_API_TOKEN" ]; then
        log "FATAL: BOT_TOKEN/XUI_API_TOKEN пусты"
        exit 1
    fi
    log "=== Bot v2.2 started, API=${API}, FILTER=${INBOUND_FILTER} ==="

    local sanity; sanity=$(xui_inbounds_list | jq -r '.success // "err"' 2>/dev/null)
    [ "$sanity" = "true" ] && log "API OK" || log "API check FAILED"

    broadcast_admins "🚀 Бот v2.2 запущен на <code>$(hostname)</code>
API: ${sanity}"

    while true; do
        offset=$(get_offset)
        response=$(curl -s --max-time 35 \
            "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D")
        [ -z "$response" ] && { log "empty resp"; sleep 5; continue; }
        if [ "$(echo "$response" | jq -r '.ok // false')" != "true" ]; then
            log "API err: $response"; sleep 10; continue
        fi

        echo "$response" | jq -c '.result[]?' | while read -r u; do
            uid=$(echo "$u" | jq -r '.update_id // empty'); [ -z "$uid" ] && continue
            set_offset $((uid+1))

            cb_id=$(echo "$u" | jq -r '.callback_query.id // empty')
            if [ -n "$cb_id" ]; then
                cb_data=$(echo "$u" | jq -r '.callback_query.data // empty')
                cb_chat=$(echo "$u" | jq -r '.callback_query.message.chat.id // empty')
                cb_user=$(echo "$u" | jq -r '.callback_query.from.id // empty')
                answer_callback "$cb_id" ""
                [ -n "$cb_data" ] && handle_command "$cb_chat" "$cb_user" "$cb_data"
                continue
            fi

            chat=$(echo "$u" | jq -r '.message.chat.id // empty')
            user=$(echo "$u" | jq -r '.message.from.id // empty')
            txt=$(echo "$u"  | jq -r '.message.text // empty')
            [ -n "$txt" ] && [ -n "$chat" ] && handle_command "$chat" "$user" "$txt"
        done
        sleep 1
    done
}

case "${1:-run}" in
    run)          main_loop ;;
    alerts-loop)  alerts_loop ;;
    snapshot)     snapshot_traffic ;;
    summary)      send_summary ;;
    check)        run_check ;;
    *)
        echo "Usage: $0 {run|alerts-loop|snapshot|summary|check}"
        exit 1
        ;;
esac
