#!/bin/bash

#===============================================================================
# rublock-tor Installer for Debian 12
# Установка и настройка rublock с Tor для обхода блокировок
# Version: 2.2
#===============================================================================

#===============================================================================
# Цвета и символы для вывода
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    echo "║                           Version 2.2                                ║"
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
    
    log_question "$prompt [$default]: "
    read -r answer
    
    if [[ -z "$answer" ]]; then
        echo "$default"
    else
        echo "$answer"
    fi
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
        MAIN_IP=$(input_with_default "Введите IPv4 адрес сервера" "$MAIN_IP")
        log_success "Используется IP: $MAIN_IP"
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

    # Настройки по умолчанию
    USE_BRIDGES=0
    BRIDGES_LIST=""
    EXCLUDE_COUNTRIES="{ru},{by},{kz},{kg},{uz},{tj},{tm},{az},{am}"
    USE_IPV6=1
    IPV6_SETTING_USE="1"
    IPV6_SETTING_PREFER="1"
}

#===============================================================================
# Установка пакетов
#===============================================================================
install_packages() {
    print_header "Шаг 1/8: Установка пакетов"
    
    PACKAGES="tor tor-geoipdb dnsmasq iptables-persistent lua5.4 lua-socket lua-sec obfs4proxy curl"
    
    log_info "Будут установлены следующие пакеты:"
    echo ""
    echo "    $PACKAGES"
    echo ""
    
    if ! confirm "Продолжить установку пакетов?" "y"; then
        log_error "Установка отменена пользователем"
        exit 1
    fi
    
    log_info "Обновление списка пакетов..."
    apt-get update -qq
    
    log_info "Установка пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PACKAGES
    
    INSTALLED_COUNT=$(dpkg -l $PACKAGES 2>/dev/null | grep -c "^ii" || echo 0)
    log_success "Установлено пакетов: $INSTALLED_COUNT"
}

