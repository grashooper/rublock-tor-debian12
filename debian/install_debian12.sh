#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ask_continue() {
  read -r -p "$1 [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

log()  { echo -e "${GREEN}${BOLD}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[⚠]${NC} $*"; }
err()  { echo -e "${RED}${BOLD}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}${BOLD}[ℹ]${NC} $*"; }

print_header() {
    local text="$1"
    local width=70
    echo ""
    echo -e "${CYAN}${BOLD}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    printf "${CYAN}${BOLD}│${NC} %-${width}s ${CYAN}${BOLD}│${NC}\n" "$text"
    echo -e "${CYAN}${BOLD}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo ""
}

# Автоопределение локального IP (не localhost)
get_local_ip() {
  ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | grep -v '^172\.17\.' | grep -v '^172\.18\.' | head -1
}

# Получаем имя основного интерфейса
get_main_interface() {
  ip route | grep default | awk '{print $5}' | head -1
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "Запустите скрипт от root: sudo bash $0"
  exit 1
fi

# Определяем IP-адреса
LOCAL_IP=$(get_local_ip)
MAIN_IFACE=$(get_main_interface)

if [[ -z "$LOCAL_IP" ]]; then
  err "Не удалось определить локальный IP-адрес"
  exit 1
fi

print_header "rublock-tor Installer for Debian 12"

info "Обнаружены сетевые настройки:"
echo -e "    Основной интерфейс: ${BOLD}$MAIN_IFACE${NC}"
echo -e "    Локальный IP: ${BOLD}$LOCAL_IP${NC}"
echo -e "    Localhost: ${BOLD}127.0.0.1${NC}"
echo ""

if ! ask_continue "Продолжить установку rublock?"; then
  echo "Отменено."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

declare -a NEW_PKGS=()

print_header "Шаг 1/7: Проверка пакетов"

need_pkgs=(tor tor-geoipdb dnsmasq ipset iptables-persistent ca-certificates curl lua5.4 lua-socket lua-sec)

# Проверяем наличие obfs4proxy
if command -v obfs4proxy &>/dev/null || dpkg -s obfs4proxy &>/dev/null 2>&1; then
  log "obfs4proxy уже установлен"
else
  need_pkgs+=(obfs4proxy)
fi

for p in "${need_pkgs[@]}"; do
  if ! dpkg -s "$p" &>/dev/null 2>&1; then
    NEW_PKGS+=("$p")
  fi
done

if ((${#NEW_PKGS[@]})); then
  info "Устанавливаю: ${NEW_PKGS[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${NEW_PKGS[@]}"
  log "Установлено пакетов: ${#NEW_PKGS[@]}"
else
  log "Все необходимые пакеты уже установлены"
fi

print_header "Шаг 2/7: Подготовка директорий"

install -d /usr/local/lib/rublock /usr/local/bin /etc/rublock

# Копируем lua скрипт
if [[ -f "$(dirname "$0")/rublupdate.lua" ]]; then
  install -m 0755 "$(dirname "$0")/rublupdate.lua" /usr/local/lib/rublock/rublupdate.lua
  log "Lua скрипт установлен"
else
  err "Не найден rublupdate.lua в директории скрипта"
  exit 1
fi

print_header "Шаг 3/7: Создание скрипта обновления"

cat > /usr/local/bin/rublock-update.sh << 'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/lib/rublock/rublupdate.lua"

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_success() { echo -e "${GREEN}${BOLD}[✓]${NC} $*"; }
log_info() { echo -e "${BOLD}[ℹ]${NC} $*"; }
log_error() { echo -e "${RED}${BOLD}[✗]${NC} $*"; }

LUA_BIN="$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)"

if [[ -z "$LUA_BIN" ]]; then
  log_error "Lua не найден. Установите: apt install lua5.4"
  exit 1
fi

if [[ ! -x "$LUA_SCRIPT" ]]; then
  log_error "Lua скрипт не найден: $LUA_SCRIPT"
  exit 1
fi

install -d "$DATA_DIR"
touch "$DATA_DIR/runblock.dnsmasq" "$DATA_DIR/runblock.ipset" 2>/dev/null || true

log_info "Обновление списков блокировок..."
if ! "$LUA_BIN" "$LUA_SCRIPT"; then
  log_error "Ошибка при выполнении Lua скрипта"
  exit 1
fi

log_info "Подготовка ipset наборов..."
# Удаляем старые наборы для чистой загрузки
ipset destroy rublock-ip 2>/dev/null || true
ipset destroy rublock-ip-tmp 2>/dev/null || true
ipset destroy rublock-dns 2>/dev/null || true

if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
  log_info "Загрузка IP-адресов через ipset restore..."
  
  if ipset restore < "$DATA_DIR/runblock.ipset" 2>&1 | tee /tmp/ipset-load.log; then
    log_success "IP-адреса загружены успешно"
  else
    log_error "Ошибка загрузки ipset:"
    cat /tmp/ipset-load.log
    exit 1
  fi
else
  log_error "Файл ipset не найден: $DATA_DIR/runblock.ipset"
  exit 1
fi

# Создаём rublock-dns если не существует
ipset create rublock-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true

# Подсчитываем загруженные IP
IP_COUNT=$(ipset list rublock-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)

# Форматируем число с разделителями тысяч
if [[ $IP_COUNT -gt 0 ]]; then
  IP_COUNT_FORMATTED=$(echo "$IP_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
  log_success "Загружено IP-адресов: $IP_COUNT_FORMATTED"
else
  log_success "Загружено IP-адресов: 0"
fi

log_info "Применение правил iptables..."

# Применяем правила ТОЛЬКО для TCP (покрывает HTTPS, HTTP, большинство сайтов)
# PREROUTING - для трафика из локальной сети
if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040
fi

if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040
fi

# OUTPUT - для трафика с самого сервера
if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040
fi

if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040
fi

# Сохраняем правила
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

RULES_COUNT=$(iptables -t nat -L -n 2>/dev/null | grep -c "rublock" || echo 0)
log_success "Активных правил iptables: $RULES_COUNT"

log_info "Перезагрузка dnsmasq..."
if systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null; then
  log_success "dnsmasq перезагружен"
else
  log_error "Не удалось перезагрузить dnsmasq"
fi

# Tor НЕ перезагружаем - он работает пассивно через TransPort
log_info "Tor: перезагрузка не требуется (работает пассивно)"

DOMAIN_COUNT=$(wc -l < "$DATA_DIR/runblock.dnsmasq" 2>/dev/null || echo 0)
DOMAIN_COUNT_FORMATTED=$(echo "$DOMAIN_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
RULES_COUNT_FORMATTED=$(echo "$RULES_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Обновление завершено успешно"
echo "═══════════════════════════════════════════════════════════════════"
echo "  Доменов:        $(printf '%12s' "$DOMAIN_COUNT_FORMATTED")"
echo "  IP/Подсетей:    $(printf '%12s' "$IP_COUNT_FORMATTED")"
echo "  iptables:       $(printf '%12s' "$RULES_COUNT_FORMATTED") правил"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
UPDATEEOF

chmod +x /usr/local/bin/rublock-update.sh
log "Скрипт обновления создан: /usr/local/bin/rublock-update.sh"

print_header "Шаг 4/7: Конфигурация dnsmasq"

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

# Upstream DNS серверы (Google, Cloudflare)
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1

# Кэш DNS
cache-size=10000

# rublock списки
conf-file=/etc/rublock/rublock.dnsmasq

# .onion домены через Tor DNS
ipset=/onion/rublock-dns
server=/onion/127.0.0.1#9053
EOF

log "Конфигурация dnsmasq создана"

print_header "Шаг 5/7: Конфигурация Tor"

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

# Виртуальные адреса для .onion
VirtualAddrNetworkIPv4 10.254.0.0/16
AutomapHostsOnResolve 1

# SOCKS прокси (пассивный режим)
SocksPort 127.0.0.1:9050
SocksPort $LOCAL_IP:9050

# TransPort для rublock (БЕЗ изоляции для производительности)
TransPort 127.0.0.1:9040
TransPort $LOCAL_IP:9040

# DNS через Tor
DNSPort 127.0.0.1:9053
DNSPort $LOCAL_IP:9053

# Запрет быть Exit-нодой
ExitPolicy reject *:*
ExitRelay 0

# Исключаем страны СНГ и соседние
ExcludeNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
ExcludeExitNodes {RU},{BY},{KG},{KZ},{UZ},{TJ},{TM},{TR},{AZ},{AM},{UA}
StrictNodes 1

# Поддержка IPv4 и IPv6
ClientUseIPv6 1
ClientUseIPv4 1
ClientPreferIPv6ORPort 1

# Логирование
Log notice file /var/log/tor/notices.log

# ═══ ОПТИМИЗАЦИЯ ПРОИЗВОДИТЕЛЬНОСТИ ═══
# Количество Guard-нод
NumEntryGuards 3

# Таймауты построения цепочек
CircuitBuildTimeout 60
LearnCircuitBuildTimeout 1

# Переиспользование цепочек (снижает нагрузку)
MaxCircuitDirtiness 600
NewCircuitPeriod 30

# Таймауты потоков
CircuitStreamTimeout 60
CircuitIdleTimeout 3600

# Ограничение памяти
MaxMemInQueues 512 MB

# Отключение записи на диск
AvoidDiskWrites 1

# ═══ МОСТЫ (раскомментируйте если нужны для обхода блокировок Tor) ═══
# UseBridges 1
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# Bridge obfs4 193.11.166.194:27015 2D82C2E354D531A68469ADF7F878FA6060C6BACA cert=4TLQPJrTSaDffMK7Nbao6LC7G9OW/NHkUwIdjLSS3KYf0Nv4/nQiiI8dY2TcsQx01NniOg iat-mode=0
# Bridge obfs4 193.11.166.194:27020 86A22470DDD2C97F7289B88844C2BF6A8A0346FA cert=XQKM1FLDw2jkDYOOV8hcGTw4a4zLfPJ8PBN3j2GcaQq5QOwx8e2jAhRB24D+uZf/T5OqJA iat-mode=0
# Bridge obfs4 85.31.186.98:443 011F2599C0E9B27EE74B353155E244813763C3E5 cert=ayq0XzCwhpdysn5o0EyDUbmSOx3X/oTEbzDMvczHOdBJKlvIdHHLJGkZARtT4dcBFArPPg iat-mode=0
EOF

# Создаём директорию для логов
install -d -o debian-tor -g debian-tor /var/log/tor
log "Конфигурация Tor создана"

print_header "Шаг 6/7: Настройка systemd"

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
# Запуск ежедневно в 05:00 с случайной задержкой до 30 минут
OnCalendar=*-*-* 05:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable rublock-update.timer
log "Systemd unit-файлы созданы и активированы"

print_header "Шаг 7/7: Запуск сервисов"

# Останавливаем конфликтующие DNS сервисы
for svc in named bind9; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    info "Останавливаю конфликтующий сервис: $svc"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  fi
done

info "Перезапуск dnsmasq..."
systemctl restart dnsmasq

info "Перезапуск Tor..."
systemctl restart tor

# Ждём запуска Tor
info "Ожидание подключения Tor к сети (5 сек)..."
sleep 5

# Запускаем первичное обновление списков
info "Запуск первичного обновления списков блокировок..."
echo ""

if /usr/local/bin/rublock-update.sh; then
  log "Первичный запуск успешно завершён"
else
  warn "Первичный запуск завершился с ошибкой"
  warn "Проверьте вручную: sudo /usr/local/bin/rublock-update.sh"
fi

# Запускаем таймер обновлений
systemctl start rublock-update.timer
log "Таймер автообновления запущен"

print_header "Установка завершена успешно!"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${BOLD}Настройки rublock${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BOLD}Сеть:${NC}"
echo "    Локальный IP:        $LOCAL_IP"
echo "    Интерфейс:           $MAIN_IFACE"
echo ""
echo -e "  ${BOLD}Tor прокси:${NC}"
echo "    SOCKS:               127.0.0.1:9050, $LOCAL_IP:9050"
echo "    TransPort:           127.0.0.1:9040, $LOCAL_IP:9040"
echo "    DNS:                 127.0.0.1:9053, $LOCAL_IP:9053"
echo ""
echo -e "  ${BOLD}Автообновление:${NC}"
echo "    Расписание:          Ежедневно в 05:00"
echo "    Ручной запуск:       sudo /usr/local/bin/rublock-update.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "  ${BOLD}Проверка работы${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "  1. Проверка подключения к Tor:"
echo -e "     ${CYAN}curl --socks5 127.0.0.1:9050 https://check.torproject.org/api/ip${NC}"
echo ""
echo "  2. Проверка DNS через Tor:"
echo -e "     ${CYAN}dig @127.0.0.1 -p 9053 google.com${NC}"
echo ""
echo "  3. Просмотр логов Tor:"
echo -e "     ${CYAN}sudo journalctl -u tor -f${NC}"
echo ""
echo "  4. Статус ipset:"
echo -e "     ${CYAN}sudo ipset list rublock-ip | head${NC}"
echo ""
echo "  5. Правила iptables:"
echo -e "     ${CYAN}sudo iptables -t nat -L -n -v | grep rublock${NC}"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""
