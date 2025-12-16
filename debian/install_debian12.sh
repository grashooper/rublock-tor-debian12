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
  # Получаем IP основного интерфейса (исключаем docker, lo, veth)
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

if ! ask_continue "Продолжить установку privacy-gateway (Debian 12)?"; then
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
install -d /usr/local/lib/tor-gateway /usr/local/bin /etc/tor-gateway

# Копируем lua скрипт
if [[ -f "$(dirname "$0")/rublupdate.lua" ]]; then
  install -m 0755 "$(dirname "$0")/rublupdate.lua" /usr/local/lib/tor-gateway/rublupdate.lua
else
  err "Не найден rublupdate.lua"
  exit 1
fi

log "[3/7] Создание скрипта обновления (с IP: $LOCAL_IP)"

cat > /usr/local/bin/tor-gateway-update.sh << 'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/tor-gateway"
LUA_SCRIPT="/usr/local/lib/tor-gateway/rublupdate.lua"

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

echo "[tor-gateway] Обновление списков"
if ! "$LUA_BIN" "$LUA_SCRIPT"; then
  echo "[tor-gateway] Ошибка генерации списков"
  exit 1
fi

echo "[tor-gateway] Создание наборов ipset"
ipset create tor-gateway-dns hash:ip family inet hashsize 65536 maxelem 1048576 -exist 2>/dev/null || true
ipset create tor-gateway-ip hash:ip family inet hashsize 65536 maxelem 1048576 -exist 2>/dev/null || true
ipset create tor-gateway-ip-tmp hash:ip family inet hashsize 65536 maxelem 1048576 -exist 2>/dev/null || true

ipset flush tor-gateway-ip 2>/dev/null || true
ipset flush tor-gateway-dns 2>/dev/null || true
ipset flush tor-gateway-ip-tmp 2>/dev/null || true

if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
  echo "[tor-gateway] Загрузка IP-адресов в ipset"
  ipset restore -! <"$DATA_DIR/runblock.ipset" 2>/dev/null || true
fi

echo "[tor-gateway] Применение правил iptables"
for chain in PREROUTING OUTPUT; do
  for proto in tcp udp; do
    for setname in tor-gateway-dns tor-gateway-ip; do
      if ! iptables -t nat -C "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040
      fi
    done
  done
done

echo "[tor-gateway] Перезагрузка сервисов"
systemctl reload tor 2>/dev/null || systemctl restart tor || true
systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq || true

echo "[tor-gateway] Готово"
UPDATEEOF

chmod +x /usr/local/bin/tor-gateway-update.sh

log "[4/7] Конфигурация dnsmasq"
cat > /etc/dnsmasq.d/tor-gateway.conf << EOF
# tor-gateway configuration
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

# tor-gateway списки
conf-file=/etc/tor-gateway/runblock.dnsmasq
ipset=/onion/tor-gateway-dns
server=/onion/127.0.0.1#9053
EOF

log "[5/7] Конфигурация Tor (IP: $LOCAL_IP)"

# Удаляем старые конфиги tor-gateway в torrc.d
rm -f /etc/tor/torrc.d/tor-gateway.conf /etc/tor/torrc.d/tor-gateway.bridges 2>/dev/null || true

# Создаём основной конфиг Tor
cat > /etc/tor/torrc << EOF
# Tor configuration for tor-gateway
# Автосгенерировано: $(date)
# Локальный IP: $LOCAL_IP

User debian-tor
DataDirectory /var/lib/tor
PidFile /run/tor/tor.pid

# Виртуальные адреса для .onion
VirtualAddrNetworkIPv4 10.254.0.0/16
AutomapHostsOnResolve 1

# SOCKS прокси
SocksPort 127.0.0.1:9050
SocksPort $LOCAL_IP:9050

# Transparent Proxy для rublock
TransPort 127.0.0.1:9040 IsolateClientAddr
TransPort $LOCAL_IP:9040 IsolateClientAddr

# DNS через Tor
DNSPort 127.0.0.1:9053
DNSPort $LOCAL_IP:9053

# Запрет быть Exit-нодой
ExitPolicy reject *:*
ExitPolicy reject6 *:*
ExitRelay 0

# Исключаем страны СНГ и соседние
ExcludeNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
ExcludeExitNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
StrictNodes 1

# IPv6 поддержка
ClientUseIPv6 1
ClientUseIPv4 1
ClientPreferIPv6ORPort 1

# Логирование
Log notice file /var/log/tor/notices.log

# Опционально: obfs4 мосты (раскомментируйте если нужны)
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# UseBridges 1
# Bridge obfs4 IP:PORT FINGERPRINT cert=CERT iat-mode=0
EOF

# Создаём директорию для логов
install -d -o debian-tor -g debian-tor /var/log/tor

log "[6/7] Unit-файлы systemd"

cat > /etc/systemd/system/tor-gateway-update.service << 'EOF'
[Unit]
Description=Обновление списков tor-gateway и применение iptables/ipset
Wants=network-online.target
After=network-online.target tor.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tor-gateway-update.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/tor-gateway-update.timer << 'EOF'
[Unit]
Description=Периодический запуск tor-gateway-update

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable tor-gateway-update.timer

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
sleep 3

# Запускаем обновление списков
if /usr/local/bin/tor-gateway-update.sh; then
  log "Первичный запуск tor-gateway-update выполнен успешно"
else
  warn "Первичный запуск tor-gateway-update завершился с ошибкой. Проверьте: sudo tor-gateway-update.sh"
fi

# Запускаем таймер
systemctl start tor-gateway-update.timer

echo ""
log "=========================================="
log "Установка tor-gateway завершена!"
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
