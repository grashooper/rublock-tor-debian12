#!/bin/bash

#===============================================================================
# rublock-tor Installer for Debian 12
# Установка и настройка rublock с Tor для обхода блокировок
# Version: 2.5 Production-Safe (Fixed)
#===============================================================================

#===============================================================================
# Цвета и символы для вывода
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SUCCESS="[✓]"
ERROR="[✗]"
INFO="[ℹ]"
WARNING="[⚠]"
QUESTION="[?]"

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

log_question() {
    echo -ne "${CYAN}${QUESTION}${NC} $1"
}

log_important() {
    echo -e "${MAGENTA}${BOLD}>>> $1${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}┌──────────────────────────────────────────────────────────────────────┐${NC}"
    printf "${BLUE}│${NC} ${BOLD}%-68s${NC} ${BLUE}│${NC}\n" "$1"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                      ║"
    echo "║   ██████╗ ██╗   ██╗██████╗ ██╗      ██████╗  ██████╗██╗  ██╗         ║"
    echo "║   ██╔══██╗██║   ██║██╔══██╗██║     ██╔═══██╗██╔════╝██║ ██╔╝         ║"
    echo "║   ██████╔╝██║   ██║██████╔╝██║     ██║   ██║██║     █████╔╝          ║"
    echo "║   ██╔══██╗██║   ██║██╔══██╗██║     ██║   ██║██║     ██╔═██╗          ║"
    echo "║   ██║  ██║╚██████╔╝██████╔╝███████╗╚██████╔╝╚██████╗██║  ██╗         ║"
    echo "║   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝         ║"
    echo "║                                                                      ║"
    echo "║                    TOR Configuration for Debian 12                   ║"
    echo "║                      Version 2.5 Production-Safe                     ║"
    echo "║                                                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#===============================================================================
# Функция подтверждения
#===============================================================================
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer
    
    if [[ "$default" =~ ^[Yy]$ ]]; then
        log_question "$prompt [Y/n]: "
    else
        log_question "$prompt [y/N]: "
    fi
    
    read -r answer
    
    if [[ -z "$answer" ]]; then
        answer="$default"
    fi
    
    [[ "$answer" =~ ^[Yy]$ ]]
}

#===============================================================================
# Функция ввода с значением по умолчанию
#===============================================================================
input_with_default() {
    local prompt="$1"
    local default="$2"
    local answer
    
    # Выводим prompt и ждём ввода на той же строке
    echo -ne "${CYAN}${QUESTION}${NC} $prompt [$default]: "
    read -r answer
    
    if [[ -z "$answer" ]]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

#===============================================================================
# Функция выбора из меню (исправленная версия)
# Использует глобальную переменную MENU_RESULT для возврата значения
#===============================================================================
select_option() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo "" >&2
    log_info "$prompt" >&2
    echo "" >&2
    
    for i in "${!options[@]}"; do
        echo "    $((i+1))) ${options[$i]}" >&2
    done
    echo "" >&2
    
    while true; do
        log_question "Выберите опцию [1-${#options[@]}]: " >&2
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            MENU_RESULT=$((choice-1))
            return 0
        fi
        log_warning "Неверный выбор. Попробуйте снова." >&2
    done
}

#===============================================================================
# Проверка прав root
#===============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        log_info "Используйте: sudo $0"
        exit 1
    fi
}

#===============================================================================
# Переменные конфигурации
#===============================================================================
init_variables() {
    RUBLOCK_DIR="/etc/rublock"
    RUBLOCK_SCRIPT="/usr/local/bin/rublock.lua"
    RUBLOCK_UPDATE_SCRIPT="/usr/local/bin/rublock-update.sh"
    RUBLOCK_DNSMASQ_FILE="${RUBLOCK_DIR}/rublock.dnsmasq"
    LOG_FILE="/var/log/rublock-update.log"
    DNSMASQ_CONF="/etc/dnsmasq.d/rublock.conf"
    TOR_CONF="/etc/tor/torrc"
    
    # Директория для бэкапов
    BACKUP_DIR="/etc/rublock/backups"
    BACKUP_MANIFEST="${BACKUP_DIR}/manifest.txt"

    # Настройки по умолчанию
    USE_BRIDGES=0
    BRIDGES_LIST=""
    EXCLUDE_COUNTRIES="{ru},{by},{kz},{kg},{uz},{tj},{tm},{az},{am}"
    USE_IPV6=1
    IPV6_SETTING_USE="1"
    IPV6_SETTING_PREFER="1"
    
    # Порты
    DNSMASQ_PORT=53
    TOR_DNS_PORT=9053
    
    # Флаги режима работы
    IS_REINSTALL=0
    BACKUP_CREATED=0
    CURRENT_BACKUP_NAME=""
    DISABLE_RESOLVED=0
    DISABLE_BIND=0
    DNSMASQ_ALT_PORT=0
    
    # Глобальная переменная для результата меню
    MENU_RESULT=0
}

#===============================================================================
# Проверка предыдущей установки
#===============================================================================
check_existing_installation() {
    print_header "Проверка системы"
    
    local existing_components=()
    local warnings=()
    
    # Проверяем компоненты rublock
    if [ -d "$RUBLOCK_DIR" ]; then
        existing_components+=("Директория rublock ($RUBLOCK_DIR)")
    fi
    
    if [ -f "$RUBLOCK_SCRIPT" ]; then
        existing_components+=("Lua скрипт ($RUBLOCK_SCRIPT)")
    fi
    
    if [ -f "$DNSMASQ_CONF" ]; then
        existing_components+=("Конфиг dnsmasq rublock ($DNSMASQ_CONF)")
    fi
    
    if [ -f "$TOR_CONF" ] && grep -q "rublock-tor" "$TOR_CONF" 2>/dev/null; then
        existing_components+=("Конфиг Tor с rublock настройками")
    fi
    
    if systemctl is-enabled rublock-update.timer &>/dev/null; then
        existing_components+=("Systemd таймер rublock")
    fi
    
    # Проверяем потенциально конфликтующие сервисы
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warnings+=("systemd-resolved активен (использует порт 53)")
    fi
    
    if systemctl is-active --quiet named 2>/dev/null; then
        warnings+=("BIND (named) активен (использует порт 53)")
    fi
    
    if systemctl is-active --quiet unbound 2>/dev/null; then
        warnings+=("Unbound активен (использует порт 53)")
    fi
    
    # Проверяем что на порту 53
    local port53_users
    port53_users=$(ss -tulpn 2>/dev/null | grep ":53 " | awk '{print $7}' | sed 's/.*"\([^"]*\)".*/\1/' | sort -u | tr '\n' ', ' | sed 's/,$//')
    
    if [ -n "$port53_users" ] && [ "$port53_users" != "dnsmasq" ]; then
        warnings+=("Порт 53 используется: $port53_users")
    fi
    
    # Вывод информации
    if [ ${#existing_components[@]} -gt 0 ]; then
        IS_REINSTALL=1
        echo ""
        log_warning "Обнаружена предыдущая установка rublock:"
        echo ""
        for comp in "${existing_components[@]}"; do
            echo "    • $comp"
        done
        echo ""
    else
        log_success "Предыдущая установка rublock не обнаружена"
    fi
    
    if [ ${#warnings[@]} -gt 0 ]; then
        echo ""
        log_warning "Потенциальные конфликты:"
        echo ""
        for warn in "${warnings[@]}"; do
            echo "    ⚠ $warn"
        done
        echo ""
    fi
    
    # Если это переустановка - показываем опции
    if [ $IS_REINSTALL -eq 1 ]; then
        echo ""
        log_important "Выберите действие:"
        
        select_option "Что сделать с существующей установкой?" \
            "Создать бэкап и установить заново (рекомендуется)" \
            "Перезаписать без бэкапа" \
            "Восстановить из бэкапа" \
            "Показать список бэкапов" \
            "Отмена"
        
        case $MENU_RESULT in
            0)
                create_backup
                ;;
            1)
                log_warning "Установка без бэкапа. Текущие настройки будут перезаписаны."
                if ! confirm "Вы уверены?" "n"; then
                    log_info "Установка отменена"
                    exit 0
                fi
                ;;
            2)
                restore_backup_menu
                exit $?
                ;;
            3)
                list_backups
                echo ""
                if confirm "Продолжить установку?" "n"; then
                    create_backup
                else
                    exit 0
                fi
                ;;
            4)
                log_info "Установка отменена"
                exit 0
                ;;
        esac
    fi
}

