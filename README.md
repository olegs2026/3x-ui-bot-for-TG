# 🤖 3x-ui-bot

Telegram-бот для управления панелью **[3x-ui](https://github.com/MHSanaei/3x-ui)** с поддержкой VLESS-Reality, multi-inbound клиентами, алертингом и ежедневной аналитикой.

![Shell](https://img.shields.io/badge/Shell-Bash%205+-89e051?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-3.0.1+-blue)

---

## 📑 Содержание

- [Возможности](#-возможности)
- [Требования](#-требования)
- [Быстрая установка](#-быстрая-установка)
- [Структура проекта](#-структура-проекта)
- [Команды бота](#-команды-бота)
- [Управление сервисами](#-управление-сервисами)
- [Алертинг и сводка](#-алертинг-и-сводка)
- [Диагностика](#-диагностика)
- [Обновление](#-обновление)
- [Удаление](#-удаление)
- [Утилиты](#-утилиты)
- [Troubleshooting](#-troubleshooting)
- [Безопасность](#-безопасность)
- [FAQ](#-faq)
- [Лицензия](#-лицензия)

---

## ✨ Возможности

### 👥 Управление клиентами
- ➕ Создание клиента одной командой **сразу во всех inbound'ах** (multi-inbound)
- 🗑 Удаление с подтверждением
- 🔄 Сброс трафика
- 📋 Список с группировкой по subId
- 🔗 Получение ссылок на подписки (base64 / Xray JSON / sing-box JSON)
- ♻️ Автоматический `flow=xtls-rprx-vision` для VLESS-Reality

### 🛡 Защита и стабильность
- 🛡 **DUMMY-пользователь** в каждом inbound'е — гарантирует, что Xray всегда поднимает порт
- 🔐 Автогенерация x25519-ключей и shortIds
- ✅ Подтверждение всех опасных действий (delete / restart) инлайн-кнопками
- 🔒 Конфиг с секретами `chmod 600`

### 🚨 Мониторинг
- 📡 Алерты в Telegram при превышении CPU / RAM / Disk
- 💔 Алерт при падении сервиса x-ui или API
- ✅ Анти-spam: повторные алерты не шлются, recovery-сообщения при восстановлении
- 📈 Часовой снимок трафика (для графиков)

### 📅 Ежедневная сводка (в 10:00 локального времени)
- 📊 PNG-график трафика за 24ч (gnuplot)
- 🏆 Топ-5 клиентов по объёму
- 💻 Текущее состояние сервера
- 📧 Доставка всем admin'ам через Telegram

### 🩺 Диагностика
- ✅ 59 проверок в одном скрипте (`healthcheck.sh`)
- 📤 Вывод в текст / JSON / отправка в Telegram
- 🎯 Reality-suitability score для доменов

### 🛠 Инструменты эксплуатации
- 📦 Создание / выгрузка бэкапов через бот
- 🔄 Обновление с автоматическим rollback при падении
- 🧹 Корректное удаление с сохранением выборочных данных

---

## 📋 Требования

| Компонент | Версия | Назначение |
|---|---|---|
| OS | **Ubuntu 22.04** или **24.04** LTS (Debian 11/12 — тоже) | Базовая ОС |
| Bash | ≥ 4 (нужны associative arrays) | Все скрипты |
| [3x-ui](https://github.com/MHSanaei/3x-ui) | ≥ 3.0.1 | VPN-панель |
| Telegram Bot | от [@BotFather](https://t.me/BotFather) | Канал управления |
| 3x-ui API Token | Bearer (Settings → Telegram Bot) | API панели |

**Автоматически устанавливаемые пакеты:**
`curl`, `jq`, `sqlite3`, `gnuplot`, `bc`, `openssl`, `iproute2`, `uuid-runtime`, `python3`

---

## 🚀 Быстрая установка

### 1. Установите 3x-ui (если ещё нет)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

В панели создайте API Token: Settings → Telegram Bot → Bot API Token.

Создайте бота у @BotFather и запишите Token.
Узнайте свой Telegram ID у @userinfobot.

2. Клонируйте репозиторий
bash

git clone https://github.com/YOUR-USERNAME/3x-ui-bot.git
cd 3x-ui-bot
3. Запустите установщик
bash

chmod +x install.sh
sudo ./install.sh
Установщик:

Проверит зависимости (bash 4+, root, OS, NTP, сеть)
Спросит интерактивно все параметры (token, admin ID, API URL и т.д.)
Проверит доступность Telegram API и 3x-ui API
Автоматически создаст недостающие VLESS-Reality inbound'ы (если их нет)
Сгенерирует x25519-ключи через xray x25519
Добавит DUMMY-пользователя в каждый inbound (защита от падения Xray)
Установит и запустит 4 systemd-юнита
4. Откройте бота в Telegram
/start → появится меню с инлайн-кнопками.

📁 Структура проекта
После установки:

/opt/3x-ui-bot/
├── bot.sh                # основной бот (long-polling)
├── bot.env               # конфиг с токенами (chmod 600)
├── reality-keys.txt      # x25519 ключи + shortId (chmod 600)
├── healthcheck.sh        # диагностика
├── update.sh             # обновление + rollback
├── uninstall.sh          # удаление
├── sni-check.sh          # проверка доменов для Reality
├── backups/              # tar.gz бэкапы x-ui (+ update-* субдиректории)
├── logs/
│   ├── bot.log
│   └── alerts.log
└── data/
    ├── offset            # Telegram polling offset
    ├── alert_state.json  # состояние алертов
    ├── traffic.csv       # часовые снимки трафика
    └── pending/          # session state для inline-flow
systemd-юниты:

3x-ui-bot.service — основной бот (long-polling)
3x-ui-bot-alerts.service — мониторинг (loop)
3x-ui-bot-snapshot.timer — снимок трафика (hourly)
3x-ui-bot-summary.timer — ежедневная сводка (10:00)

🎯 Команды бота
Главное меню (инлайн-кнопки)
[ ➕ Добавить клиента ] [ 🗑 Удалить клиента ]
[ 👥 Клиенты         ] [ 🟢 Онлайн          ]
[ 📊 Статус          ] [ 📡 Inbounds        ]
[ 📈 Трафик          ] [ 🩺 Порты           ]
[ 📅 Сводка          ] [ 🚨 Алерты          ]
[ 🔄 Restart x-ui    ] [ ⚡ Restart Xray    ]
[ 📦 Бэкап           ] [ 💻 Сервер          ]
Текстовые команды
Категория	Команды
Клиенты	/adduser имя [дней] [ГБ], /deluser имя, /listusers, /getsubs имя, /clientinfo имя, /resettraffic имя
Inbound'ы	/inbounds, /setfilter all|vless|regex:...|list:..., /check, /checkdest
Мониторинг	/online, /lastconn имя, /xraylog, /xrayerr, /clientstats, /portstats
Алертинг	/alerts, /summary
Сервис	/status, /restart, /xrayrestart, /logs
Бэкапы	/backup, /backups
Сервер	/uptime, /disk, /mem, /sysinfo
Пример: создание клиента
В чате с ботом → ➕ Добавить клиента → ввести vasya 30 100

Бот создаст клиента vasya сразу в 4-х inbound'ах с email'ами вида:

vasya-main-443
vasya-fallback-993
vasya-fallback-587
vasya-fallback-465
Общий subId=vasya → подписка одна, конфиги для всех inbound'ов.

В ответ придут:

📱 base64-ссылка для V2rayN/V2Box/HAPP
🍎 JSON-ссылка для sing-box (с приоритетом 443)
🛠 Управление сервисами
bash

# Статус
systemctl status 3x-ui-bot 3x-ui-bot-alerts x-ui --no-pager
systemctl list-timers '3x-ui-bot-*'

# Логи
tail -f /opt/3x-ui-bot/logs/bot.log
tail -f /opt/3x-ui-bot/logs/alerts.log
journalctl -u 3x-ui-bot -n 100 --no-pager

# Перезапуск
systemctl restart 3x-ui-bot 3x-ui-bot-alerts

# Ручные команды
sudo /opt/3x-ui-bot/bot.sh summary    # сводка сейчас
sudo /opt/3x-ui-bot/bot.sh snapshot   # снимок трафика
sudo /opt/3x-ui-bot/bot.sh check      # разовая проверка алертов
🚨 Алертинг и сводка
Что проверяется (каждые 60 сек)
Метрика	Источник	Порог по умолчанию
CPU	/proc/stat (Δ за 0.5 сек)	85%
RAM	/proc/meminfo	85%
Disk /	df -P /	90%
x-ui service	systemctl is-active	—
3x-ui API	GET /panel/api/inbounds/list	—
Поведение при срабатывании
Первое превышение → 🚨 ALERT в Telegram всем админам
Повторные при том же состоянии → молчание (анти-spam)
Восстановление → ✅ RECOVERED уведомление
Изменение порогов
bash

sudo nano /opt/3x-ui-bot/bot.env
# поправьте CPU_THRESHOLD / RAM_THRESHOLD / DISK_THRESHOLD / CHECK_INTERVAL
sudo systemctl restart 3x-ui-bot-alerts
Ежедневная сводка
В 10:00 по Europe/Moscow (час и TZ настраиваются в bot.env):

📊 PNG-график трафика за 24 часа
🏆 Топ-5 клиентов по subId (с фильтром DUMMY-*)
📡 Inbound'ы / клиенты / суммарный трафик
🩺 Текущее CPU / RAM / Disk
🩺 Диагностика
bash

sudo /opt/3x-ui-bot/healthcheck.sh --verbose
Проверяет 59 пунктов в 11 категориях:

config — bot.env загружается и валиден
system — OS, uptime, load, CPU/RAM/Disk, NTP, bash
files — права на каталоги/файлы/юниты, синтаксис bot.sh
services — x-ui, 3x-ui-bot, 3x-ui-bot-alerts (через LoadState)
timers — snapshot, summary (active + next run)
telegram — getMe, admins
xui-api — inbounds/list работает
inbounds — каждый из 4 required inbound'ов
ports — TCP-прослушка на 443/993/587/465
dummy — DUMMY-пользователь в каждом inbound
reality-dest — TCP+TLS 1.3 на dest каждого inbound
db — целостность x-ui.db
logs — bot.log/alerts.log (свежесть, число ошибок)
data — traffic.csv, alert_state, backups, pending
network — доступность api.telegram.org
Опции
Флаг	Эффект
--verbose	Детальный вывод по каждой проверке
--json	JSON для интеграций (Zabbix, Prometheus, ...)
--tg	Отправить отчёт в Telegram админам
Exit codes
0 — всё OK
1 — есть FAIL (критика)
2 — есть только WARN
Использование в cron
bash

# Раз в час, шлёт в TG только если что-то не так
0 * * * * /opt/3x-ui-bot/healthcheck.sh >/dev/null 2>&1 || /opt/3x-ui-bot/healthcheck.sh --tg
🔄 Обновление
Обновить только bot.sh
Положите новый bot.sh рядом с update.sh
Запустите:
bash

sudo /opt/3x-ui-bot/update.sh
Что произойдёт:

Сравнит md5 (если идентично — выйдет)
Покажет diff (можно посмотреть и подтвердить)
Проверит bash -n синтаксис
Сделает бэкап текущей версии → backups/update-YYYYMMDD-HHMMSS/
Атомарно заменит файл (install -m 755 -o root -g root)
Перезапустит сервисы
Health-check 15 сек — если упадёт, автоматически откатится
Опции
Флаг	Эффект
--yes	Без вопросов
--diff	Принудительно показать diff
--no-restart	Подменить файл, рестарт сделать вручную
--force	Заменить, даже если md5 совпадает
--rollback	Откатиться на предыдущую версию
--keep N	Хранить N последних бэкапов (default 10)
--dry-run	Только показать план
Ручной rollback
bash

sudo /opt/3x-ui-bot/update.sh --rollback
🗑 Удаление
bash

sudo /opt/3x-ui-bot/uninstall.sh
В интерактивном режиме спросит, что сохранить (бэкапы, конфиг, логи) — сохранит в /root/3x-ui-bot-saved-YYYYMMDD-HHMMSS/.

Опции для скриптинга
Флаг	Эффект
--yes	Без подтверждений
--keep-backups	Сохранить tar.gz бэкапы
--keep-config	Сохранить bot.env и reality-keys.txt
--keep-logs	Сохранить логи
--keep-all	Только остановить сервисы, ничего не удалять
--purge	Дополнительно удалить DUMMY-пользователей из 3x-ui
--dry-run	Только показать план
Что НЕ удаляется
Сама панель 3x-ui (x-ui.service, /etc/x-ui, /usr/local/x-ui)
Реальные клиенты и inbound'ы
Системные пакеты (jq, gnuplot и т.п. могут использоваться другим)
Telegram-бот у @BotFather
🧰 Утилиты
sni-check.sh — проверка доменов для Reality
Тестирует пул популярных российских доменов на пригодность как Reality dest:

bash

sudo /opt/3x-ui-bot/sni-check.sh --verbose --retries 10
Что проверяется:

DNS + IP + страна
TCP-соединение (avg 3 попытки)
TLS 1.3 success rate (N попыток — детектит нестабильные CDN)
Key Exchange (X25519 / P-256 / ...)
ALPN (h2 / http/1.1)
Сертификат: CN, Issuer, дни до истечения, SAN entries
HTTP-ответ (код + HTTPv)
Reality-suitability score (0-10)
Выходные данные подскажут, какие домены безопасно использовать.

Свой список:

bash

sudo /opt/3x-ui-bot/sni-check.sh --domains "www.example.ru:443 www.test.ru:443"
JSON-вывод:

bash

sudo /opt/3x-ui-bot/sni-check.sh --json > dests-report.json

🩹 Troubleshooting
Бот не отвечает
bash

systemctl status 3x-ui-bot --no-pager
tail -30 /opt/3x-ui-bot/logs/bot.log
journalctl -u 3x-ui-bot -n 50 --no-pager
api.telegram.org недоступен
Проверьте /etc/hosts (не должно быть 127.0.0.1 api.telegram.org):

bash

getent hosts api.telegram.org
# должно: 149.154.167.220 api.telegram.org
Если другое — поправьте:

bash

sudo sed -i '/api\.telegram\.org/d' /etc/hosts
echo "149.154.167.220 api.telegram.org" | sudo tee -a /etc/hosts
sudo systemctl restart 3x-ui-bot
juq: error: syntax error, unexpected ?//
Это jq 1.7 на Ubuntu 24 — требует пробел в fromjson? // {}. Скрипты v2.8+ уже это учитывают, но если вдруг попались старые:

bash

sudo sed -i \
  -e 's|fromjson?//|fromjson? // |g' \
  -e 's|\.clients//|.clients // |g' \
  /opt/3x-ui-bot/*.sh
Xray не стартует (порты не слушаются)
Проверьте конфиг inbound'а на double-encoding (settings начинается с "{\"clients\"...):

bash

sudo sqlite3 /etc/x-ui/x-ui.db \
    "SELECT length(settings), substr(settings,1,80) FROM inbounds WHERE remark='main-443';"
Если видите "{\"clients\" (с экранированием) — settings двойной-закодирован. Чините через прямой Python-фикс (см. issue templates) или удалите inbound и пересоздайте.

Healthcheck показывает FAIL для активного сервиса
Скорее всего grep по list-unit-files ложно негативит. В версии v1.2 используется systemctl show -p LoadState — обновитесь.

Подробнее — в issue-трекере
Если что-то не покрыто — открывайте issue с приложением:

healthcheck.sh --verbose (полный вывод)
последние 50 строк bot.log
journalctl -u 3x-ui-bot -n 50 --no-pager
🔒 Безопасность
Файл	Права	Содержит
bot.env	600 root:root	BOT_TOKEN, XUI_API_TOKEN
reality-keys.txt	600 root:root	x25519 private key
backups/*.tar.gz	640 root:root	x-ui.db, bot.env
data/*	644 root:root	состояние (не секреты)
systemd-юниты	644 root:root	пути к файлам
Рекомендации
Защитите /etc/hosts от случайных правок:

bash

sudo chattr +i /etc/hosts
Регулярные бэкапы — нажимайте 📦 Бэкап в боте или настройте через cron:

bash

0 4 * * * /opt/3x-ui-bot/bot.sh ... # см. ниже
Никогда не коммитьте bot.env в git — в нём токены. Используйте .gitignore:

bot.env
reality-keys.txt
data/
logs/
backups/
Используйте отдельный VPN/Bastion для SSH — не оставляйте 22 порт открытым в интернет.

Ограничьте ADMIN_IDS — только доверенные Telegram-аккаунты.

❓ FAQ
Можно ли менять Reality dest'ы?
Да, только через панель 3x-ui (UI → inbound → Edit → Reality settings). НЕ через API из bash — это вызывает проблему с double-encoding (на нашей практике).

Можно ли использовать на нескольких серверах?
Да. Каждый сервер — отдельная установка с собственным bot.env. Боты могут быть разными (по одному BOT_TOKEN на сервер) или общие (если ADMIN_IDS пересекается).

Поддерживается ли IPv6?
В целом да — getent достанет AAAA-записи. Telegram API в большинстве случаев работает через IPv4.

Что такое DUMMY-пользователь?
В 3x-ui inbound без клиентов не поднимает порт. DUMMY — это «защитный» клиент, который гарантирует, что порт всегда занят, даже если все реальные клиенты удалены. Email формата DUMMY-<remark>, бот его фильтрует во всех своих списках.

Можно ли работать без 3x-ui панели?
Нет, бот работает поверх 3x-ui — использует её API. Для прямого управления Xray нужен другой инструмент.

Зачем нужны fallback-993/587/465?
Это альтернативные порты для клиентов, у которых заблокирован 443 (некоторые корпоративные сети). Клиент пробует main-443, потом fallback — один из них сработает.

Как сменить часовой пояс сводки?
bash

sudo nano /opt/3x-ui-bot/bot.env
# поменяйте TZ=Europe/Moscow на нужный, и SUMMARY_HOUR
sudo systemctl daemon-reload
sudo systemctl restart 3x-ui-bot-summary.timer

Версии скриптов
Файл	Версия	Описание
install.sh	v2.8	Pre-flight + автосоздание inbound'ов + DUMMY
bot.sh	v2.2	Telegram-бот (long-polling, inline-кнопки)
healthcheck.sh	v1.2	59 проверок, JSON-вывод, TG-уведомление
update.sh	v1.1	Обновление с автоматическим rollback
uninstall.sh	v1.1	Корректное удаление + опц. удаление DUMMY
sni-check.sh	v1.2	Reality-suitability score
🤝 Contributing
Приветствуются:

Bug reports с выводом healthcheck.sh --verbose и bot.log
Pull requests с прогоном на Ubuntu 22.04 и 24.04
Идеи по расширению (см. roadmap ниже)
Roadmap
 Inline-выбор срока/лимита кнопками (7д / 30д / 90д / ∞)
 Редактирование клиента из чата (продлить, изменить лимит, enable/disable)
 Изменение порогов алертов прямо из бота
 Восстановление из бэкапа кнопкой
 Алерт за 7 дней до истечения cert'а dest'а
 Алерт за 3 дня до истечения клиента
 z-score детектор аномальных всплесков трафика
 CI/CD: deploy-to-server.sh для управления флотом
 Bundle deploy.sh для curl ... | sudo bash установки
📜 Лицензия
MIT — используйте, модифицируйте, распространяйте свободно. Без гарантий.

🙏 Благодарности
MHSanaei/3x-ui — отличная панель
XTLS/Xray-core — Reality
gnuplot, jq, sqlite3 — без них всё бы выглядело иначе
