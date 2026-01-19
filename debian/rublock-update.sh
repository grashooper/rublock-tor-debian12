#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# rublock-update.sh - Обновление списков блокировок с ipset + dnsmasq
# Version: 2.0
#===============================================================================

DATA_DIR="/etc/rublock"
LUA_SCRIPT="/usr/local/bin/rublock.lua"
LOG_FILE="/var/log/rublock-update.log"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
    printf "${CYAN}${BOLD}│${NC} %-${width}s ${CYAN}${BOLD}│${NC}\n" "$text" | tee -a "$LOG_FILE"
    echo -e "${CYAN}${BOLD}└$(printf '─%.0s' $(seq 1 $width))┘${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

format_number() {
    echo "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

#===============================================================================
# Проверка окружения
#===============================================================================
check_environment() {
    # Проверка прав root
    if [[ $EUID -ne 0 ]]; then
        log_error "Требуются права root"
        exit 1
    fi

    # Проверка Lua
    LUA_BIN="$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)"
    
    if [[ -z "$LUA_BIN" ]]; then
        log_error "Lua не найден. Установите: apt install lua5.4"
        exit 1
    fi
    
    log_info "Используется: $LUA_BIN"
    
    # Проверка Lua скрипта
    if [[ ! -f "$LUA_SCRIPT" ]]; then
        log_error "Lua скрипт не найден: $LUA_SCRIPT"
        exit 1
    fi
    
    if [[ ! -x "$LUA_SCRIPT" ]]; then
        log_warning "Lua скрипт не исполняемый, исправляю..."
        chmod +x "$LUA_SCRIPT"
    fi
    
    # Создание директорий
    install -d "$DATA_DIR"
    touch "$DATA_DIR/rublock.dnsmasq" "$DATA_DIR/rublock.ipset" 2>/dev/null || true
}

#===============================================================================
# Шаг 1: Обновление списков через Lua
#===============================================================================
update_blocklists() {
    print_header "Шаг 1/4: Обновление списков доменов"
    
    log_info "Запуск Lua скрипта..."
    log_info "Команда: $LUA_BIN $LUA_SCRIPT"
    echo ""
    
    if ! "$LUA_BIN" "$LUA_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
        echo ""
        log_error "Ошибка выполнения Lua скрипта (код: ${PIPESTATUS[0]})"
        return 1
    fi
    
    echo ""
    log_success "Списки доменов обновлены"
    
    # Статистика доменов
    if [[ -f "$DATA_DIR/rublock.dnsmasq" ]]; then
        local domain_count=$(grep -c "^server=/" "$DATA_DIR/rublock.dnsmasq" 2>/dev/null || echo 0)
        log_info "Доменов в списке: $(format_number $domain_count)"
    fi
}

#===============================================================================
# Шаг 2: Загрузка ipset (если файл существует)
#===============================================================================
load_ipset() {
    print_header "Шаг 2/4: Загрузка ipset"
    
    # Проверяем наличие ipset файла
    if [[ ! -f "$DATA_DIR/rublock.ipset" ]] || [[ ! -s "$DATA_DIR/rublock.ipset" ]]; then
        log_warning "Файл ipset не найден или пуст: $DATA_DIR/rublock.ipset"
        log_info "Пропускаю загрузку ipset (используется только DNS)"
        return 0
    fi
    
    log_info "Очистка старых ipset..."
    ipset destroy rublock-ip 2>/dev/null || true
    ipset destroy rublock-ip-tmp 2>/dev/null || true
    ipset destroy rublock-dns 2>/dev/null || true
    
    log_info "Загрузка ipset из файла..."
    
    if [[ "${DEBUG:-0}" == "1" ]]; then
        log_info "Первые 5 строк ipset конфига:"
        head -5 "$DATA_DIR/rublock.ipset" | tee -a "$LOG_FILE"
    fi
    
    if ipset restore < "$DATA_DIR/rublock.ipset" 2>&1 | tee /tmp/ipset-errors.log | grep -qiE "(error|failed)"; then
        log_error "Ошибка загрузки ipset:"
        cat /tmp/ipset-errors.log | tee -a "$LOG_FILE"
        return 1
    else
        log_success "ipset загружен успешно"
    fi
    
    # Создаём rublock-dns если не существует
    ipset create rublock-dns hash:ip family inet hashsize 131072 maxelem 2097152 -exist 2>/dev/null || true
    
    # Подсчёт IP
    local ip_count=$(ipset list rublock-ip 2>/dev/null | grep -c "^[0-9]" || echo 0)
    
    if [[ $ip_count -eq 0 ]]; then
        log_warning "IP адреса не загружены в ipset"
    else
        log_success "Загружено IP/подсетей: $(format_number $ip_count)"
    fi
    
    echo "$ip_count" > /tmp/rublock-ip-count
}

#===============================================================================
# Шаг 3: Применение iptables правил
#===============================================================================
apply_iptables() {
    print_header "Шаг 3/4: Применение iptables правил"
    
    # Проверяем есть ли ipset
    if ! ipset list rublock-ip >/dev/null 2>&1; then
        log_info "ipset rublock-ip не найден, пропускаю iptables"
        return 0
    fi
    
    log_info "Проверка и добавление правил iptables..."
    
    local rules_added=0
    
    # PREROUTING - для трафика из локальной сети
    if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040
        log_info "Добавлено правило PREROUTING для rublock-dns"
        ((rules_added++))
    fi
    
    if ! iptables -t nat -C PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I PREROUTING -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040
        log_info "Добавлено правило PREROUTING для rublock-ip"
        ((rules_added++))
    fi
    
    # OUTPUT - для трафика с самого сервера
    if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-dns dst -j REDIRECT --to-ports 9040
        log_info "Добавлено правило OUTPUT для rublock-dns"
        ((rules_added++))
    fi
    
    if ! iptables -t nat -C OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040 2>/dev/null; then
        iptables -t nat -I OUTPUT -p tcp -m set --match-set rublock-ip dst -j REDIRECT --to-ports 9040
        log_info "Добавлено правило OUTPUT для rublock-ip"
        ((rules_added++))
    fi
    
    if [[ $rules_added -eq 0 ]]; then
        log_success "Все правила iptables уже применены"
    else
        log_success "Добавлено новых правил: $rules_added"
    fi
    
    local rules_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c rublock || echo 0)
    log_info "Активных правил iptables: $rules_count"
    
    # Сохранение правил
    log_info "Сохранение правил iptables..."
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    log_success "Правила сохранены"
}