#===============================================================================
# Функции бэкапа
#===============================================================================
create_backup() {
    print_header "Создание бэкапа"
    
    # Создаём директорию для бэкапов
    mkdir -p "$BACKUP_DIR"
    
    # Генерируем имя бэкапа
    CURRENT_BACKUP_NAME="backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${CURRENT_BACKUP_NAME}"
    
    mkdir -p "$backup_path"
    
    log_info "Создание бэкапа: $CURRENT_BACKUP_NAME"
    echo ""
    
    local backed_up=()
    
    # Бэкап конфигов rublock
    if [ -f "$DNSMASQ_CONF" ]; then
        cp "$DNSMASQ_CONF" "$backup_path/"
        backed_up+=("dnsmasq rublock config")
        log_success "  dnsmasq rublock конфиг"
    fi
    
    if [ -f "$RUBLOCK_DNSMASQ_FILE" ]; then
        cp "$RUBLOCK_DNSMASQ_FILE" "$backup_path/"
        backed_up+=("rublock domains list")
        log_success "  Список доменов rublock"
    fi
    
    # Бэкап Tor конфига
    if [ -f "$TOR_CONF" ]; then
        cp "$TOR_CONF" "$backup_path/"
        backed_up+=("tor config")
        log_success "  Tor конфиг"
    fi
    
    # Бэкап основного dnsmasq конфига
    if [ -f "/etc/dnsmasq.conf" ]; then
        cp "/etc/dnsmasq.conf" "$backup_path/"
        backed_up+=("main dnsmasq config")
        log_success "  Основной dnsmasq конфиг"
    fi
    
    # Бэкап resolv.conf
    if [ -f "/etc/resolv.conf" ]; then
        # Копируем содержимое, а не симлинк
        cat /etc/resolv.conf > "$backup_path/resolv.conf"
        # Сохраняем информацию о симлинке если есть
        if [ -L "/etc/resolv.conf" ]; then
            readlink -f /etc/resolv.conf > "$backup_path/resolv.conf.link"
        fi
        backed_up+=("resolv.conf")
        log_success "  resolv.conf"
    fi
    
    # Бэкап Lua скрипта
    if [ -f "$RUBLOCK_SCRIPT" ]; then
        cp "$RUBLOCK_SCRIPT" "$backup_path/"
        backed_up+=("rublock.lua")
        log_success "  Lua скрипт"
    fi
    
    # Бэкап скрипта обновления
    if [ -f "$RUBLOCK_UPDATE_SCRIPT" ]; then
        cp "$RUBLOCK_UPDATE_SCRIPT" "$backup_path/"
        backed_up+=("update script")
        log_success "  Скрипт обновления"
    fi
    
    # Сохраняем состояние сервисов
    {
        echo "# Service states at backup time"
        echo "DATE=$(date)"
        echo "SYSTEMD_RESOLVED=$(systemctl is-active systemd-resolved 2>/dev/null || echo 'unknown')"
        echo "SYSTEMD_RESOLVED_ENABLED=$(systemctl is-enabled systemd-resolved 2>/dev/null || echo 'unknown')"
        echo "NAMED=$(systemctl is-active named 2>/dev/null || echo 'unknown')"
        echo "NAMED_ENABLED=$(systemctl is-enabled named 2>/dev/null || echo 'unknown')"
        echo "DNSMASQ=$(systemctl is-active dnsmasq 2>/dev/null || echo 'unknown')"
        echo "DNSMASQ_ENABLED=$(systemctl is-enabled dnsmasq 2>/dev/null || echo 'unknown')"
        echo "TOR=$(systemctl is-active tor 2>/dev/null || echo 'unknown')"
        echo "TOR_ENABLED=$(systemctl is-enabled tor 2>/dev/null || echo 'unknown')"
        echo "RUBLOCK_TIMER=$(systemctl is-active rublock-update.timer 2>/dev/null || echo 'unknown')"
        echo "RUBLOCK_TIMER_ENABLED=$(systemctl is-enabled rublock-update.timer 2>/dev/null || echo 'unknown')"
    } > "$backup_path/services.state"
    log_success "  Состояние сервисов"
    
    # Обновляем манифест
    {
        echo "${CURRENT_BACKUP_NAME}|$(date)|${#backed_up[@]} files|$(IFS=,; echo "${backed_up[*]}")"
    } >> "$BACKUP_MANIFEST"
    
    echo ""
    log_success "Бэкап создан: $backup_path"
    log_info "Файлов в бэкапе: ${#backed_up[@]}"
    
    BACKUP_CREATED=1
}

list_backups() {
    print_header "Список бэкапов"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null | grep "^backup_")" ]; then
        log_warning "Бэкапы не найдены"
        return 1
    fi
    
    echo ""
    echo "  №   Дата/время           Файлов   Содержимое"
    echo "  ─── ──────────────────── ──────── ──────────────────────────────"
    
    local i=1
    for backup in "$BACKUP_DIR"/backup_*; do
        if [ -d "$backup" ]; then
            local name=$(basename "$backup")
            local date_part=$(echo "$name" | sed 's/backup_//' | sed 's/_/ /')
            local file_count=$(ls -1 "$backup" 2>/dev/null | wc -l)
            local files=$(ls -1 "$backup" 2>/dev/null | head -3 | tr '\n' ', ' | sed 's/,$//')
            
            printf "  %-3s %-20s %-8s %s\n" "$i" "$date_part" "$file_count" "$files..."
            ((i++))
        fi
    done
    
    echo ""
    return 0
}

restore_backup_menu() {
    print_header "Восстановление из бэкапа"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Директория бэкапов не найдена"
        return 1
    fi
    
    # Получаем список бэкапов
    local backups=()
    for backup in "$BACKUP_DIR"/backup_*; do
        if [ -d "$backup" ]; then
            backups+=("$(basename "$backup")")
        fi
    done
    
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "Бэкапы не найдены"
        return 1
    fi
    
    # Показываем список
    echo ""
    log_info "Доступные бэкапы:"
    echo ""
    
    for i in "${!backups[@]}"; do
        local name="${backups[$i]}"
        local date_part=$(echo "$name" | sed 's/backup_//' | sed 's/_/ /')
        local file_count=$(ls -1 "${BACKUP_DIR}/${name}" 2>/dev/null | wc -l)
        echo "    $((i+1))) $date_part ($file_count файлов)"
    done
    echo "    $((${#backups[@]}+1))) Отмена"
    echo ""
    
    local choice
    while true; do
        log_question "Выберите бэкап для восстановления [1-$((${#backups[@]}+1))]: "
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -eq $((${#backups[@]}+1)) ]; then
                log_info "Восстановление отменено"
                return 0
            fi
            if [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
                restore_backup "${backups[$((choice-1))]}"
                return $?
            fi
        fi
        log_warning "Неверный выбор"
    done
}

restore_backup() {
    local backup_name="$1"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    if [ ! -d "$backup_path" ]; then
        log_error "Бэкап не найден: $backup_path"
        return 1
    fi
    
    echo ""
    log_warning "ВНИМАНИЕ: Восстановление перезапишет текущие конфигурации!"
    echo ""
    log_info "Содержимое бэкапа:"
    ls -la "$backup_path" | sed 's/^/    /'
    echo ""
    
    if ! confirm "Восстановить этот бэкап?" "n"; then
        log_info "Восстановление отменено"
        return 0
    fi
    
    log_info "Восстановление из: $backup_name"
    echo ""
    
    # Останавливаем сервисы
    log_info "Остановка сервисов..."
    systemctl stop rublock-update.timer 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl stop tor 2>/dev/null || true
    
    # Восстанавливаем файлы
    if [ -f "$backup_path/rublock.conf" ]; then
        mkdir -p "$(dirname "$DNSMASQ_CONF")"
        cp "$backup_path/rublock.conf" "$DNSMASQ_CONF"
        log_success "  Восстановлен: dnsmasq rublock конфиг"
    fi
    
    if [ -f "$backup_path/rublock.dnsmasq" ]; then
        mkdir -p "$(dirname "$RUBLOCK_DNSMASQ_FILE")"
        cp "$backup_path/rublock.dnsmasq" "$RUBLOCK_DNSMASQ_FILE"
        log_success "  Восстановлен: список доменов"
    fi
    
    if [ -f "$backup_path/torrc" ]; then
        cp "$backup_path/torrc" "$TOR_CONF"
        log_success "  Восстановлен: Tor конфиг"
    fi
    
    if [ -f "$backup_path/dnsmasq.conf" ]; then
        cp "$backup_path/dnsmasq.conf" "/etc/dnsmasq.conf"
        log_success "  Восстановлен: основной dnsmasq конфиг"
    fi
    
    if [ -f "$backup_path/rublock.lua" ]; then
        cp "$backup_path/rublock.lua" "$RUBLOCK_SCRIPT"
        chmod +x "$RUBLOCK_SCRIPT"
        log_success "  Восстановлен: Lua скрипт"
    fi
    
    if [ -f "$backup_path/rublock-update.sh" ]; then
        cp "$backup_path/rublock-update.sh" "$RUBLOCK_UPDATE_SCRIPT"
        chmod +x "$RUBLOCK_UPDATE_SCRIPT"
        log_success "  Восстановлен: скрипт обновления"
    fi
    
    # Восстановление resolv.conf
    if [ -f "$backup_path/resolv.conf" ]; then
        if [ -f "$backup_path/resolv.conf.link" ]; then
            # Был симлинк - пытаемся восстановить
            local orig_link=$(cat "$backup_path/resolv.conf.link")
            if [ -f "$orig_link" ]; then
                rm -f /etc/resolv.conf
                ln -s "$orig_link" /etc/resolv.conf
                log_success "  Восстановлен: resolv.conf (симлинк на $orig_link)"
            else
                cp "$backup_path/resolv.conf" /etc/resolv.conf
                log_success "  Восстановлен: resolv.conf (как файл)"
            fi
        else
            cp "$backup_path/resolv.conf" /etc/resolv.conf
            log_success "  Восстановлен: resolv.conf"
        fi
    fi
    
    # Восстановление состояния сервисов
    if [ -f "$backup_path/services.state" ]; then
        # Читаем переменные из файла с префиксом BACKUP_
        local BACKUP_SYSTEMD_RESOLVED=""
        local BACKUP_SYSTEMD_RESOLVED_ENABLED=""
        local BACKUP_NAMED=""
        local BACKUP_NAMED_ENABLED=""
        local BACKUP_DNSMASQ=""
        local BACKUP_DNSMASQ_ENABLED=""
        local BACKUP_TOR=""
        local BACKUP_TOR_ENABLED=""
        local BACKUP_RUBLOCK_TIMER=""
        local BACKUP_RUBLOCK_TIMER_ENABLED=""
        
        while IFS='=' read -r key value; do
            case "$key" in
                SYSTEMD_RESOLVED) BACKUP_SYSTEMD_RESOLVED="$value" ;;
                SYSTEMD_RESOLVED_ENABLED) BACKUP_SYSTEMD_RESOLVED_ENABLED="$value" ;;
                NAMED) BACKUP_NAMED="$value" ;;
                NAMED_ENABLED) BACKUP_NAMED_ENABLED="$value" ;;
                DNSMASQ) BACKUP_DNSMASQ="$value" ;;
                DNSMASQ_ENABLED) BACKUP_DNSMASQ_ENABLED="$value" ;;
                TOR) BACKUP_TOR="$value" ;;
                TOR_ENABLED) BACKUP_TOR_ENABLED="$value" ;;
                RUBLOCK_TIMER) BACKUP_RUBLOCK_TIMER="$value" ;;
                RUBLOCK_TIMER_ENABLED) BACKUP_RUBLOCK_TIMER_ENABLED="$value" ;;
            esac
        done < "$backup_path/services.state"
        
        echo ""
        log_info "Восстановление состояния сервисов..."
        
        # systemd-resolved
        if [ "$BACKUP_SYSTEMD_RESOLVED_ENABLED" = "enabled" ]; then
            systemctl unmask systemd-resolved 2>/dev/null || true
            systemctl enable systemd-resolved 2>/dev/null || true
            if [ "$BACKUP_SYSTEMD_RESOLVED" = "active" ]; then
                systemctl start systemd-resolved
                log_success "  systemd-resolved запущен"
            fi
        fi
        
        # named
        if [ "$BACKUP_NAMED_ENABLED" = "enabled" ]; then
            systemctl unmask named 2>/dev/null || true
            systemctl enable named 2>/dev/null || true
            if [ "$BACKUP_NAMED" = "active" ]; then
                systemctl start named
                log_success "  named (BIND) запущен"
            fi
        fi
        
        # tor
        if [ "$BACKUP_TOR" = "active" ] || [ "$BACKUP_TOR_ENABLED" = "enabled" ]; then
            systemctl start tor
            log_success "  tor запущен"
        fi
        
        # dnsmasq
        if [ "$BACKUP_DNSMASQ" = "active" ] || [ "$BACKUP_DNSMASQ_ENABLED" = "enabled" ]; then
            systemctl start dnsmasq
            log_success "  dnsmasq запущен"
        fi
        
        # rublock timer
        if [ "$BACKUP_RUBLOCK_TIMER_ENABLED" = "enabled" ]; then
            systemctl start rublock-update.timer
            log_success "  rublock-update.timer запущен"
        fi
    fi
    
    echo ""
    log_success "Восстановление завершено!"
    
    return 0
}

