#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ask_continue() {
  read -r -p "$1 [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[~]${NC} $*"; }
err()  { echo -e "${RED}[!]${NC} $*" >&2; }

# Автоопределение локального IP (не localhost)
get_local_ip() {
  ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | grep -v '^172\.17\.' | grep -v '^172\.18\.' | head -1
}

# Получаем имя основного интерфейса
get_main_interface() {
  ip route | grep default | awk '{print $5}' | head -1
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "Запустите скрипт от root (sudo -s или sudo ./install_debian12.sh)"
  exit 1
fi

# Определяем IP-адреса
LOCAL_IP=$(get_local_ip)
MAIN_IFACE=$(get_main_interface)

if [[ -z "$LOCAL_IP" ]]; then
  err "Не удалось определить локальный IP-адрес"
  exit 1
fi

echo ""
log "Обнаружены сетевые настройки:"
echo "    Основной интерфейс: $MAIN_IFACE"
echo "    Локальный IP: $LOCAL_IP"
echo "    Localhost: 127.0.0.1"
echo ""

if ! ask_continue "Продолжить установку rublock (Debian 12)?"; then
  echo "Отменено."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

declare -a NEW_PKGS=()

log "[1/7] Проверка пакетов"
need_pkgs=(tor tor-geoipdb dnsmasq ipset iptables-persistent ca-certificates curl lua5.4 lua-socket lua-sec)

# Проверяем наличие obfs4proxy
if command -v obfs4proxy &>/dev/null || dpkg -s obfs4proxy &>/dev/null 2>&1; then
  log "obfs4proxy уже установлен"
else
  need_pkgs+=(obfs4proxy)
fi

for p in "${need_pkgs[@]}"; do
  if ! dpkg -s "$p" &>/dev/null; then
    NEW_PKGS+=("$p")
  fi
done

if ((${#NEW_PKGS[@]})); then
  log "Устанавливаю: ${NEW_PKGS[*]}"
  apt-get update
  apt-get install -y --no-install-recommends "${NEW_PKGS[@]}"
else
  log "Все необходимые пакеты уже установлены"
fi

log "[2/7] Подготовка директорий и скриптов"
install -d /usr/local/lib/rublock /usr/local/bin /etc/rublock

# Копируем lua скрипт
if [[ -f "$(dirname "$0")/rublupdate.lua" ]]; then
  install -m 0755 "$(dirname "$0")/rublupdate.lua" /usr/local/lib/rublock/rublupdate.lua
else
  err "Не найден rublupdate.lua"
  exit 1
fi

log "[3/7] Создание скрипта обновления (с IP: $LOCAL_IP)"

cat > /usr/local/bin/rublock-update.sh << 'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/lib/rublock/rublupdate.lua"

LUA_BIN="$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)"

if [[ -z "$LUA_BIN" ]]; then
  echo "Не найден исполняемый файл lua. Установите пакет lua5.4."
  exit 1
fi

if [[ ! -x "$LUA_SCRIPT" ]]; then
  echo "Не найден $LUA_SCRIPT. Запустите install_debian12.sh."
  exit 1
fi

install -d "$DATA_DIR"
touch "$DATA_DIR/runblock.dnsmasq" "$DATA_DIR/runblock.ipset" 2>/dev/null || true

echo "[rublock] Обновление списков"
if ! "$LUA_BIN" "$LUA_SCRIPT"; then
  echo "[rublock] Ошибка генерации списков"
  exit 1
fi

echo "[rublock] Создание наборов ipset"
ipset create rublack-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true
ipset create rublack-ip hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true

ipset flush rublack-ip 2>/dev/null || true
ipset flush rublack-dns 2>/dev/null || true

if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
  echo "[rublock] Загрузка IP-адресов в ipset"
  ipset restore -! <"$DATA_DIR/runblock.ipset" 2>/dev/null || true
fi

echo "[rublock] Применение правил iptables"
# Проверяем и добавляем правило только ОДИН раз (объединённое)
if ! iptables -t nat -C PREROUTING -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040
fi

if ! iptables -t nat -C PREROUTING -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040
fi

if ! iptables -t nat -C OUTPUT -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040
fi

if ! iptables -t nat -C OUTPUT -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040
fi

# Сохраняем правила
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

echo "[rublock] Перезагрузка dnsmasq (Tor НЕ перезагружается)"
systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq || true

echo "[rublock] Готово"
UPDATEEOF

chmod +x /usr/local/bin/rublock-update.sh

log "[4/7] Конфигурация dnsmasq"
cat > /etc/dnsmasq.d/rublock.conf << EOF
# rublock configuration
# Автосгенерировано: $(date)
# Локальный IP: $LOCAL_IP

# Слушать на локальных адресах
listen-address=127.0.0.1
listen-address=$LOCAL_IP
bind-interfaces

# Не использовать /etc/resolv.conf
no-resolv

# Upstream DNS серверы
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1

# rublock списки
conf-file=/etc/rublock/runblock.dnsmasq
ipset=/onion/rublack-dns
server=/onion/127.0.0.1#9053
EOF

log "[5/7] Конфигурация Tor (IP: $LOCAL_IP)"

# Удаляем старые конфиги
rm -f /etc/tor/torrc.d/rublock.conf /etc/tor/torrc.d/rublock.bridges 2>/dev/null || true

# Создаём оптимизированный конфиг Tor
cat > /etc/tor/torrc << EOF
# Tor configuration for rublock
# Автосгенерировано: $(date)
# Локальный IP: $LOCAL_IP

User debian-tor
DataDirectory /var/lib/tor
PidFile /run/tor/tor.pid

# Виртуальные адреса
VirtualAddrNetworkIPv4 10.254.0.0/16
AutomapHostsOnResolve 1

# SOCKS прокси (пассивный, без изоляции)
SocksPort 127.0.0.1:9050
SocksPort $LOCAL_IP:9050

# TransPort для rublock (БЕЗ избыточной изоляции)
TransPort 127.0.0.1:9040
TransPort $LOCAL_IP:9040

# DNS через Tor
DNSPort 127.0.0.1:9053
DNSPort $LOCAL_IP:9053

# Запрет быть Exit-нодой
ExitPolicy reject *:*
ExitRelay 0

# Исключаем страны СНГ
ExcludeNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
ExcludeExitNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
StrictNodes 1

# IPv6 поддержка
ClientUseIPv6 1
ClientUseIPv4 1
ClientPreferIPv6ORPort 1

# Логирование
Log notice file /var/log/tor/notices.log

# === ОПТИМИЗАЦИЯ ===
NumEntryGuards 3
CircuitBuildTimeout 60
MaxCircuitDirtiness 600
NewCircuitPeriod 30
CircuitStreamTimeout 60
MaxMemInQueues 512 MB
AvoidDiskWrites 1

# Мосты (раскомментируйте если нужны)
# UseBridges 1
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# Bridge obfs4 193.11.166.194:27015 2D82C2E354D531A68469ADF7F878FA6060C6BACA cert=4TLQPJrTSaDffMK7Nbao6LC7G9OW/NHkUwIdjLSS3KYf0Nv4/nQiiI8dY2TcsQx01NniOg iat-mode=0
EOF

# Создаём директорию для логов
install -d -o debian-tor -g debian-tor /var/log/tor

log "[6/7] Unit-файлы systemd"

cat > /etc/systemd/system/rublock-update.service << 'EOF'
[Unit]
Description=Обновление списков rublock и применение iptables/ipset
Wants=network-online.target
After=network-online.target tor.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rublock-update.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rublock-update.timer << 'EOF'
[Unit]
Description=Периодический запуск rublock-update

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable rublock-update.timer

log "[7/7] Запуск сервисов"

# Останавливаем конфликтующие сервисы
systemctl stop named 2>/dev/null || true
systemctl stop bind9 2>/dev/null || true
systemctl disable named 2>/dev/null || true
systemctl disable bind9 2>/dev/null || true

# Перезапускаем сервисы
systemctl restart dnsmasq
systemctl restart tor

# Ждём запуска Tor
sleep 5

# Запускаем обновление списков
if /usr/local/bin/rublock-update.sh; then
  log "Первичный запуск rublock-update выполнен успешно"
else
  warn "Первичный запуск rublock-update завершился с ошибкой. Проверьте: sudo rublock-update.sh"
fi

# Запускаем таймер
systemctl start rublock-update.timer

echo ""
log "=========================================="
log "Установка завершена!"
log "=========================================="
echo ""
echo "Настройки:"
echo "  Локальный IP: $LOCAL_IP"
echo "  SOCKS прокси: $LOCAL_IP:9050 и 127.0.0.1:9050"
echo "  TransPort: $LOCAL_IP:9040 и 127.0.0.1:9040"
echo "  DNS Tor: $LOCAL_IP:9053 и 127.0.0.1:9053"
echo ""
echo "Проверка:"
echo "  curl --socks5 127.0.0.1:9050 https://check.torproject.org/api/ip"
echo "  dig @127.0.0.1 -p 9053 google.com"
echo ""
echo "Списки обновляются ежедневно в 05:00"
echo ""