#===============================================================================
# Шаг 4: Перезагрузка сервисов
#===============================================================================
reload_services() {
    print_header "Шаг 4/4: Перезагрузка сервисов"
    
    # Tor не трогаем - он использует TransPort пассивно
    log_info "Tor: перезагрузка не требуется (использует TransPort пассивно)"
    
    # Перезагрузка dnsmasq
    log_info "Перезагрузка dnsmasq..."
    if systemctl reload dnsmasq 2>/dev/null; then
        log_success "dnsmasq перезагружен (reload)"
    elif systemctl restart dnsmasq 2>/dev/null; then
        log_success "dnsmasq перезапущен (restart)"
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
    print_header "Обновление завершено успешно"
    
    echo -e "  ${BOLD}Доменов:${NC}        $(printf '%12s' "$(format_number $domain_count)")" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}IP/Подсетей:${NC}    $(printf '%12s' "$(format_number $ip_count)")" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}iptables:${NC}       $(printf '%12s' "$(format_number $rules_count)") правил" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    log_success "Списки блокировок обновлены"
    echo "" | tee -a "$LOG_FILE"
    
    # Очистка временных файлов
    rm -f /tmp/rublock-ip-count /tmp/ipset-errors.log
}

#===============================================================================
# Главная функция
#===============================================================================
main() {
    local start_time=$(date +%s)
    
    echo "" | tee "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Запуск обновления rublock" | tee -a "$LOG_FILE"
    echo "================================================================" | tee -a "$LOG_FILE"
    
    check_environment || exit 1
    update_blocklists || exit 1
    load_ipset || true  # не критично если ipset нет
    apply_iptables || true  # не критично если ipset нет
    reload_services || exit 1
    print_summary
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "Время выполнения: ${duration} сек"
    echo "================================================================" | tee -a "$LOG_FILE"
}

#===============================================================================
# Запуск
#===============================================================================
main "$@"