#===============================================================================
# Настройка мостов Tor
#===============================================================================
configure_bridges() {
    print_header "Шаг 2/8: Настройка мостов Tor (obfs4)"
    
    log_info "Мосты Tor помогают обходить блокировку Tor в вашей стране."
    log_info "Если Tor работает без мостов - они не нужны."
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
    chmod 755 "$RUBLOCK_DIR"
    
    # Создание пустого файла списков
    touch "$RUBLOCK_DNSMASQ_FILE"
    chmod 644 "$RUBLOCK_DNSMASQ_FILE"
    
    # Создание улучшенного Lua скрипта для парсинга списков
    cat > "$RUBLOCK_SCRIPT" << 'LUAEOF'
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
    
    output_file = "/etc/rublock/rublock.dnsmasq",
    temp_file = "/tmp/rublock_domains.tmp",
    temp_gz = "/tmp/rublock_dump.csv.gz",
    temp_csv = "/tmp/rublock_dump.csv",
    
    tor_dns = "127.0.0.1#9053",
    
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
    local safe_filepath = filepath:gsub("'", "'\\''")
    local safe_url = url:gsub("'", "'\\''")
    
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
    local safe_gz = gz_path:gsub("'", "'\\''")
    local safe_out = output_path:gsub("'", "'\\''")
    
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
    os.execute("mv '" .. CONFIG.temp_file:gsub("'", "'\\''") .. "' '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
    os.execute("chmod 644 '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
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
    
    log_info "dnsmasq будет настроен как DNS-сервер для локальной сети."
    echo ""
    echo "    Слушать на:          127.0.0.1 и $MAIN_IP"
    echo "    Upstream DNS:        8.8.8.8, 8.8.4.4, 1.1.1.1"
    echo "    Заблокированные:     → Tor DNS (127.0.0.1:9053)"
    echo ""
    
    if ! confirm "Продолжить настройку dnsmasq?" "y"; then
        log_error "Настройка отменена пользователем"
        exit 1
    fi
    
    # Создание резервной копии
    if [ -f /etc/dnsmasq.conf ]; then
        cp /etc/dnsmasq.conf "/etc/dnsmasq.conf.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Создание конфигурации rublock
    cat > "$DNSMASQ_CONF" << DNSMASQEOF
# ═══════════════════════════════════════════════════════════════════════════
#                    rublock dnsmasq Configuration
# ═══════════════════════════════════════════════════════════════════════════
# Generated: $(date)
# Server IP: $MAIN_IP

# Listen addresses
listen-address=127.0.0.1
listen-address=$MAIN_IP
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
server=/onion/127.0.0.1#9053
DNSMASQEOF

    log_success "Конфигурация dnsmasq создана"
}

#===============================================================================
# Настройка Tor
#===============================================================================
configure_tor() {
    print_header "Шаг 7/8: Конфигурация Tor"
    
    local bridges_status="отключены"
    if [[ $USE_BRIDGES -eq 1 ]]; then
        bridges_status="включены"
    fi
    
    local ipv6_status="отключён (только IPv4)"
    if [[ $USE_IPV6 -eq 1 ]]; then
        ipv6_status="включён"
    fi
    
    log_info "Tor будет настроен со следующими параметрами:"
    echo ""
    echo "    SOCKS прокси:        127.0.0.1:9050 и $MAIN_IP:9050"
    echo "    DNS прокси:          127.0.0.1:9053 и $MAIN_IP:9053"
    echo "    Trans прокси:        127.0.0.1:9040 и $MAIN_IP:9040"
    echo "    IPv6:                $ipv6_status"
    echo "    Мосты:               $bridges_status"
    echo "    Исключены страны:    $EXCLUDE_COUNTRIES"
    echo ""
    
    if ! confirm "Продолжить настройку Tor?" "y"; then
        log_error "Настройка отменена пользователем"
        exit 1
    fi
    
    # Создание резервной копии
    if [ -f "$TOR_CONF" ]; then
        cp "$TOR_CONF" "${TOR_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
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
DNSPort 127.0.0.1:9053
DNSPort $MAIN_IP:9053

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
# CLIENT MODE
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
    
    # Продолжение конфига
    cat >> "$TOR_CONF" << TOREOF2

# ───────────────────────────────────────────────────────────────────────────
# NODE RESTRICTIONS
# ───────────────────────────────────────────────────────────────────────────
ExcludeNodes $EXCLUDE_COUNTRIES
ExcludeExitNodes $EXCLUDE_COUNTRIES
StrictNodes 1

# ───────────────────────────────────────────────────────────────────────────
# PERFORMANCE
# ───────────────────────────────────────────────────────────────────────────
CircuitBuildTimeout 30
LearnCircuitBuildTimeout 1
NumEntryGuards 3
TOREOF2

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
    
    log_info "Проверка и остановка конфликтующих сервисов..."
    
    # Проверка и остановка systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_info "Останавливаю systemd-resolved..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        systemctl mask systemd-resolved
        
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        log_success "systemd-resolved отключён"
    fi
    
    # Проверка и остановка BIND (named)
    if systemctl is-active --quiet named 2>/dev/null; then
        log_warning "Обнаружен запущенный BIND (named)"
        
        if confirm "Остановить и отключить BIND?" "y"; then
            systemctl stop named
            systemctl disable named
            systemctl mask named
            log_success "BIND (named) отключён"
        else
            log_error "dnsmasq не сможет запуститься пока BIND использует порт 53"
            exit 1
        fi
    fi
    
    # Проверка порта 53
    if ss -tulpn 2>/dev/null | grep -q ":53 "; then
        log_warning "Порт 53 занят:"
        ss -tulpn | grep ":53 " || true
        sleep 2
    fi
    
    # Остановка сервисов перед запуском
    log_info "Останавливаю сервисы..."
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
    
    # Первое обновление списков
    log_info "Выполняю первое обновление списков..."
    if "$RUBLOCK_UPDATE_SCRIPT" >/dev/null 2>&1; then
        log_success "Списки успешно загружены"
    else
        log_warning "Ошибка при загрузке списков (будет повторено по расписанию)"
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
    
    echo ""
    log_info "Проверка портов..."
    echo ""
    echo "  Tor порты:"
    ss -tulpn 2>/dev/null | grep -E ":(9050|9053|9040)" | sed 's/^/    /' || echo "    Порты Tor не найдены!"
    echo ""
    echo "  DNS порт (53):"
    ss -tulpn 2>/dev/null | grep ":53 " | sed 's/^/    /' || echo "    Порт 53 не найден!"
    echo ""
    
    log_info "Проверка DNS (dnsmasq)..."
    local dns_result
    dns_result=$(dig @127.0.0.1 google.com +short +time=5 2>/dev/null | head -1)
    if [[ -n "$dns_result" ]]; then
        log_success "DNS работает"
        echo "    google.com → $dns_result"
    else
        log_error "DNS не работает"
    fi
    echo ""
    
    log_info "Проверка Tor DNS (порт 9053)..."
    local tor_dns_result
    tor_dns_result=$(dig @127.0.0.1 -p 9053 google.com +short +time=10 2>/dev/null | head -1)
    if [[ -n "$tor_dns_result" ]]; then
        log_success "Tor DNS работает"
        echo "    google.com → $tor_dns_result"
    else
        log_warning "Tor DNS не отвечает"
    fi
    echo ""
    
    log_info "Проверка Tor SOCKS (localhost)..."
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
        log_warning "Tor SOCKS localhost не отвечает (Tor может ещё загружаться)"
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
    blocked_test=$(dig @127.0.0.1 rutracker.org +short +time=10 2>/dev/null | head -1)
    if [[ -n "$blocked_test" ]]; then
        log_success "Заблокированные домены резолвятся через Tor"
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
    echo "  DNS сервер:        127.0.0.1 и $MAIN_IP"
    echo "  Tor SOCKS:         127.0.0.1:9050 и $MAIN_IP:9050"
    echo "  Tor DNS:           127.0.0.1:9053 и $MAIN_IP:9053"
    echo "  Tor TransPort:     127.0.0.1:9040 и $MAIN_IP:9040"
    
    if [[ $USE_BRIDGES -eq 1 ]]; then
        echo "  Мосты:             включены"
    else
        echo "  Мосты:             отключены"
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
    echo "  Тест DNS:                dig @127.0.0.1 google.com"
    echo "  Тест Tor:                curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip"
    echo ""
    
    echo "═══════════════════════════════════════════════════════════════════════"
    echo " Настройка клиентов"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  В настройках сети клиентов укажите DNS сервер: $MAIN_IP"
    echo "  Для SOCKS прокси используйте: $MAIN_IP:9050"
    echo ""
    
    log_info "Рекомендуется перезагрузить систему для проверки автозапуска"
    echo ""
}

#===============================================================================
# Главная функция
#===============================================================================
main() {
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
    
    if ! confirm "Начать установку rublock-tor?"; then
        log_info "Установка отменена"
        exit 0
    fi
    
    # Определение сети
    detect_network
    
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
