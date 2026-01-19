#!/usr/bin/env bash

#===============================================================================
# rublock-update.sh - Обновление списков блокировок с ipset + dnsmasq
# Version: 2.3 (исправлена область видимости переменных)
#===============================================================================

# Строгий режим, но с обработкой ошибок
set -euo pipefail

# Ловушка для отладки ошибок
trap 'echo "ОШИБКА на строке $LINENO: код $?" >&2' ERR

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/bin/rublock.lua"
LOG_FILE="/var/log/rublock-update.log"

# Глобальная переменная для Lua
LUA_BIN=""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#===============================================================================
# Функции логирования
#===============================================================================
log_info() { 
    echo -e "${BLUE}${BOLD}[ℹ]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() { 
    echo -e "${GREEN}${BOLD}[✓]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() { 
    echo -e "${YELLOW}${BOLD}[⚠]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() { 
    echo -e "${RED}${BOLD}[✗]${NC} $*" | tee -a "$LOG_FILE"
}

print_header() {
    local text="$1"
    local width=70
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}${BOLD}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}" | tee -a "$LOG_FILE"
    printf "${CYAN}${BOLD}│${NC} ${BOLD}%-$((width-1))s${NC}${CYAN}${BOLD}│${NC}\n" "$text" | tee -a "$LOG_FILE"
    echo -e "${CYAN}${BOLD}└$(printf '─%.0s' $(seq 1 $width))┘${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                      ║"
    echo "║                    rublock-update v2.3                               ║"
    echo "║              Обновление списков блокировок                           ║"
    echo "║                                                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

format_number() {
    local num="${1:-0}"
    echo "$num" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

format_time() {
    local seconds="${1:-0}"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds} сек"
    else
        echo "$((seconds / 60)) мин $((seconds % 60)) сек"
    fi
}

#===============================================================================
# Проверка окружения
#===============================================================================
check_environment() {
    print_header "Проверка окружения"
    
    # Проверка прав root
    if [[ $EUID -ne 0 ]]; then
        log_error "Требуются права root"
        exit 1
    fi
    log_success "Права root: OK"

    # Проверка Lua и установка глобальной переменной
    if command -v lua5.4 &>/dev/null; then
        LUA_BIN="$(command -v lua5.4)"
    elif command -v lua5.3 &>/dev/null; then
        LUA_BIN="$(command -v lua5.3)"
    elif command -v lua &>/dev/null; then
        LUA_BIN="$(command -v lua)"
    else
        log_error "Lua не найден. Установите: apt install lua5.4"
        exit 1
    fi
    
    log_success "Lua: $LUA_BIN"
    
    # Проверка Lua скрипта
    if [[ ! -f "$LUA_SCRIPT" ]]; then
        log_error "Lua скрипт не найден: $LUA_SCRIPT"
        exit 1
    fi
    
    if [[ ! -x "$LUA_SCRIPT" ]]; then
        chmod +x "$LUA_SCRIPT" || {
            log_error "Не удалось установить права на $LUA_SCRIPT"
            exit 1
        }
        log_warning "Права на Lua скрипт исправлены"
    fi
    log_success "Lua скрипт: OK"
    
    # Проверка сервисов
    if systemctl is-active --quiet tor 2>/dev/null; then
        log_success "Tor: активен"
    else
        log_warning "Tor: не активен"
    fi
    
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        log_success "dnsmasq: активен"
    else
        log_warning "dnsmasq: не активен"
    fi
    
    # Создание директорий
    mkdir -p "$DATA_DIR" || {
        log_error "Не удалось создать $DATA_DIR"
        exit 1
    }
    
    touch "$DATA_DIR/rublock.dnsmasq" "$DATA_DIR/rublock.ipset" 2>/dev/null || true
}

#===============================================================================
# Шаг 1: Обновление списков через Lua
#===============================================================================
update_blocklists() {
    print_header "Шаг 1/4: Обновление списков доменов"
    
    log_info "Запуск Lua скрипта для загрузки и обработки списков..."
    echo ""
    
    # Засекаем время
    local start_time=$(date +%s)
    
    # Запускаем Lua скрипт (он сам показывает прогресс)
    # Временно отключаем set -e для этой команды
    set +e
    "$LUA_BIN" "$LUA_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    local lua_exit_code=${PIPESTATUS[0]}
    set -e
    
    if [[ $lua_exit_code -ne 0 ]]; then
        echo ""
        log_error "Ошибка выполнения Lua скрипта (код: $lua_exit_code)"
        return 1
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    log_success "Списки обновлены за $(format_time $duration)"
    
    # Статистика доменов
    if [[ -f "$DATA_DIR/rublock.dnsmasq" ]]; then
        local domain_count=$(grep -c "^server=/" "$DATA_DIR/rublock.dnsmasq" 2>/dev/null || echo 0)
        log_info "Всего доменов в списке: $(format_number $domain_count)"
    fi
}

