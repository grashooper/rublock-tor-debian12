#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/tor-gateway"
LUA_SCRIPT="/usr/local/lib/tor-gateway/rublupdate.lua"

# Цвета для bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}${BOLD}[ℹ]${NC} $*"
}

log_success() {
    echo -e "${GREEN}${BOLD}[✓]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}${BOLD}[⚠]${NC} $*"
}

log_error() {
    echo -e "${RED}${BOLD}[✗]${NC} $*"
}

print_header() {
    local text="$1"
    local width=70
    echo ""
    echo -e "${CYAN}${BOLD}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    printf "${CYAN}${BOLD}│${NC} %-${width}s ${CYAN}${BOLD}│${NC}\n" "$text"
    echo -e "${CYAN}${BOLD}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo ""
}

# Проверка Lua
LUA_BIN="$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)"

if [[ -z "$LUA_BIN" ]]; then
    log_error "Lua not found. Install lua5.4 package."
    exit 1
fi

if [[ ! -x "$LUA_SCRIPT" ]]; then
    log_error "Lua script not found: $LUA_SCRIPT"
    exit 1
fi

install -d "$DATA_DIR"
touch "$DATA_DIR/runblock.dnsmasq" "$DATA_DIR/runblock.ipset" 2>/dev/null || true

# Запуск Lua скрипта
print_header "Starting List Update"
log_info "Executing: $LUA_BIN $LUA_SCRIPT"
echo ""

if ! "$LUA_BIN" "$LUA_SCRIPT"; then
    echo ""
    log_error "Lua script failed with exit code $?"
    exit 1
fi

echo ""
print_header "Applying iptables and ipset Rules"

# Удаление старых iptables правил
log_info "Removing old iptables rules..."
for chain in PREROUTING OUTPUT; do
    while iptables -t nat -D "$chain" -p tcp -m set --match-set tor-gateway-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; do :; done
    while iptables -t nat -D "$chain" -p tcp -m set --match-set tor-gateway-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; do :; done
    while iptables -t nat -D "$chain" -p udp -m set --match-set tor-gateway-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; do :; done
    while iptables -t nat -D "$chain" -p udp -m set --match-set tor-gateway-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; do :; done
done

# Удаление старых ipset
log_info "Removing old ipset..."
ipset destroy tor-gateway-ip 2>/dev/null || true
ipset destroy tor-gateway-ip-tmp 2>/dev/null || true
ipset destroy tor-gateway-dns 2>/dev/null || true

# Загрузка ipset из файла
if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
    log_info "Loading ipset configuration..."

    # Показываем первые строки для диагностики
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log_info "First 5 lines of ipset config:"
        head -5 "$DATA_DIR/runblock.ipset"
    fi

    # Загружаем с показом ошибок
    if ipset restore < "$DATA_DIR/runblock.ipset" 2>&1 | tee /tmp/ipset-errors.log | grep -qE "(Error|failed)"; then
        log_error "Failed to load ipset. Errors:"
        cat /tmp/ipset-errors.log
        exit 1
    else
        log_success "ipset loaded successfully"
    fi
else
    log_error "ipset config file not found or empty: $DATA_DIR/runblock.ipset"
    exit 1
fi

# Создание tor-gateway-dns если не существует
ipset create tor-gateway-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true

# Подсчёт загруженных IP
IP_COUNT=$(ipset list tor-gateway-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)
if [[ $IP_COUNT -eq 0 ]]; then
    log_warning "No IPs loaded into ipset!"
    log_info "Checking ipset contents..."
    ipset list tor-gateway-ip | head -20
else
    log_success "Loaded $IP_COUNT IP addresses/subnets into ipset"
fi

# Применение iptables правил
log_info "Applying iptables rules..."
for chain in PREROUTING OUTPUT; do
    for proto in tcp udp; do
        for setname in tor-gateway-dns tor-gateway-ip; do
            if ! iptables -t nat -C "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040 2>/dev/null; then
                iptables -t nat -A "$chain" -p "$proto" -m set --match-set "$setname" dst -j REDIRECT --to-ports 9040
            fi
        done
    done
done

RULES_COUNT=$(iptables -t nat -L PREROUTING -n | grep -c tor-gateway || echo 0)
log_success "Applied $RULES_COUNT iptables rules"

# Сохранение правил
log_info "Saving iptables rules..."
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# Перезагрузка сервисов
print_header "Reloading Services"

log_info "Reloading Tor..."
systemctl reload tor 2>/dev/null || systemctl restart tor || log_warning "Tor reload failed"

log_info "Reloading dnsmasq..."
systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq || log_warning "dnsmasq reload failed"

# Финальная статистика
DOMAIN_COUNT=$(wc -l < "$DATA_DIR/runblock.dnsmasq" 2>/dev/null || echo 0)

echo ""
print_header "Update Completed Successfully"
echo -e "  ${BOLD}Domains:${NC}        $(printf '%12s' "$(echo $DOMAIN_COUNT | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')")"
echo -e "  ${BOLD}IPs/Subnets:${NC}    $(printf '%12s' "$(echo $IP_COUNT | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')")"
echo -e "  ${BOLD}iptables:${NC}       $(printf '%12s' "$(echo $RULES_COUNT | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')") rules"
echo ""
log_success "All services reloaded"
echo ""