#===============================================================================
# Определение сетевых параметров
#===============================================================================
detect_network() {
    print_header "Определение сетевых параметров"
    
    # Определение основного интерфейса
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        log_error "Не удалось определить сетевой интерфейс"
        exit 1
    fi
    
    # Определение IPv4 адреса
    MAIN_IP=$(ip -4 addr show "$MAIN_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    
    # Определение IPv6 адреса
    MAIN_IP6=$(ip -6 addr show "$MAIN_INTERFACE" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -n1)
    
    # Определение подсети
    SUBNET=$(ip -4 addr show "$MAIN_INTERFACE" | grep -oP '\d+(\.\d+){3}/\d+' | head -n1)
    NETWORK=$(echo "$SUBNET" | cut -d'/' -f1 | sed 's/\.[0-9]*$/.0/')
    NETMASK_CIDR=$(echo "$SUBNET" | cut -d'/' -f2)
    
    # Валидация IP-адреса
    if ! [[ "$MAIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Не удалось определить корректный IP-адрес"
        exit 1
    fi
    
    log_info "Обнаружены сетевые настройки:"
    echo ""
    echo "    Интерфейс:     $MAIN_INTERFACE"
    echo "    IPv4 адрес:    $MAIN_IP"
    echo "    Подсеть:       $NETWORK/$NETMASK_CIDR"
    if [[ -n "$MAIN_IP6" ]]; then
        echo "    IPv6 адрес:    $MAIN_IP6"
    else
        echo "    IPv6 адрес:    не обнаружен"
    fi
    echo ""
    
    if ! confirm "Использовать эти настройки?" "y"; then
        # Запрашиваем новый IP напрямую, без подстановки команды
        echo -ne "${CYAN}${QUESTION}${NC} Введите IPv4 адрес сервера [$MAIN_IP]: "
        read -r new_ip
        
        if [[ -n "$new_ip" ]]; then
            MAIN_IP="$new_ip"
        fi
        
        log_success "Используется IP: $MAIN_IP"
    fi
}

#===============================================================================
# Проверка совместимости с существующими сервисами
#===============================================================================
check_service_compatibility() {
    print_header "Проверка совместимости сервисов"
    
    local conflicts=0
    
    echo ""
    log_important "ВАЖНО: Информация о UDP трафике"
    echo ""
    echo "    Tor поддерживает ТОЛЬКО TCP соединения."
    echo "    Этот скрипт НЕ создаёт iptables правил для перенаправления трафика."
    echo "    UDP трафик (игры, VoIP, видео и т.д.) НЕ будет затронут."
    echo ""
    echo "    Скрипт только настраивает DNS резолвинг заблокированных доменов"
    echo "    через Tor DNS (TCP), остальной трафик идёт напрямую."
    echo ""
    
    # Проверяем systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo ""
        log_warning "systemd-resolved активен и использует порт 53"
        echo ""
        echo "    systemd-resolved - стандартный DNS resolver в современных системах."
        echo "    Для работы dnsmasq на порту 53 его нужно либо:"
        echo "      1) Отключить (dnsmasq будет основным DNS)"
        echo "      2) Настроить на использование другого порта"
        echo "      3) Настроить dnsmasq на другой порт (не 53)"
        echo ""
        
        select_option "Что сделать с systemd-resolved?" \
            "Отключить systemd-resolved (рекомендуется для серверов)" \
            "Настроить dnsmasq на порт 5353 (systemd-resolved остаётся)" \
            "Оставить как есть (возможны конфликты!)" \
            "Отмена установки"
        
        case $MENU_RESULT in
            0)
                DISABLE_RESOLVED=1
                log_info "systemd-resolved будет отключён"
                ;;
            1)
                DNSMASQ_PORT=5353
                DNSMASQ_ALT_PORT=1
                log_info "dnsmasq будет слушать на порту 5353"
                log_warning "Клиенты должны использовать DNS порт 5353!"
                ;;
            2)
                log_warning "Возможны конфликты портов!"
                ;;
            3)
                log_info "Установка отменена"
                exit 0
                ;;
        esac
        
        ((conflicts++)) || true
    fi
    
    # Проверяем BIND
    if systemctl is-active --quiet named 2>/dev/null; then
        echo ""
        log_warning "BIND (named) активен и использует порт 53"
        echo ""
        echo "    BIND - полноценный DNS сервер, часто используется на серверах."
        echo "    Возможные варианты:"
        echo "      1) Интегрировать rublock с BIND (ручная настройка)"
        echo "      2) Отключить BIND (dnsmasq заменит его)"
        echo "      3) Использовать dnsmasq на другом порту"
        echo ""
        
        select_option "Что сделать с BIND?" \
            "Показать инструкцию по интеграции с BIND и выйти" \
            "Отключить BIND (ВНИМАНИЕ: может нарушить работу сервисов!)" \
            "Настроить dnsmasq на порт 5353" \
            "Отмена установки"
        
        case $MENU_RESULT in
            0)
                show_bind_integration_guide
                exit 0
                ;;
            1)
                if confirm "Вы УВЕРЕНЫ что хотите отключить BIND?" "n"; then
                    DISABLE_BIND=1
                    log_warning "BIND будет отключён!"
                else
                    log_info "Установка отменена"
                    exit 0
                fi
                ;;
            2)
                DNSMASQ_PORT=5353
                DNSMASQ_ALT_PORT=1
                log_info "dnsmasq будет слушать на порту 5353"
                ;;
            3)
                log_info "Установка отменена"
                exit 0
                ;;
        esac
        
        ((conflicts++)) || true
    fi
    
    # Проверяем другие DNS серверы
    local other_dns
    other_dns=$(ss -tulpn 2>/dev/null | grep ":53 " | grep -v "dnsmasq\|systemd-resolve\|named" | awk '{print $7}')
    
    if [ -n "$other_dns" ]; then
        echo ""
        log_warning "Обнаружены другие процессы на порту 53:"
        ss -tulpn 2>/dev/null | grep ":53 " | grep -v "dnsmasq\|systemd-resolve\|named"
        echo ""
        
        if ! confirm "Продолжить установку?" "n"; then
            exit 1
        fi
    fi
    
    if [ $conflicts -eq 0 ]; then
        log_success "Конфликтующие сервисы не обнаружены"
    fi
    
    # Проверяем игровые серверы и другие важные сервисы
    echo ""
    log_info "Проверка работающих сервисов..."
    echo ""
    
    local important_ports
    important_ports=$(ss -tulpn 2>/dev/null | grep -E ":(25565|27015|7777|7778|2456|2457|3724|8080|80|443|3306|5432) " | head -10)
    
    if [ -n "$important_ports" ]; then
        echo "    Обнаружены активные сервисы на типичных портах:"
        echo "$important_ports" | sed 's/^/    /'
        echo ""
        log_success "Эти сервисы НЕ будут затронуты установкой rublock"
        log_info "rublock влияет только на DNS резолвинг (порт 53)"
    fi
    
    echo ""
}

