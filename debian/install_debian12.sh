#!/bin/bash

#===============================================================================
# rublock-tor Installer for Debian 12
# Установка и настройка rublock с Tor для обхода блокировок
#===============================================================================

set -e

#===============================================================================
# Цвета и символы для вывода
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SUCCESS="[✓]"
ERROR="[✗]"
INFO="[ℹ]"
WARNING="[⚠]"

#===============================================================================
# Функции логирования
#===============================================================================
log_success() {
    echo -e "${GREEN}${SUCCESS}${NC} $1"
}

log_error() {
    echo -e "${RED}${ERROR}${NC} $1"
}

log_info() {
    echo -e "${BLUE}${INFO}${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}${WARNING}${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────────────────┐${NC}"
    printf "${BLUE}│${NC} %-68s ${BLUE}│${NC}\n" "$1"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────────────┘${NC}\n"
}

#===============================================================================
# Проверка прав root
#===============================================================================
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен быть запущен с правами root"
   exit 1
fi

#===============================================================================
# Определение сетевых параметров
#===============================================================================
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
MAIN_IP=$(ip -4 addr show "$MAIN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
LOCALHOST="127.0.0.1"

# Валидация IP-адреса
if ! [[ "$MAIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Не удалось определить корректный IP-адрес"
    exit 1
fi

#===============================================================================
# Переменные конфигурации
#===============================================================================
RUBLOCK_DIR="/etc/rublock"
RUBLOCK_SCRIPT="/usr/local/bin/rublock.lua"
RUBLOCK_UPDATE_SCRIPT="/usr/local/bin/rublock-update.sh"
RUBLOCK_DNSMASQ_FILE="${RUBLOCK_DIR}/rublock.dnsmasq"
LOG_FILE="/var/log/rublock-update.log"
DNSMASQ_CONF="/etc/dnsmasq.d/rublock.conf"
TOR_CONF="/etc/tor/torrc"

#===============================================================================
# Информация о системе
#===============================================================================
clear
print_header "rublock-tor Installer for Debian 12"

log_info "Обнаружены сетевые настройки:"
echo "    Основной интерфейс: $MAIN_INTERFACE"
echo "    Локальный IP: $MAIN_IP"
echo "    Localhost: $LOCALHOST"
echo ""

read -p "Продолжить установку rublock? [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Установка отменена"
    exit 0
fi

#===============================================================================
# Шаг 1: Установка пакетов
#===============================================================================
print_header "Шаг 1/7: Проверка пакетов"

PACKAGES="tor tor-geoipdb dnsmasq iptables-persistent lua5.4 lua-socket lua-sec obfs4proxy"

log_info "Устанавливаю: $PACKAGES"
apt-get update -qq
apt-get install -y --no-install-recommends $PACKAGES

INSTALLED_COUNT=$(dpkg -l $PACKAGES 2>/dev/null | grep -c "^ii" || echo 0)
log_success "Установлено пакетов: $INSTALLED_COUNT"

#===============================================================================
# Шаг 2: Создание директорий и Lua скрипта
#===============================================================================
print_header "Шаг 2/7: Подготовка директорий"

# Создание директорий
mkdir -p "$RUBLOCK_DIR"
chmod 755 "$RUBLOCK_DIR"

# Создание пустого файла списков (чтобы dnsmasq мог запуститься)
touch "$RUBLOCK_DNSMASQ_FILE"
chmod 644 "$RUBLOCK_DNSMASQ_FILE"

# Создание Lua скрипта для парсинга списков
cat > "$RUBLOCK_SCRIPT" << 'EOF'
#!/usr/bin/env lua

local https = require("ssl.https")
local ltn12 = require("ltn12")

local SOURCES = {
    "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv",
    "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst"
}

local OUTPUT_FILE = "/etc/rublock/rublock.dnsmasq"
local TMP_FILE = "/tmp/rublock_domains.tmp"

local function download_file(url)
    local response = {}
    local _, status = https.request{
        url = url,
        sink = ltn12.sink.table(response),
        protocol = "tlsv1_2"
    }
    
    if status == 200 then
        return table.concat(response)
    else
        return nil
    end
end

local function extract_domains(content)
    local domains = {}
    local seen = {}
    
    for line in content:gmatch("[^\r\n]+") do
        -- Извлечение доменов из различных форматов
        for domain in line:gmatch("([%w%-%.]+%.[%w]+)") do
            domain = domain:lower():gsub("^www%.", "")
            if not seen[domain] and domain:match("%.") then
                seen[domain] = true
                table.insert(domains, domain)
            end
        end
    end
    
    return domains
end

local function main()
    print("Загрузка списков блокировок...")
    
    local all_domains = {}
    local seen = {}
    
    for _, url in ipairs(SOURCES) do
        print("Загрузка: " .. url)
        local content = download_file(url)
        
        if content then
            local domains = extract_domains(content)
            for _, domain in ipairs(domains) do
                if not seen[domain] then
                    seen[domain] = true
                    table.insert(all_domains, domain)
                end
            end
            print("  Найдено доменов: " .. #domains)
        else
            print("  ОШИБКА: не удалось загрузить")
        end
    end
    
    print("\nВсего уникальных доменов: " .. #all_domains)
    
    -- Запись в файл dnsmasq
    local file = io.open(TMP_FILE, "w")
    if not file then
        print("ОШИБКА: не удалось создать временный файл")
        os.exit(1)
    end
    
    file:write("# rublock domains list\n")
    file:write("# Generated: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    file:write("# Total domains: " .. #all_domains .. "\n\n")
    
    for _, domain in ipairs(all_domains) do
        file:write("server=/" .. domain .. "/127.0.0.1#9053\n")
    end
    
    file:close()
    
    -- Атомарная замена файла
    os.execute("mv " .. TMP_FILE .. " " .. OUTPUT_FILE)
    os.execute("chmod 644 " .. OUTPUT_FILE)
    
    print("Файл сохранён: " .. OUTPUT_FILE)
    print("Перезапуск dnsmasq...")
    os.execute("systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq")
    
    print("✓ Обновление завершено")
end

main()
EOF

chmod +x "$RUBLOCK_SCRIPT"
log_success "Lua скрипт установлен"

#===============================================================================
# Шаг 3: Создание скрипта обновления
#===============================================================================
print_header "Шаг 3/7: Создание скрипта обновления"

cat > "$RUBLOCK_UPDATE_SCRIPT" << EOF
#!/bin/bash
#
# rublock-update.sh - Скрипт обновления списков блокировок
#

LOGFILE="$LOG_FILE"
RUBLOCK_SCRIPT="$RUBLOCK_SCRIPT"

exec >> "\$LOGFILE" 2>&1

echo "==================================================="
echo "Запуск обновления: \$(date)"
echo "==================================================="

if [ -x "\$RUBLOCK_SCRIPT" ]; then
    "\$RUBLOCK_SCRIPT"
    EXIT_CODE=\$?
    
    if [ \$EXIT_CODE -eq 0 ]; then
        echo "✓ Обновление успешно завершено"
    else
        echo "✗ Ошибка обновления (код: \$EXIT_CODE)"
    fi
else
    echo "✗ ОШИБКА: скрипт \$RUBLOCK_SCRIPT не найден или не исполняем"
    exit 1
fi

echo ""
EOF

chmod +x "$RUBLOCK_UPDATE_SCRIPT"
log_success "Скрипт обновления создан: $RUBLOCK_UPDATE_SCRIPT"

#===============================================================================
# Шаг 4: Настройка dnsmasq
#===============================================================================
print_header "Шаг 4/7: Конфигурация dnsmasq"

# Создание резервной копии
if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%Y%m%d_%H%M%S)
fi

# Создание конфигурации rublock
cat > "$DNSMASQ_CONF" << EOF
# rublock configuration
# Автосгенерировано: $(date)
# Локальный IP: $MAIN_IP

# Слушать на локальных адресах
listen-address=127.0.0.1
listen-address=$MAIN_IP
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
conf-file=$RUBLOCK_DNSMASQ_FILE

# .onion домены через Tor DNS
server=/onion/127.0.0.1#9053
EOF

log_success "Конфигурация dnsmasq создана"

#===============================================================================
# Шаг 5: Настройка Tor
#===============================================================================
print_header "Шаг 5/7: Конфигурация Tor"

# Создание резервной копии
if [ -f "$TOR_CONF" ]; then
    cp "$TOR_CONF" "${TOR_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
fi

# Создание конфигурации Tor
cat > "$TOR_CONF" << 'EOF'
# rublock Tor configuration

# SOCKS прокси
SOCKSPort 9050

# DNS порт для резолвинга через Tor
DNSPort 127.0.0.1:9053

# Автоматическое определение портов
AutomapHostsOnResolve 1

# Виртуальная сеть для .onion
VirtualAddrNetworkIPv4 10.192.0.0/10

# Логирование
Log notice file /var/log/tor/notices.log

# Директории данных
DataDirectory /var/lib/tor

# Использование мостов (опционально, раскомментируйте при необходимости)
# UseBridges 1
# ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
# Bridge obfs4 [IP:PORT] [FINGERPRINT] cert=[CERT] iat-mode=0

# Настройки безопасности
RunAsDaemon 1
User debian-tor
EOF

log_success "Конфигурация Tor создана"

#===============================================================================
# Шаг 6: Настройка systemd
#===============================================================================
print_header "Шаг 6/7: Настройка systemd"

# Создание systemd service
cat > /etc/systemd/system/rublock-update.service << EOF
[Unit]
Description=rublock List Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUBLOCK_UPDATE_SCRIPT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Создание systemd timer
cat > /etc/systemd/system/rublock-update.timer << EOF
[Unit]
Description=rublock Update Timer
Requires=rublock-update.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Перезагрузка systemd и активация таймера
systemctl daemon-reload
systemctl enable rublock-update.timer
systemctl start rublock-update.timer

log_success "Systemd unit-файлы созданы и активированы"

#===============================================================================
# Шаг 7: Запуск сервисов
#===============================================================================
print_header "Шаг 7/7: Запуск сервисов"

# Остановка конфликтующих сервисов
log_info "Проверка конфликтующих сервисов..."

# Проверка и остановка systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    log_info "Останавливаю systemd-resolved..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    systemctl mask systemd-resolved
    
    # Восстановление /etc/resolv.conf
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    log_success "systemd-resolved отключён"
fi

# Проверка и остановка BIND (named)
if systemctl is-active --quiet named; then
    log_info "Останавливаю конфликтующий сервис: named"
    systemctl stop named
    systemctl disable named
    systemctl mask named
    log_success "BIND (named) отключён"
fi

# Даём время освободиться порту 53
sleep 2

# Остановка всех сервисов перед запуском
systemctl stop dnsmasq tor 2>/dev/null || true

# Запуск dnsmasq
log_info "Запуск dnsmasq..."
systemctl restart dnsmasq

if ! systemctl is-active --quiet dnsmasq; then
    log_error "dnsmasq не запустился! Логи:"
    journalctl -xeu dnsmasq.service --no-pager -n 30
    exit 1
fi
log_success "dnsmasq запущен"

# Проверка порта 53
if ! ss -tulpn | grep -q ":53.*dnsmasq"; then
    log_warning "dnsmasq не слушает на порту 53"
    ss -tulpn | grep :53
fi

# Запуск Tor
log_info "Запуск Tor..."
systemctl restart tor

if ! systemctl is-active --quiet tor; then
    log_error "Tor не запустился! Логи:"
    journalctl -xeu tor.service --no-pager -n 30
    exit 1
fi
log_success "Tor запущен"

# Первое обновление списков
log_info "Выполняю первое обновление списков..."
if "$RUBLOCK_UPDATE_SCRIPT"; then
    log_success "Списки успешно загружены"
else
    log_warning "Ошибка при загрузке списков (будет повторено по расписанию)"
fi

#===============================================================================
# Завершение установки
#===============================================================================
echo ""
print_header "Установка завершена!"

echo -e "${GREEN}✓ rublock-tor успешно установлен и настроен${NC}\n"

echo "Информация о сервисах:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
systemctl status dnsmasq --no-pager -l | head -n 3
echo ""
systemctl status tor --no-pager -l | head -n 3
echo ""
systemctl status rublock-update.timer --no-pager -l | head -n 3
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Конфигурация:"
echo "  • DNS сервер: 127.0.0.1 и $MAIN_IP"
echo "  • Tor SOCKS: 127.0.0.1:9050"
echo "  • Tor DNS: 127.0.0.1:9053"
echo "  • Списки: $RUBLOCK_DNSMASQ_FILE"
echo "  • Логи: $LOG_FILE"
echo ""

echo "Полезные команды:"
echo "  sudo $RUBLOCK_UPDATE_SCRIPT          # Обновить списки вручную"
echo "  sudo systemctl status dnsmasq         # Статус dnsmasq"
echo "  sudo systemctl status tor             # Статус Tor"
echo "  sudo journalctl -f -u dnsmasq         # Логи dnsmasq в реальном времени"
echo "  tail -f $LOG_FILE                     # Логи обновлений"
echo "  dig @127.0.0.1 google.com             # Тест DNS"
echo ""

echo "Настройка клиентов:"
echo "  В настройках сети укажите DNS: $MAIN_IP"
echo ""

log_info "Рекомендуется перезагрузить систему для проверки автозапуска сервисов"

exit 0
