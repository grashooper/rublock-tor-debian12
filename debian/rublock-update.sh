#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/lib/rublock/rublupdate.lua"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}${BOLD}[ℹ]${NC} $*"; }
log_success() { echo -e "${GREEN}${BOLD}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}${BOLD}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}${BOLD}[✗]${NC} $*"; }

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
    log_error "Lua not found. Install: apt install lua5.4"
    exit 1
fi

if [[ ! -x "$LUA_SCRIPT" ]]; then
    log_error "Lua script not found: $LUA_SCRIPT"
    exit 1
fi

install -d "$DATA_DIR"
touch "$DATA_DIR/runblock.dnsmasq" "$DATA_DIR/runblock.ipset" 2>/dev/null || true

# ========== ШАГ 1: Обновление списков ==========
print_header "Starting Blocklist Update"
log_info "Executing: $LUA_BIN $LUA_SCRIPT"
echo ""

if ! "$LUA_BIN" "$LUA_SCRIPT"; then
    echo ""
    log_error "Lua script failed with exit code $?"
    exit 1
fi

# ========== ШАГ 2: Загрузка ipset ==========
echo ""
print_header "Loading ipset Configuration"

# Удаляем старые наборы
log_info "Cleaning old ipset..."
ipset destroy rublack-ip 2>/dev/null || true
ipset destroy rublack-ip-tmp 2>/dev/null || true
ipset destroy rublack-dns 2>/dev/null || true

# Загрузка нового ipset
if [[ -s "$DATA_DIR/runblock.ipset" ]]; then
    log_info "Loading ipset from file..."
    
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log_info "First 5 lines of ipset config:"
        head -5 "$DATA_DIR/runblock.ipset"
    fi
    
    if ipset restore < "$DATA_DIR/runblock.ipset" 2>&1 | tee /tmp/ipset-errors.log | grep -qiE "(error|failed)"; then
        log_error "Failed to load ipset:"
        cat /tmp/ipset-errors.log
        exit 1
    else
        log_success "ipset loaded successfully"
    fi
else
    log_error "ipset config file not found: $DATA_DIR/runblock.ipset"
    exit 1
fi

# Создаём rublack-dns если не существует
ipset create rublack-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true

# Подсчёт IP
IP_COUNT=$(ipset list rublack-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)

if [[ $IP_COUNT -eq 0 ]]; then
    log_warning "No IPs loaded into ipset!"
else
    IP_COUNT_FORMATTED=$(echo "$IP_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
    log_success "Loaded $IP_COUNT_FORMATTED IP addresses/subnets"
fi

# ========== ШАГ 3: Применение iptables ==========
echo ""
print_header "Applying iptables Rules"

# Проверяем и добавляем правила ТОЛЬКО если их нет
log_info "Checking iptables rules..."

# PREROUTING - для трафика из локальной сети
if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -p tcp -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040
  log_info "Added PREROUTING rule for rublack-dns"
fi

if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I PREROUTING -p tcp -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040
  log_info "Added PREROUTING rule for rublack-ip"
fi

# OUTPUT - для трафика с самого сервера
if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -p tcp -m set --match-set rublack-dns dst -j REDIRECT --to-ports 9040
  log_info "Added OUTPUT rule for rublack-dns"
fi

if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
  iptables -t nat -I OUTPUT -p tcp -m set --match-set rublack-ip dst -j REDIRECT --to-ports 9040
  log_info "Added OUTPUT rule for rublack-ip"
fi

RULES_COUNT=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c rublack || echo 0)
log_success "iptables rules active: $RULES_COUNT"

# Сохранение правил
log_info "Saving iptables rules..."
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# ========== ШАГ 4: Перезагрузка ТОЛЬКО dnsmasq ==========
echo ""
print_header "Reloading Services"

# Tor НЕ трогаем - он не использует ipset напрямую!
log_info "Tor: no reload needed (uses TransPort passively)"

log_info "Reloading dnsmasq..."
if systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null; then
    log_success "dnsmasq reloaded"
else
    log_warning "dnsmasq reload failed"
fi

# ========== Финальная статистика ==========
DOMAIN_COUNT=$(wc -l < "$DATA_DIR/runblock.dnsmasq" 2>/dev/null || echo 0)
DOMAIN_COUNT_FORMATTED=$(echo "$DOMAIN_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
IP_COUNT_FORMATTED=$(echo "$IP_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
RULES_COUNT_FORMATTED=$(echo "$RULES_COUNT" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')

echo ""
print_header "Update Completed Successfully"
echo -e "  ${BOLD}Domains:${NC}        $(printf '%12s' "$DOMAIN_COUNT_FORMATTED")"
echo -e "  ${BOLD}IPs/Subnets:${NC}    $(printf '%12s' "$IP_COUNT_FORMATTED")"
echo -e "  ${BOLD}iptables:${NC}       $(printf '%12s' "$RULES_COUNT_FORMATTED") rules"
echo ""
log_success "Blocklist updated successfully"
echo ""