#===============================================================================
# Показать инструкцию по интеграции с BIND
#===============================================================================
show_bind_integration_guide() {
    print_header "Интеграция rublock с BIND"
    
    cat << 'BINDGUIDE'
Для интеграции rublock с BIND, вам нужно вручную настроить 
форвардинг доменов через Tor DNS.

1. Создайте файл /etc/bind/rublock-zones.conf:
   
   # Форвард заблокированных доменов через Tor
   zone "example-blocked-domain.com" {
       type forward;
       forward only;
       forwarders { 127.0.0.1 port 9053; };
   };

2. Подключите его в /etc/bind/named.conf:
   
   include "/etc/bind/rublock-zones.conf";

3. Используйте скрипт для генерации зон из списка rublock.

4. Установите только Tor:
   apt install tor
   
   Настройте /etc/tor/torrc с DNSPort 127.0.0.1:9053

5. Перезапустите BIND:
   systemctl restart named

Для автоматизации создайте скрипт конвертации rublock списков
в формат BIND зон.

BINDGUIDE
}

#===============================================================================
# Установка пакетов
#===============================================================================
install_packages() {
    print_header "Шаг 1/8: Установка пакетов"
    
    # Определяем нужные пакеты
    local packages="tor tor-geoipdb iptables-persistent lua5.4 lua-socket lua-sec obfs4proxy curl dnsutils"
    
    # Добавляем dnsmasq только если не используем альтернативный порт с существующим DNS
    if [ "$DNSMASQ_ALT_PORT" != "1" ] || ! dpkg -l dnsmasq &>/dev/null; then
        packages="$packages dnsmasq"
    fi
    
    log_info "Будут установлены следующие пакеты:"
    echo ""
    echo "    $packages"
    echo ""
    
    if ! confirm "Продолжить установку пакетов?" "y"; then
        log_error "Установка отменена пользователем"
        exit 1
    fi
    
    log_info "Обновление списка пакетов..."
    apt-get update -qq
    
    log_info "Установка пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages
    
    local installed_count
    installed_count=$(dpkg -l $packages 2>/dev/null | grep -c "^ii" || echo 0)
    log_success "Установлено пакетов: $installed_count"
}

#===============================================================================
# Настройка мостов Tor
#===============================================================================
configure_bridges() {
    print_header "Шаг 2/8: Настройка мостов Tor (obfs4)"
    
    log_info "Мосты Tor помогают обходить блокировку Tor в вашей стране."
    log_info "Если Tor работает без мостов - они не нужны."
    echo ""
    log_warning "ВАЖНО: При использовании мостов, исключение стран (ExcludeNodes)"
    log_warning "        будет применяться только к выходным узлам (Exit nodes)."
    log_warning "        Это необходимо, т.к. мосты могут быть в любой стране."
    echo ""
    log_info "Получить мосты можно:"
    echo "    1. https://bridges.torproject.org/"
    echo "    2. Telegram: @GetBridgesBot"
    echo "    3. Email: bridges@torproject.org"
    echo ""
    
    if confirm "Включить использование мостов obfs4?"; then
        USE_BRIDGES=1
        
        echo ""
        log_info "Введите мосты (по одному на строку)."
        log_info "Формат: obfs4 IP:PORT FINGERPRINT cert=... iat-mode=0"
        log_info "Когда закончите, введите пустую строку (просто нажмите Enter)."
        echo ""
        
        BRIDGES_LIST=""
        local bridge_count=0
        
        while true; do
            echo -n "Мост $((bridge_count + 1)): "
            read -r bridge_line
            
            # Проверка на пустую строку
            if [[ -z "$bridge_line" ]]; then
                break
            fi
            
            # Добавляем Bridge в начало если его нет
            if [[ ! "$bridge_line" =~ ^Bridge[[:space:]] ]]; then
                bridge_line="Bridge $bridge_line"
            fi
            
            BRIDGES_LIST="${BRIDGES_LIST}${bridge_line}"$'\n'
            ((bridge_count++))
            log_success "Мост добавлен"
        done
        
        if [[ $bridge_count -eq 0 ]]; then
            log_warning "Мосты не введены. Отключаю использование мостов."
            USE_BRIDGES=0
        else
            echo ""
            log_success "Добавлено мостов: $bridge_count"
            log_info "Режим: ExcludeNodes будет применяться только к Exit-нодам"
        fi
    else
        log_info "Мосты не используются"
    fi
}

#===============================================================================
# Настройка исключения стран
#===============================================================================
configure_countries() {
    print_header "Шаг 3/8: Настройка исключения стран"
    
    log_info "По умолчанию исключаются узлы Tor из стран СНГ:"
    echo ""
    echo "    RU (Россия), BY (Беларусь), KZ (Казахстан)"
    echo "    KG (Киргизия), UZ (Узбекистан), TJ (Таджикистан)"
    echo "    TM (Туркменистан), AZ (Азербайджан), AM (Армения)"
    echo ""
    
    if [[ $USE_BRIDGES -eq 1 ]]; then
        log_warning "Используются мосты: исключение применится только к Exit-нодам"
    else
        log_info "Мосты отключены: исключение применится ко всем узлам"
    fi
    echo ""
    
    if confirm "Использовать список по умолчанию?" "y"; then
        EXCLUDE_COUNTRIES="{ru},{by},{kz},{kg},{uz},{tj},{tm},{az},{am}"
        log_success "Используется список по умолчанию"
    else
        log_question "Введите коды стран через запятую (например: ru,by,kz): "
        read -r countries_input
        
        if [[ -n "$countries_input" ]]; then
            # Форматируем ввод: убираем пробелы, оборачиваем в {}
            EXCLUDE_COUNTRIES=$(echo "$countries_input" | tr -d ' ' | sed 's/,/},{/g' | sed 's/^/{/' | sed 's/$/}/')
            log_success "Исключаемые страны: $EXCLUDE_COUNTRIES"
        else
            EXCLUDE_COUNTRIES="{ru},{by},{kz},{kg},{uz},{tj},{tm},{az},{am}"
            log_warning "Используется список по умолчанию"
        fi
    fi
}

#===============================================================================
# Настройка IPv6 для Tor
#===============================================================================
configure_ipv6() {
    print_header "Шаг 4/8: Настройка IPv6 для Tor"
    
    log_info "IPv6 позволяет Tor использовать больше узлов для соединения."
    log_info "Это увеличивает анонимность и может улучшить скорость."
    echo ""
    
    if [[ -n "$MAIN_IP6" ]]; then
        log_success "IPv6 обнаружен: $MAIN_IP6"
        log_info "Рекомендуется включить поддержку IPv6"
    else
        log_warning "IPv6 адрес не обнаружен на интерфейсе"
        log_info "Можно включить IPv6 для исходящих соединений Tor"
    fi
    echo ""
    
    if confirm "Включить поддержку IPv6 в Tor?" "y"; then
        USE_IPV6=1
        IPV6_SETTING_USE="1"
        IPV6_SETTING_PREFER="1"
        log_success "IPv6 включён (Tor будет использовать IPv4 и IPv6)"
    else
        USE_IPV6=0
        IPV6_SETTING_USE="0"
        IPV6_SETTING_PREFER="0"
        log_info "IPv6 отключён (Tor будет использовать только IPv4)"
    fi
}