#===============================================================================
# Шаг 2: Загрузка ipset
#===============================================================================
load_ipset() {
    print_header "Шаг 2/4: Проверка ipset"
    
    # Проверяем наличие ipset файла
    if [[ ! -f "$DATA_DIR/rublock.ipset" ]] || [[ ! -s "$DATA_DIR/rublock.ipset" ]]; then
        log_info "Файл ipset не найден или пуст"
        log_info "Пропускаю (используется только DNS режим)"
        echo "0" > /tmp/rublock-ip-count || true
        return 0
    fi
    
    log_info "Загрузка ipset..."
    
    # Очистка старых (игнорируем ошибки)
    ipset destroy rublock-ip 2>/dev/null || true
    ipset destroy rublock-ip-tmp 2>/dev/null || true
    ipset destroy rublock-dns 2>/dev/null || true
    
    # Пробуем загрузить ipset
    if ipset restore < "$DATA_DIR/rublock.ipset" 2>/dev/null; then
        log_success "ipset загружен"
    else
        log_warning "Ошибка загрузки ipset"
        echo "0" > /tmp/rublock-ip-count || true
        return 0
    fi
    
    # Создаём rublock-dns если не существует
    ipset create rublock-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true
    
    # Подсчёт IP
    local ip_count=$(ipset list rublock-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)
    echo "$ip_count" > /tmp/rublock-ip-count || true
    
    if [[ $ip_count -gt 0 ]]; then
        log_success "Загружено IP/подсетей: $(format_number $ip_count)"
    else
        log_info "IP адреса не загружены (используется только DNS)"
    fi
}

#===============================================================================
# Шаг 3: Применение iptables правил
#===============================================================================
apply_iptables() {
    print_header "Шаг 3/4: Проверка iptables"
    
    # Проверяем есть ли ipset
    if ! ipset list rublock-ip >/dev/null 2>&1; then
        log_info "ipset rublock-ip не найден"
        log_info "Пропускаю iptables (используется только DNS режим)"
        return 0
    fi
    
    log_info "Проверка правил iptables..."
    
    local rules_added=0
    
    # PREROUTING (игнорируем ошибки проверки)
    if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 || true
        ((rules_added++)) || true
    fi
    
    if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 || true
        ((rules_added++)) || true
    fi
    
    # OUTPUT
    if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 || true
        ((rules_added++)) || true
    fi
    
    if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 || true
        ((rules_added++)) || true
    fi
    
    if [[ $rules_added -eq 0 ]]; then
        log_success "Все правила уже применены"
    else
        log_success "Добавлено правил: $rules_added"
        
        # Сохранение
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save 2>/dev/null || true
        else
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
    
    local rules_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c rublock || echo 0)
    log_info "Активных правил: $rules_count"
}

#===============================================================================
# Шаг 4: Перезагрузка сервисов
#===============================================================================
reload_services() {
    print_header "Шаг 4/4: Перезагрузка сервисов"
    
    log_info "Tor: перезагрузка не требуется"
    
    log_info "Перезагрузка dnsmasq..."
    if systemctl reload dnsmasq 2>/dev/null; then
        log_success "dnsmasq перезагружен"
    elif systemctl restart dnsmasq 2>/dev/null; then
        log_success "dnsmasq перезапущен"
    else
        log_error "Не удалось перезагрузить dnsmasq"
        return 1
    fi
}

#===============================================================================
# Финальная статистика
#===============================================================================
print_summary() {
    local domain_count=$(grep -c "^server=/" "$DATA_DIR/rublock.dnsmasq" 2>/dev/null || echo 0)
    local ip_count=$(cat /tmp/rublock-ip-count 2>/dev/null || echo 0)
    local rules_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c rublock || echo 0)
    
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                      ║"
    echo "║              ✓ ✓ ✓   ОБНОВЛЕНИЕ ЗАВЕРШЕНО   ✓ ✓ ✓                   ║"
    echo "║                                                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "  ${BOLD}Доменов:${NC}        $(printf '%12s' "$(format_number $domain_count)")"
    echo -e "  ${BOLD}IP/Подсетей:${NC}    $(printf '%12s' "$(format_number $ip_count)")"
    echo -e "  ${BOLD}iptables:${NC}       $(printf '%12s' "$(format_number $rules_count)") правил"
    echo ""
    
    # Очистка
    rm -f /tmp/rublock-ip-count /tmp/ipset-errors.log 2>/dev/null || true
}

#===============================================================================
# Главная функция
#===============================================================================
main() {
    local start_time=$(date +%s)
    
    # Инициализация лога (создаём директорию если нужно)
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    {
        echo ""
        echo "=========================================="
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск rublock-update"
        echo "=========================================="
    } > "$LOG_FILE"
    
    print_banner
    
    check_environment || exit 1
    update_blocklists || exit 1
    load_ipset || true
    apply_iptables || true
    reload_services || exit 1
    print_summary
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Общее время: $(format_time $duration)"
    echo ""
}

#===============================================================================
# Запуск
#===============================================================================
main "$@"