#===============================================================================
# Создание директорий и Lua скрипта
#===============================================================================
setup_directories() {
    print_header "Шаг 5/8: Подготовка директорий и скриптов"
    
    # Создание директорий
    mkdir -p "$RUBLOCK_DIR"
    mkdir -p "$BACKUP_DIR"
    chmod 755 "$RUBLOCK_DIR"
    
    # Создание пустого файла списков если не существует
    if [ ! -f "$RUBLOCK_DNSMASQ_FILE" ]; then
        touch "$RUBLOCK_DNSMASQ_FILE"
    fi
    chmod 644 "$RUBLOCK_DNSMASQ_FILE"
    
    # Создание улучшенного Lua скрипта для парсинга списков
    # Используем переменную TOR_DNS_PORT для настройки порта
    cat > "$RUBLOCK_SCRIPT" << LUAEOF
#!/usr/bin/env lua

--[[
================================================================================
  rublock.lua - Обновление списков заблокированных доменов для Tor
  Version: 2.0
================================================================================
--]]

local https = require("ssl.https")
local ltn12 = require("ltn12")

--------------------------------------------------------------------------------
-- Конфигурация
--------------------------------------------------------------------------------
local CONFIG = {
    source_url_gz = "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv.gz",
    
    extra_sources = {
        "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst",
        "https://community.antifilter.download/list/domains.lst",
        "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst"
    },
    
    output_file = "${RUBLOCK_DNSMASQ_FILE}",
    temp_file = "/tmp/rublock_domains.tmp",
    temp_gz = "/tmp/rublock_dump.csv.gz",
    temp_csv = "/tmp/rublock_dump.csv",
    
    tor_dns = "127.0.0.1#${TOR_DNS_PORT}",
    
    exclude_domains = {
        ["google.com"] = true,
        ["google.ru"] = true,
        ["googleapis.com"] = true,
        ["googleusercontent.com"] = true,
        ["gstatic.com"] = true,
        ["googlevideo.com"] = true,
        ["youtube.com"] = true,
        ["youtu.be"] = true,
        ["ytimg.com"] = true,
        ["ggpht.com"] = true,
        ["facebook.com"] = true,
        ["fbcdn.net"] = true,
        ["instagram.com"] = true,
        ["whatsapp.com"] = true,
        ["whatsapp.net"] = true,
        ["cloudflare.com"] = true,
        ["cloudflare-dns.com"] = true,
        ["amazonaws.com"] = true,
        ["azure.com"] = true,
        ["apple.com"] = true,
        ["icloud.com"] = true,
        ["microsoft.com"] = true,
        ["live.com"] = true,
        ["github.com"] = true,
        ["githubusercontent.com"] = true,
        ["twitter.com"] = true,
        ["linkedin.com"] = true
    },
    
    max_download_time = 600,
    progress_interval = 50000
}

local function log(msg)
    io.stdout:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
    io.stdout:flush()
end

local function log_separator(char)
    char = char or "="
    log(string.rep(char, 70))
end

local function download_with_curl(url, filepath)
    local safe_filepath = filepath:gsub("'", "'\\\\''")
    local safe_url = url:gsub("'", "'\\\\''")
    
    local cmd = string.format(
        "curl -L -s -f --max-time %d -o '%s' '%s' 2>&1",
        CONFIG.max_download_time,
        safe_filepath,
        safe_url
    )
    
    local handle = io.popen(cmd)
    if handle then
        local output = handle:read("*a") or ""
        local success = handle:close()
        
        local test_file = io.open(filepath, "r")
        if success and test_file then
            test_file:close()
            return true
        end
    end
    
    cmd = string.format(
        "wget -q -T %d -O '%s' '%s' 2>&1",
        CONFIG.max_download_time,
        safe_filepath,
        safe_url
    )
    
    handle = io.popen(cmd)
    if handle then
        local output = handle:read("*a") or ""
        local success = handle:close()
        
        local test_file = io.open(filepath, "r")
        if success and test_file then
            test_file:close()
            return true
        end
    end
    
    return false, "Не удалось загрузить через curl или wget"
end

local function download_to_memory(url)
    local response = {}
    
    local result, status_code = https.request{
        url = url,
        sink = ltn12.sink.table(response),
        protocol = "any",
        options = {"all"},
        verify = "none",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; rublock/2.0)"
        }
    }
    
    if status_code == 200 then
        return table.concat(response)
    else
        return nil, "HTTP " .. tostring(status_code)
    end
end

local function get_file_size(filepath)
    local file = io.open(filepath, "rb")
    if not file then return 0 end
    
    local current = file:seek()
    local size = file:seek("end")
    file:seek("set", current)
    file:close()
    
    return size or 0
end

local function format_size(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
end

local function gunzip_file(gz_path, output_path)
    local safe_gz = gz_path:gsub("'", "'\\\\''")
    local safe_out = output_path:gsub("'", "'\\\\''")
    
    local cmd = string.format("gunzip -c '%s' > '%s' 2>&1", safe_gz, safe_out)
    
    local handle = io.popen(cmd)
    if not handle then
        return false, "Не удалось запустить gunzip"
    end
    
    local result = handle:read("*a") or ""
    local success = handle:close()
    
    if success then
        return true
    else
        return false, result
    end
end

local function read_file(filepath)
    local file, err = io.open(filepath, "r")
    if not file then
        return nil, "Не удалось открыть: " .. (err or "unknown")
    end
    
    local content = file:read("*all")
    file:close()
    
    if not content or #content == 0 then
        return nil, "Файл пустой"
    end
    
    return content
end

local function is_valid_domain(domain)
    if not domain or #domain < 4 or #domain > 253 then
        return false
    end
    
    if not domain:find(".", 1, true) then
        return false
    end
    
    if domain:match("^[%.%-]") or domain:match("[%.%-]$") then
        return false
    end
    
    if not domain:match("^[%w%.%-]+$") then
        return false
    end
    
    if domain:match("^%d+%.%d+%.%d+%.%d+$") then
        return false
    end
    
    if domain:find("..", 1, true) then
        return false
    end
    
    local dot_count = select(2, domain:gsub("%.", ""))
    if dot_count < 1 then
        return false
    end
    
    return true
end

local function is_excluded(domain)
    if CONFIG.exclude_domains[domain] then
        return true
    end
    
    local parts = {}
    for part in domain:gmatch("[^.]+") do
        table.insert(parts, part)
    end
    
    for i = 2, #parts do
        local parent = table.concat(parts, ".", i)
        if CONFIG.exclude_domains[parent] then
            return true
        end
    end
    
    return false
end

local function clean_domain(domain)
    if not domain then return nil end
    
    domain = domain:lower()
    domain = domain:gsub("^%s+", ""):gsub("%s+$", "")
    domain = domain:gsub("^www%.", "")
    domain = domain:gsub("^%*%.", "")
    domain = domain:gsub("^https?://", "")
    domain = domain:gsub("^ftp://", "")
    domain = domain:gsub("[:/].*$", "")
    domain = domain:gsub("%?.*$", "")
    domain = domain:gsub("%.$", "")
    
    return domain
end

local function parse_csv(content, domains, seen)
    local count = 0
    local line_num = 0
    local total_lines = select(2, content:gsub("\n", "\n")) + 1
    
    log("    Всего строк в CSV: " .. total_lines)
    
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        
        if line_num % 10000 == 0 then
            log(string.format("    Обработано строк: %d/%d", line_num, total_lines))
        end
        
        if line_num > 1 and not line:match("^Updated:") and not line:match("^%s*$") then
            local separator = ";"
            if not line:find(";") and line:find("|") then
                separator = "|"
            end
            
            local fields = {}
            for field in (line .. separator):gmatch("([^" .. separator .. "]*)" .. separator) do
                table.insert(fields, field)
            end
            
            if fields[2] and fields[2] ~= "" then
                for raw_domain in fields[2]:gmatch("([^,|;%s]+)") do
                    local domain = clean_domain(raw_domain)
                    
                    if domain and is_valid_domain(domain) and not seen[domain] and not is_excluded(domain) then
                        seen[domain] = true
                        table.insert(domains, domain)
                        count = count + 1
                    end
                end
            end
            
            if fields[3] and fields[3] ~= "" then
                local url_domain = fields[3]:match("https?://([^/]+)")
                if url_domain then
                    local domain = clean_domain(url_domain)
                    if domain and is_valid_domain(domain) and not seen[domain] and not is_excluded(domain) then
                        seen[domain] = true
                        table.insert(domains, domain)
                        count = count + 1
                    end
                end
            end
        end
    end
    
    return count
end

local function parse_list(content, domains, seen)
    local count = 0
    
    for line in content:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local domain = clean_domain(line)
            
            if domain and is_valid_domain(domain) and not seen[domain] and not is_excluded(domain) then
                seen[domain] = true
                table.insert(domains, domain)
                count = count + 1
            end
        end
    end
    
    return count
end

local function main()
    log_separator()
    log("rublock - Обновление списков заблокированных доменов")
    log_separator()
    log("")
    
    local all_domains = {}
    local seen = {}
    local stats = {
        sources_total = 0,
        sources_ok = 0,
        start_time = os.time()
    }
    
    os.remove(CONFIG.temp_gz)
    os.remove(CONFIG.temp_csv)
    os.remove(CONFIG.temp_file)
    
    stats.sources_total = stats.sources_total + 1
    log("[1/4] Основной источник: zapret-info (РКН dump)")
    log("    URL: " .. CONFIG.source_url_gz)
    log("    Загрузка (может занять несколько минут)...")
    
    local ok, err = download_with_curl(CONFIG.source_url_gz, CONFIG.temp_gz)
    
    if ok then
        local size = get_file_size(CONFIG.temp_gz)
        log("    Размер архива: " .. format_size(size))
        
        if size > 0 then
            log("    Распаковка gzip...")
            local gunzip_ok, gunzip_err = gunzip_file(CONFIG.temp_gz, CONFIG.temp_csv)
            
            if gunzip_ok then
                local csv_size = get_file_size(CONFIG.temp_csv)
                log("    Размер CSV: " .. format_size(csv_size))
                
                log("    Парсинг CSV (это может занять 1-2 минуты)...")
                local content, read_err = read_file(CONFIG.temp_csv)
                
                if content then
                    local count = parse_csv(content, all_domains, seen)
                    stats.sources_ok = stats.sources_ok + 1
                    log("    ✓ Успешно извлечено доменов: " .. count)
                else
                    log("    ✗ Ошибка чтения CSV: " .. (read_err or "unknown"))
                end
                
                content = nil
                collectgarbage("collect")
                os.remove(CONFIG.temp_csv)
            else
                log("    ✗ Ошибка распаковки: " .. (gunzip_err or "unknown"))
            end
        else
            log("    ✗ Загруженный файл пустой")
        end
        
        os.remove(CONFIG.temp_gz)
    else
        log("    ✗ Ошибка загрузки: " .. (err or "unknown"))
    end
    
    for i, url in ipairs(CONFIG.extra_sources) do
        stats.sources_total = stats.sources_total + 1
        log("")
        log(string.format("[%d/%d] Дополнительный источник", i + 1, stats.sources_total))
        log("    URL: " .. url)
        log("    Загрузка...")
        
        local content, err = download_to_memory(url)
        if content then
            local count = parse_list(content, all_domains, seen)
            stats.sources_ok = stats.sources_ok + 1
            log("    ✓ Извлечено доменов: " .. count)
            
            content = nil
            collectgarbage("collect")
        else
            log("    ✗ Ошибка: " .. (err or "unknown"))
        end
    end
    
    log("")
    log_separator()
    log("ИТОГОВАЯ СТАТИСТИКА:")
    log("  Источников обработано: " .. stats.sources_ok .. "/" .. stats.sources_total)
    log("  Уникальных доменов:    " .. #all_domains)
    log("  Время загрузки:        " .. (os.time() - stats.start_time) .. " сек")
    log_separator()
    
    if #all_domains == 0 then
        log("")
        log("КРИТИЧЕСКАЯ ОШИБКА: Список пуст!")
        log("Проверьте подключение к интернету и доступность источников")
        os.exit(1)
    end
    
    log("")
    log("Сортировка доменов по алфавиту...")
    table.sort(all_domains)
    log("✓ Сортировка завершена")
    
    log("")
    log("Запись в файл: " .. CONFIG.output_file)
    
    local file, file_err = io.open(CONFIG.temp_file, "w")
    if not file then
        log("ОШИБКА: Не удалось создать файл: " .. (file_err or "unknown"))
        os.exit(1)
    end
    
    file:write("# " .. string.rep("=", 70) .. "\n")
    file:write("# rublock domains list for dnsmasq\n")
    file:write("# \n")
    file:write("# Generated:  " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    file:write("# Domains:    " .. #all_domains .. "\n")
    file:write("# Sources:    " .. stats.sources_ok .. "/" .. stats.sources_total .. "\n")
    file:write("# Tor DNS:    " .. CONFIG.tor_dns .. "\n")
    file:write("# \n")
    file:write("# " .. string.rep("=", 70) .. "\n")
    file:write("\n")
    
    log("  Запись доменов...")
    for i, domain in ipairs(all_domains) do
        file:write("server=/" .. domain .. "/" .. CONFIG.tor_dns .. "\n")
        
        if i % 50000 == 0 then
            log(string.format("  Записано: %d/%d", i, #all_domains))
        end
    end
    
    file:close()
    log("✓ Запись завершена")
    
    log("")
    log("Применение изменений...")
    os.execute("mv '" .. CONFIG.temp_file:gsub("'", "'\\\\''") .. "' '" .. CONFIG.output_file:gsub("'", "'\\\\''") .. "'")
    os.execute("chmod 644 '" .. CONFIG.output_file:gsub("'", "'\\\\''") .. "'")
    log("✓ Файл сохранён: " .. CONFIG.output_file)
    
    log("")
    log("Перезагрузка dnsmasq...")
    
    local reload_result = os.execute("systemctl reload dnsmasq 2>/dev/null")
    if reload_result ~= 0 and reload_result ~= true then
        log("  reload не сработал, пробую restart...")
        os.execute("systemctl restart dnsmasq 2>/dev/null")
    end
    
    log("✓ dnsmasq обновлён")
    
    local total_time = os.time() - stats.start_time
    
    log("")
    log_separator("=")
    log("✓✓✓ ОБНОВЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО ✓✓✓")
    log_separator("=")
    log("")
    log("  Всего доменов:  " .. #all_domains)
    log("  Общее время:    " .. total_time .. " сек")
    log("  Файл:           " .. CONFIG.output_file)
    log("")
    log_separator("=")
    log("")
end

local status, err = pcall(main)

if not status then
    log("")
    log_separator("!")
    log("ФАТАЛЬНАЯ ОШИБКА:")
    log(tostring(err))
    log_separator("!")
    log("")
    os.exit(1)
end
LUAEOF

    chmod +x "$RUBLOCK_SCRIPT"
    log_success "Lua скрипт установлен (поддержка ~970K доменов)"
}

#===============================================================================
# Создание скрипта обновления
#===============================================================================
create_update_script() {
    print_header "Шаг 6/8: Создание скрипта обновления"
    
    cat > "$RUBLOCK_UPDATE_SCRIPT" << UPDATEEOF
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
        echo "[OK] Обновление успешно завершено"
    else
        echo "[ERROR] Ошибка обновления (код: \$EXIT_CODE)"
    fi
else
    echo "[ERROR] Скрипт \$RUBLOCK_SCRIPT не найден или не исполняем"
    exit 1
fi

echo ""
UPDATEEOF

    chmod +x "$RUBLOCK_UPDATE_SCRIPT"
    log_success "Скрипт обновления создан: $RUBLOCK_UPDATE_SCRIPT"
}

#===============================================================================
# Настройка dnsmasq
#===============================================================================
configure_dnsmasq() {
    print_header "Настройка dnsmasq"
    
    local listen_port="${DNSMASQ_PORT}"
    
    log_info "dnsmasq будет настроен как DNS-сервер для локальной сети."
    echo ""
    echo "    Слушать на:          127.0.0.1:$listen_port и $MAIN_IP:$listen_port"
    echo "    Upstream DNS:        8.8.8.8, 8.8.4.4, 1.1.1.1"
    echo "    Заблокированные:     → Tor DNS (127.0.0.1:${TOR_DNS_PORT})"
    echo ""
    
    if [ "$listen_port" != "53" ]; then
        log_warning "Используется нестандартный порт $listen_port"
        log_warning "Клиенты должны явно указывать этот порт для DNS!"
    fi
    
    if ! confirm "Продолжить настройку dnsmasq?" "y"; then
        log_error "Настройка отменена пользователем"
        exit 1
    fi
    
    # Создание резервной копии если не создан бэкап
    if [ $BACKUP_CREATED -eq 0 ]; then
        if [ -f /etc/dnsmasq.conf ]; then
            cp /etc/dnsmasq.conf "/etc/dnsmasq.conf.bak.$(date +%Y%m%d_%H%M%S)"
        fi
    fi
    
    # Создаём директорию для конфигов dnsmasq если не существует
    mkdir -p "$(dirname "$DNSMASQ_CONF")"
    
    # Создание конфигурации rublock
    cat > "$DNSMASQ_CONF" << DNSMASQEOF
# ═══════════════════════════════════════════════════════════════════════════
#                    rublock dnsmasq Configuration
# ═══════════════════════════════════════════════════════════════════════════
# Generated: $(date)
# Server IP: $MAIN_IP
# Port: $listen_port

# Listen addresses
listen-address=127.0.0.1
listen-address=$MAIN_IP
DNSMASQEOF

    # Добавляем порт если не стандартный
    if [ "$listen_port" != "53" ]; then
        echo "port=$listen_port" >> "$DNSMASQ_CONF"
    fi
    
    cat >> "$DNSMASQ_CONF" << DNSMASQEOF
bind-interfaces

# Upstream DNS servers
no-resolv
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1

# Cache settings
cache-size=10000

# rublock domains list
conf-file=$RUBLOCK_DNSMASQ_FILE

# .onion domains -> Tor DNS
server=/onion/127.0.0.1#${TOR_DNS_PORT}
DNSMASQEOF

    log_success "Конфигурация dnsmasq создана"
}

#===============================================================================
# Настройка Tor
#===============================================================================
configure_tor() {
    print_header "Шаг 7/8: Конфигурация Tor"
    
    local bridges_status="отключены"
    local node_policy="все узлы (Entry, Middle, Exit)"
    
    if [[ $USE_BRIDGES -eq 1 ]]; then
        bridges_status="включены"
        node_policy="только Exit-ноды (Entry/Middle - любые страны)"
    fi
    
    local ipv6_status="отключён (только IPv4)"
    if [[ $USE_IPV6 -eq 1 ]]; then
        ipv6_status="включён"
    fi
    
    log_info "Tor будет настроен со следующими параметрами:"
    echo ""
    echo "    SOCKS прокси:        127.0.0.1:9050 и $MAIN_IP:9050"
    echo "    DNS прокси:          127.0.0.1:${TOR_DNS_PORT} и $MAIN_IP:${TOR_DNS_PORT}"
    echo "    Trans прокси:        127.0.0.1:9040 и $MAIN_IP:9040"
    echo "    IPv6:                $ipv6_status"
    echo "    Мосты:               $bridges_status"
    echo "    Исключены страны:    $EXCLUDE_COUNTRIES"
    echo "    Политика:            $node_policy"
    echo ""
    
    if ! confirm "Продолжить настройку Tor?" "y"; then
        log_error "Настройка отменена пользователем"
        exit 1
    fi
    
    # Создание резервной копии если не создан бэкап
    if [ $BACKUP_CREATED -eq 0 ]; then
        if [ -f "$TOR_CONF" ]; then
            cp "$TOR_CONF" "${TOR_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        fi
    fi
    
    # Создание конфигурации Tor
    cat > "$TOR_CONF" << TOREOF
# ═══════════════════════════════════════════════════════════════════════════
#                    rublock-tor Configuration
#                      for Debian 12
# ═══════════════════════════════════════════════════════════════════════════
# Generated: $(date)
# Server IP: $MAIN_IP

# ───────────────────────────────────────────────────────────────────────────
# SYSTEM
# ───────────────────────────────────────────────────────────────────────────
User debian-tor
DataDirectory /var/lib/tor
Log notice file /var/log/tor/notices.log
Log notice syslog

# ───────────────────────────────────────────────────────────────────────────
# SOCKS PROXY
# ───────────────────────────────────────────────────────────────────────────
SocksPort 127.0.0.1:9050
SocksPort $MAIN_IP:9050

# ───────────────────────────────────────────────────────────────────────────
# DNS PROXY
# ───────────────────────────────────────────────────────────────────────────
DNSPort 127.0.0.1:${TOR_DNS_PORT}
DNSPort $MAIN_IP:${TOR_DNS_PORT}

# ───────────────────────────────────────────────────────────────────────────
# TRANSPARENT PROXY
# ───────────────────────────────────────────────────────────────────────────
TransPort 127.0.0.1:9040
TransPort $MAIN_IP:9040

# ───────────────────────────────────────────────────────────────────────────
# VIRTUAL ADDRESS MAPPING (.onion)
# ───────────────────────────────────────────────────────────────────────────
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1

# ───────────────────────────────────────────────────────────────────────────
# CLIENT MODE (не relay, не exit - только клиент)
# ───────────────────────────────────────────────────────────────────────────
ClientOnly 1
ExitRelay 0

# ───────────────────────────────────────────────────────────────────────────
# IPv6 SUPPORT
# ───────────────────────────────────────────────────────────────────────────
ClientUseIPv4 1
ClientUseIPv6 $IPV6_SETTING_USE
ClientPreferIPv6ORPort $IPV6_SETTING_PREFER

# ───────────────────────────────────────────────────────────────────────────
# BRIDGES
# ───────────────────────────────────────────────────────────────────────────
UseBridges $USE_BRIDGES
TOREOF

    # Добавление мостов если включены
    if [[ $USE_BRIDGES -eq 1 && -n "$BRIDGES_LIST" ]]; then
        cat >> "$TOR_CONF" << BRIDGESEOF
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy

# Configured bridges:
$BRIDGES_LIST
BRIDGESEOF
    fi
    
    # Добавление политики исключения стран
    cat >> "$TOR_CONF" << TOREOF2

# ───────────────────────────────────────────────────────────────────────────
# NODE RESTRICTIONS (исключение стран)
# ───────────────────────────────────────────────────────────────────────────
TOREOF2

    # Если мосты включены - мягкая политика (только Exit ноды)
    if [[ $USE_BRIDGES -eq 1 ]]; then
        cat >> "$TOR_CONF" << BRIDGEPOLICY
# При использовании мостов:
# - Мосты (Entry) могут быть из любых стран (иначе они не работают)
# - Исключение применяется только к Exit-нодам
# - StrictNodes=0 позволяет использовать мосты из исключённых стран
ExcludeExitNodes $EXCLUDE_COUNTRIES
StrictNodes 0

# ВАЖНО: Entry и Middle ноды могут быть из любых стран, включая СНГ.
# Это безопасно, т.к. они не видят ваш финальный трафик.
# Exit-ноды (видят трафик) исключены из СНГ стран.
BRIDGEPOLICY
    else
        # Без мостов - жёсткая политика (все типы узлов)
        cat >> "$TOR_CONF" << STRICTPOLICY
# Без мостов (прямое подключение к Tor):
# - Исключаем СНГ страны для всех типов узлов
# - StrictNodes=1 строго запрещает использование этих стран
ExcludeNodes $EXCLUDE_COUNTRIES
ExcludeExitNodes $EXCLUDE_COUNTRIES
StrictNodes 1
STRICTPOLICY
    fi

    # Опциональные настройки
    cat >> "$TOR_CONF" << TOREOF3

# Optional: Prefer specific exit countries (uncomment to use)
# Предпочитаемые страны для Exit-нод (раскомментируйте при необходимости)
# Рекомендуемые страны: Польша, Германия, Нидерланды, Швеция, Швейцария
# ExitNodes {pl},{de},{nl},{se},{ch}

# ───────────────────────────────────────────────────────────────────────────
# PERFORMANCE TUNING
# ───────────────────────────────────────────────────────────────────────────
CircuitBuildTimeout 30
LearnCircuitBuildTimeout 1
NumEntryGuards 3
TOREOF3

    log_success "Конфигурация Tor создана"
}

#===============================================================================
# Настройка systemd
#===============================================================================
configure_systemd() {
    print_header "Настройка systemd"
    
    # Создание systemd service
    cat > /etc/systemd/system/rublock-update.service << SERVICEEOF
[Unit]
Description=rublock List Updater
After=network-online.target tor.service
Wants=network-online.target
Requires=tor.service

[Service]
Type=oneshot
ExecStart=$RUBLOCK_UPDATE_SCRIPT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

    # Создание systemd timer
    cat > /etc/systemd/system/rublock-update.timer << TIMEREOF
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
TIMEREOF

    # Перезагрузка systemd и активация таймера
    systemctl daemon-reload
    systemctl enable rublock-update.timer
    systemctl start rublock-update.timer
    
    log_success "Systemd unit-файлы созданы и активированы"
}

#===============================================================================
# Запуск сервисов
#===============================================================================
start_services() {
    print_header "Шаг 8/8: Запуск сервисов"
    
    # Обработка systemd-resolved
    if [ "$DISABLE_RESOLVED" = "1" ]; then
        log_info "Отключение systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
        
        # Создаём новый resolv.conf
        rm -f /etc/resolv.conf
        echo "# Generated by rublock installer" > /etc/resolv.conf
        echo "nameserver 127.0.0.1" >> /etc/resolv.conf
        log_success "systemd-resolved отключён"
    fi
    
    # Обработка BIND
    if [ "$DISABLE_BIND" = "1" ]; then
        log_info "Отключение BIND..."
        systemctl stop named 2>/dev/null || true
        systemctl disable named 2>/dev/null || true
        log_success "BIND отключён"
    fi
    
    # Ждём освобождения портов
    sleep 2
    
    # Проверка порта 53 (или альтернативного)
    local listen_port="${DNSMASQ_PORT}"
    local port_check
    port_check=$(ss -tulpn 2>/dev/null | grep ":$listen_port " | grep -v dnsmasq || true)
    
    if [ -n "$port_check" ]; then
        log_warning "Порт $listen_port всё ещё занят:"
        echo "$port_check" | sed 's/^/    /'
        
        if ! confirm "Попробовать продолжить?" "n"; then
            log_error "Установка прервана"
            exit 1
        fi
    fi
    
    # Остановка сервисов перед запуском
    log_info "Останавливаю сервисы для перенастройки..."
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl stop tor 2>/dev/null || true
    sleep 2
    
    # Настройка прав для Tor
    log_info "Настройка прав доступа..."
    chown -R debian-tor:debian-tor /var/lib/tor
    chmod 700 /var/lib/tor
    mkdir -p /var/log/tor
    chown -R debian-tor:adm /var/log/tor
    chmod 750 /var/log/tor
    
    # Запуск Tor
    log_info "Запуск Tor..."
    systemctl start tor
    
    sleep 3
    
    if ! systemctl is-active --quiet tor; then
        log_error "Tor не запустился!"
        log_info "Логи Tor:"
        journalctl -xeu tor.service --no-pager -n 20
        exit 1
    fi
    log_success "Tor запущен"
    
    # Запуск dnsmasq
    log_info "Запуск dnsmasq..."
    systemctl start dnsmasq
    
    if ! systemctl is-active --quiet dnsmasq; then
        log_error "dnsmasq не запустился!"
        log_info "Логи dnsmasq:"
        journalctl -xeu dnsmasq.service --no-pager -n 20
        exit 1
    fi
    log_success "dnsmasq запущен"
    
    # Включение автозапуска
    systemctl enable tor
    systemctl enable dnsmasq
    
    # ========================================================================
    # Первое обновление списков С ВЫВОДОМ ПРОГРЕССА
    # ========================================================================
    echo ""
    log_info "Выполняю первое обновление списков..."
    log_info "Это может занять несколько минут..."
    echo ""
    
    # Запускаем Lua скрипт напрямую с выводом в консоль
    if "$RUBLOCK_SCRIPT"; then
        echo ""
        log_success "Списки успешно загружены"
    else
        echo ""
        log_warning "Ошибка при загрузке списков (будет повторено по расписанию)"
        log_info "Проверьте логи: tail -f $LOG_FILE"
    fi
}

#===============================================================================
# Тестирование
#===============================================================================
run_tests() {
    print_header "Тестирование"
    
    if ! confirm "Выполнить тесты работоспособности?" "y"; then
        return 0
    fi
    
    local listen_port="${DNSMASQ_PORT}"
    
    echo ""
    log_info "Проверка портов..."
    echo ""
    echo "  Tor порты:"
    ss -tulpn 2>/dev/null | grep -E ":(9050|${TOR_DNS_PORT}|9040)" | sed 's/^/    /' || echo "    Порты Tor не найдены!"
    echo ""
    echo "  DNS порт ($listen_port):"
    ss -tulpn 2>/dev/null | grep ":$listen_port " | sed 's/^/    /' || echo "    Порт $listen_port не найден!"
    echo ""
    
    log_info "Проверка DNS (dnsmasq)..."
    local dns_result
    if [ "$listen_port" = "53" ]; then
        dns_result=$(dig @127.0.0.1 google.com +short +time=5 2>/dev/null | head -1)
    else
        dns_result=$(dig @127.0.0.1 -p "$listen_port" google.com +short +time=5 2>/dev/null | head -1)
    fi
    
    if [[ -n "$dns_result" ]]; then
        log_success "DNS работает"
        echo "    google.com → $dns_result"
    else
        log_error "DNS не работает"
    fi
    echo ""
    
    log_info "Проверка Tor DNS (порт ${TOR_DNS_PORT})..."
    local tor_dns_result
    tor_dns_result=$(dig @127.0.0.1 -p "${TOR_DNS_PORT}" google.com +short +time=10 2>/dev/null | head -1)
    if [[ -n "$tor_dns_result" ]]; then
        log_success "Tor DNS работает"
        echo "    google.com → $tor_dns_result"
    else
        log_warning "Tor DNS не отвечает"
    fi
    echo ""
    
    log_info "Проверка Tor SOCKS (localhost)..."
    log_info "Подождите до 30 секунд для установки соединения с Tor..."
    local tor_check
    tor_check=$(curl --max-time 30 --socks5-hostname 127.0.0.1:9050 -s https://check.torproject.org/api/ip 2>/dev/null)
    if [[ -n "$tor_check" ]] && echo "$tor_check" | grep -q "IsTor"; then
        local tor_ip
        tor_ip=$(echo "$tor_check" | grep -oP '"IP":"[^"]+"' | cut -d'"' -f4)
        local is_tor
        is_tor=$(echo "$tor_check" | grep -oP '"IsTor":\w+' | cut -d':' -f2)
        log_success "Tor SOCKS localhost работает"
        echo "    Exit IP: $tor_ip"
        echo "    IsTor: $is_tor"
    else
        log_warning "Tor SOCKS localhost не отвечает"
        log_info "Tor может ещё устанавливать соединение (особенно с мостами)"
        log_info "Проверьте позже: curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip"
    fi
    echo ""
    
    log_info "Проверка Tor SOCKS (LAN: $MAIN_IP)..."
    local tor_check_lan
    tor_check_lan=$(curl --max-time 30 --socks5-hostname "$MAIN_IP:9050" -s https://check.torproject.org/api/ip 2>/dev/null)
    if [[ -n "$tor_check_lan" ]] && echo "$tor_check_lan" | grep -q "IsTor"; then
        local tor_ip_lan
        tor_ip_lan=$(echo "$tor_check_lan" | grep -oP '"IP":"[^"]+"' | cut -d'"' -f4)
        log_success "Tor SOCKS LAN работает"
        echo "    Exit IP: $tor_ip_lan"
    else
        log_warning "Tor SOCKS LAN не отвечает"
    fi
    echo ""
    
    log_info "Количество доменов в списке:"
    if [ -f "$RUBLOCK_DNSMASQ_FILE" ]; then
        local count
        count=$(grep -c "^server=/" "$RUBLOCK_DNSMASQ_FILE" 2>/dev/null || echo 0)
        echo "    $count доменов"
    else
        echo "    Файл списков не найден"
    fi
    echo ""
    
    log_info "Тест резолвинга заблокированного домена..."
    local blocked_test
    if [ "$listen_port" = "53" ]; then
        blocked_test=$(dig @127.0.0.1 rutracker.org +short +time=10 2>/dev/null | head -1)
    else
        blocked_test=$(dig @127.0.0.1 -p "$listen_port" rutracker.org +short +time=10 2>/dev/null | head -1)
    fi
    
    if [[ -n "$blocked_test" ]]; then
        log_success "Заблокированные домены резолвятся"
        echo "    rutracker.org → $blocked_test"
    else
        log_warning "Не удалось резолвить rutracker.org"
    fi
    echo ""
    
    return 0
}

#===============================================================================
# Вывод итоговой информации
#===============================================================================
print_summary() {
    local listen_port="${DNSMASQ_PORT}"
    
    echo ""
    print_header "Установка завершена!"
    
    echo -e "${GREEN}${SUCCESS} rublock-tor успешно установлен и настроен${NC}"
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " Статус сервисов"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Tor:      $(systemctl is-active tor 2>/dev/null || echo 'unknown')"
    echo "  dnsmasq:  $(systemctl is-active dnsmasq 2>/dev/null || echo 'unknown')"
    echo "  Timer:    $(systemctl is-active rublock-update.timer 2>/dev/null || echo 'unknown')"
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " Конфигурация"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  DNS сервер:        127.0.0.1:$listen_port и $MAIN_IP:$listen_port"
    echo "  Tor SOCKS:         127.0.0.1:9050 и $MAIN_IP:9050"
    echo "  Tor DNS:           127.0.0.1:${TOR_DNS_PORT} и $MAIN_IP:${TOR_DNS_PORT}"
    echo "  Tor TransPort:     127.0.0.1:9040 и $MAIN_IP:9040"
    
    if [[ $USE_BRIDGES -eq 1 ]]; then
        echo "  Мосты:             включены"
        echo "  Политика:          ExcludeNodes только для Exit-нод"
    else
        echo "  Мосты:             отключены"
        echo "  Политика:          ExcludeNodes для всех узлов (strict)"
    fi
    
    if [[ $USE_IPV6 -eq 1 ]]; then
        echo "  IPv6:              включён"
    else
        echo "  IPv6:              отключён (только IPv4)"
    fi
    
    echo ""
    echo "  Списки:            $RUBLOCK_DNSMASQ_FILE"
    echo "  Лог обновлений:    $LOG_FILE"
    echo "  Лог Tor:           /var/log/tor/notices.log"
    echo "  Конфиг Tor:        $TOR_CONF"
    
    if [ $BACKUP_CREATED -eq 1 ]; then
        echo ""
        echo "  Бэкап:             ${BACKUP_DIR}/${CURRENT_BACKUP_NAME}"
    fi
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " ВАЖНО: UDP трафик"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Tor поддерживает ТОЛЬКО TCP."
    echo "  UDP трафик (игры, VoIP, видео) НЕ затронут и работает напрямую."
    echo "  Через Tor идёт только DNS резолвинг заблокированных доменов."
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " Полезные команды"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Обновить списки:         sudo $RUBLOCK_UPDATE_SCRIPT"
    echo "  Статус Tor:              sudo systemctl status tor"
    echo "  Статус dnsmasq:          sudo systemctl status dnsmasq"
    echo "  Логи Tor:                sudo journalctl -fu tor"
    echo "  Логи dnsmasq:            sudo journalctl -fu dnsmasq"
    echo "  Логи обновлений:         tail -f $LOG_FILE"
    
    if [ "$listen_port" = "53" ]; then
        echo "  Тест DNS:                dig @127.0.0.1 google.com"
    else
        echo "  Тест DNS:                dig @127.0.0.1 -p $listen_port google.com"
    fi
    
    echo "  Тест Tor:                curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip"
    echo "  Проверка Bootstrap:      sudo grep Bootstrapped /var/log/tor/notices.log | tail -5"
    echo ""
    echo "  Восстановить бэкап:      sudo $0 --restore"
    echo "  Список бэкапов:          sudo $0 --list-backups"
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " Настройка клиентов"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    
    if [ "$listen_port" = "53" ]; then
        echo "  В настройках сети клиентов укажите DNS сервер: $MAIN_IP"
    else
        echo "  ВНИМАНИЕ: Используется нестандартный порт DNS!"
        echo "  Клиенты должны использовать: $MAIN_IP порт $listen_port"
        echo "  Большинство систем не поддерживают нестандартный DNS порт напрямую."
        echo "  Рассмотрите использование локального DNS форвардера на клиентах."
    fi
    
    echo "  Для SOCKS прокси используйте: $MAIN_IP:9050"
    echo ""
    
    if [[ $USE_BRIDGES -eq 1 ]]; then
        echo "═══════════════════════════════════════════════════════════════════════"
        echo " Важно: Используются мосты"
        echo "═══════════════════════════════════════════════════════════════════════"
        echo ""
        echo "  • Первое подключение может занять 2-5 минут"
        echo "  • Entry-ноды (мосты) могут быть из любых стран"
        echo "  • Exit-ноды ИСКЛЮЧЕНЫ из СНГ стран (безопасно)"
        echo "  • Для проверки: sudo tail -f /var/log/tor/notices.log"
        echo ""
    fi
    
    log_info "Рекомендуется перезагрузить систему для проверки автозапуска"
    echo ""
}

#===============================================================================
# Обработка аргументов командной строки
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --restore)
                check_root
                init_variables
                restore_backup_menu
                exit $?
                ;;
            --list-backups)
                check_root
                init_variables
                list_backups
                exit $?
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --restore       Восстановить из бэкапа"
                echo "  --list-backups  Показать список бэкапов"
                echo "  --help, -h      Показать эту справку"
                echo ""
                echo "Без аргументов - запуск интерактивной установки"
                exit 0
                ;;
            *)
                log_error "Неизвестный аргумент: $1"
                log_info "Используйте --help для справки"
                exit 1
                ;;
        esac
        shift
    done
}

#===============================================================================
# Главная функция
#===============================================================================
main() {
    # Обработка аргументов
    parse_args "$@"
    
    # Проверка прав
    check_root
    
    # Инициализация переменных
    init_variables
    
    # Баннер
    print_banner
    
    echo ""
    log_info "Этот скрипт установит и настроит rublock-tor для обхода блокировок."
    log_info "Заблокированные домены будут резолвиться через сеть Tor."
    echo ""
    log_important "ВАЖНО: Скрипт НЕ влияет на UDP трафик (игры, VoIP и т.д.)"
    log_important "       Tor работает только с TCP. UDP идёт напрямую."
    echo ""
    
    if ! confirm "Начать установку rublock-tor?"; then
        log_info "Установка отменена"
        exit 0
    fi
    
    # Проверка существующей установки
    check_existing_installation
    
    # Определение сети
    detect_network
    
    # Проверка совместимости сервисов
    check_service_compatibility
    
    # Установка пакетов
    install_packages
    
    # Настройка мостов
    configure_bridges
    
    # Настройка исключения стран
    configure_countries
    
    # Настройка IPv6
    configure_ipv6
    
    # Подготовка директорий
    setup_directories
    
    # Создание скрипта обновления
    create_update_script
    
    # Настройка dnsmasq
    configure_dnsmasq
    
    # Настройка Tor
    configure_tor
    
    # Настройка systemd
    configure_systemd
    
    # Запуск сервисов
    start_services
    
    # Тестирование
    run_tests
    
    # Итоговая информация
    print_summary
    
    exit 0
}

#===============================================================================
# Запуск
#===============================================================================
main "$@"
