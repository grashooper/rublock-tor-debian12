#!/usr/bin/env lua

--[[
================================================================================
  rublock.lua - Обновление списков заблокированных доменов для Tor
  Version: 2.3 (исправлен прогресс-бар)
  
  Загружает списки из zapret-info и других источников,
  парсит домены и создаёт конфигурацию для dnsmasq
================================================================================
--]]

local https = require("ssl.https")
local ltn12 = require("ltn12")

--------------------------------------------------------------------------------
-- Конфигурация
--------------------------------------------------------------------------------
local CONFIG = {
    -- Основной источник (РКН dump в gzip)
    source_url_gz = "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv.gz",
    
    -- Дополнительные источники
    extra_sources = {
        {
            url = "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst",
            name = "itdoginfo/allow-domains"
        },
        {
            url = "https://community.antifilter.download/list/domains.lst",
            name = "antifilter.download"
        },
        {
            url = "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst",
            name = "Re-filter-lists"
        }
    },
    
    -- Пути к файлам
    output_file = "/etc/rublock/rublock.dnsmasq",
    temp_file = "/tmp/rublock_domains.tmp",
    temp_gz = "/tmp/rublock_dump.csv.gz",
    temp_csv = "/tmp/rublock_dump.csv",
    
    -- Tor DNS сервер
    tor_dns = "127.0.0.1#9053",
    
    -- Исключения (домены, которые НЕ нужно блокировать)
    exclude_domains = {
        -- Google сервисы
        ["google.com"] = true,
        ["google.ru"] = true,
        ["googleapis.com"] = true,
        ["googleusercontent.com"] = true,
        ["gstatic.com"] = true,
        ["googlevideo.com"] = true,
        
        -- YouTube
        ["youtube.com"] = true,
        ["youtu.be"] = true,
        ["ytimg.com"] = true,
        ["ggpht.com"] = true,
        
        -- Facebook/Meta
        ["facebook.com"] = true,
        ["fbcdn.net"] = true,
        ["instagram.com"] = true,
        ["whatsapp.com"] = true,
        ["whatsapp.net"] = true,
        
        -- Облачные сервисы
        ["cloudflare.com"] = true,
        ["cloudflare-dns.com"] = true,
        ["amazonaws.com"] = true,
        ["azure.com"] = true,
        
        -- Популярные сервисы
        ["apple.com"] = true,
        ["icloud.com"] = true,
        ["microsoft.com"] = true,
        ["live.com"] = true,
        ["github.com"] = true,
        ["githubusercontent.com"] = true,
        ["twitter.com"] = true,
        ["linkedin.com"] = true
    },
    
    -- Настройки
    max_download_time = 600,  -- максимальное время загрузки в секундах
    progress_interval = 50000 -- показывать прогресс каждые N доменов
}

--------------------------------------------------------------------------------
-- ANSI цвета для терминала
--------------------------------------------------------------------------------
local COLORS = {
    reset = "\27[0m",
    bold = "\27[1m",
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    cyan = "\27[36m",
    
    -- Комбинации
    success = "\27[32m\27[1m",  -- зелёный жирный
    error = "\27[31m\27[1m",    -- красный жирный
    warning = "\27[33m\27[1m",  -- жёлтый жирный
    info = "\27[34m\27[1m",     -- синий жирный
    progress = "\27[36m",       -- голубой
    
    -- Управление курсором
    clear_line = "\27[2K",      -- очистить всю строку
    move_start = "\r",          -- в начало строки
}

--------------------------------------------------------------------------------
-- Логирование
--------------------------------------------------------------------------------
local function log(msg)
    io.stdout:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
    io.stdout:flush()
end

local function log_color(color, prefix, msg)
    io.stdout:write(color .. prefix .. COLORS.reset .. " " .. msg .. "\n")
    io.stdout:flush()
end

local function log_success(msg)
    log_color(COLORS.success, "[✓]", msg)
end

local function log_error(msg)
    log_color(COLORS.error, "[✗]", msg)
end

local function log_warning(msg)
    log_color(COLORS.warning, "[⚠]", msg)
end

local function log_info(msg)
    log_color(COLORS.info, "[ℹ]", msg)
end

local function log_separator(char)
    char = char or "="
    log(string.rep(char, 70))
end

--------------------------------------------------------------------------------
-- Прогресс-бар (стабильный, без мерцания)
--------------------------------------------------------------------------------
local function log_progress_bar(current, total, prefix, suffix)
    local percent = math.floor((current / total) * 100)
    local bar_width = 30
    local filled = math.floor(bar_width * current / total)
    local empty = bar_width - filled
    
    local bar = string.rep("█", filled) .. string.rep("░", empty)
    
    -- Формируем строку
    local line = string.format("    %s [%s%s%s] %3d%% %s",
        prefix or "",
        COLORS.green,
        bar,
        COLORS.reset,
        percent,
        suffix or ""
    )
    
    -- Очищаем строку и выводим
    io.stdout:write(COLORS.move_start .. COLORS.clear_line .. line)
    io.stdout:flush()
end

-- Отдельная функция для завершения прогресс-бара
local function log_progress_done()
    io.stdout:write("\n")
    io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Спиннер для процессов без известного размера
--------------------------------------------------------------------------------
local spinner_chars = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local spinner_idx = 1

local function log_spinner(msg)
    -- Очищаем строку полностью перед выводом
    io.stdout:write(COLORS.move_start .. COLORS.clear_line)
    io.stdout:write(string.format("    %s%s%s %s",
        COLORS.cyan,
        spinner_chars[spinner_idx],
        COLORS.reset,
        msg
    ))
    io.stdout:flush()
    spinner_idx = (spinner_idx % #spinner_chars) + 1
end

local function log_spinner_done(msg)
    -- Очищаем строку и выводим финальное сообщение
    io.stdout:write(COLORS.move_start .. COLORS.clear_line)
    io.stdout:write(string.format("    %s✓%s %s\n",
        COLORS.green,
        COLORS.reset,
        msg
    ))
    io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Форматирование чисел и размеров
--------------------------------------------------------------------------------
local function format_size(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / 1024 / 1024)
    end
end

local function format_number(num)
    local formatted = tostring(num)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

local function format_time(seconds)
    if seconds < 60 then
        return string.format("%d сек", seconds)
    else
        return string.format("%d мин %d сек", math.floor(seconds / 60), seconds % 60)
    end
end

--------------------------------------------------------------------------------
-- Получение размера файла
--------------------------------------------------------------------------------
local function get_file_size(filepath)
    local file = io.open(filepath, "rb")
    if not file then return 0 end
    
    local current = file:seek()
    local size = file:seek("end")
    file:seek("set", current)
    file:close()
    
    return size or 0
end

--------------------------------------------------------------------------------
-- Загрузка файла через curl (тихий режим + свой прогресс)
--------------------------------------------------------------------------------
local function download_with_progress(url, filepath, name)
    local safe_filepath = filepath:gsub("'", "'\\''")
    local safe_url = url:gsub("'", "'\\''")
    
    log_info("Загрузка: " .. (name or url))
    
    -- Запускаем curl в фоне и отслеживаем размер файла
    local cmd = string.format(
        "curl -L -s -f --max-time %d -o '%s' '%s' 2>/dev/null &",
        CONFIG.max_download_time,
        safe_filepath,
        safe_url
    )
    
    -- Удаляем старый файл если есть
    os.remove(filepath)
    
    -- Запускаем загрузку в фоне
    os.execute(cmd)
    
    -- Небольшая пауза чтобы curl стартовал
    os.execute("sleep 0.5")
    
    -- Отслеживаем прогресс по размеру файла
    local start_time = os.time()
    local last_size = 0
    local stall_count = 0
    local max_stall = 30  -- максимум 30 секунд без изменений
    
    -- Ожидаемый размер (примерный для dump.csv.gz)
    local expected_size = 20 * 1024 * 1024  -- ~20MB
    
    while true do
        os.execute("sleep 0.5")
        
        local current_size = get_file_size(filepath)
        local elapsed = os.time() - start_time
        
        if current_size > 0 then
            -- Показываем прогресс
            local speed = ""
            if elapsed > 0 then
                speed = format_size(current_size / elapsed) .. "/с"
            end
            
            -- Используем спиннер с информацией о размере
            log_spinner(string.format("Загружено: %s (%s)", format_size(current_size), speed))
            
            -- Проверяем, завершилась ли загрузка
            if current_size == last_size then
                stall_count = stall_count + 1
                if stall_count >= 4 then  -- 2 секунды без изменений = завершено
                    break
                end
            else
                stall_count = 0
            end
            
            last_size = current_size
        else
            -- Файл ещё не создан
            log_spinner("Подключение...")
        end
        
        -- Таймаут
        if elapsed > CONFIG.max_download_time then
            log_spinner_done("Таймаут загрузки")
            return false, "Таймаут"
        end
        
        -- Проверяем не зависла ли загрузка
        if stall_count >= max_stall * 2 then
            break
        end
    end
    
    -- Ждём завершения curl
    os.execute("sleep 1")
    
    -- Проверяем результат
    local final_size = get_file_size(filepath)
    local total_time = os.time() - start_time
    
    if final_size > 0 then
        local speed = ""
        if total_time > 0 then
            speed = " (" .. format_size(final_size / total_time) .. "/с)"
        end
        log_spinner_done(string.format("Загружено: %s за %s%s", 
            format_size(final_size), 
            format_time(total_time),
            speed))
        return true
    end
    
    -- Пробуем wget как fallback
    log_warning("curl не сработал, пробую wget...")
    
    cmd = string.format(
        "wget -q -T %d -O '%s' '%s' 2>/dev/null",
        CONFIG.max_download_time,
        safe_filepath,
        safe_url
    )
    
    log_spinner("Загрузка через wget...")
    
    start_time = os.time()
    os.execute(cmd)
    total_time = os.time() - start_time
    
    final_size = get_file_size(filepath)
    
    if final_size > 0 then
        log_spinner_done(string.format("Загружено: %s за %s", 
            format_size(final_size), 
            format_time(total_time)))
        return true
    end
    
    io.stdout:write(COLORS.move_start .. COLORS.clear_line)
    io.stdout:flush()
    return false, "Не удалось загрузить"
end

--------------------------------------------------------------------------------
-- Загрузка в память с прогрессом (для небольших файлов)
--------------------------------------------------------------------------------
local function download_to_memory_with_progress(url, name)
    local response = {}
    local bytes_received = 0
    local start_time = os.time()
    local last_update = 0
    
    -- Показываем начало загрузки
    log_info("Загрузка: " .. (name or url))
    
    -- Создаём sink с отслеживанием прогресса
    local progress_sink = function(chunk, err)
        if chunk then
            bytes_received = bytes_received + #chunk
            
            -- Обновляем спиннер каждые ~50KB
            if bytes_received - last_update > 51200 then
                local elapsed = os.time() - start_time
                local speed = ""
                if elapsed > 0 then
                    speed = " (" .. format_size(bytes_received / elapsed) .. "/с)"
                end
                log_spinner(string.format("Получено: %s%s", format_size(bytes_received), speed))
                last_update = bytes_received
            end
            
            table.insert(response, chunk)
        end
        return 1
    end
    
    local result, status_code = https.request{
        url = url,
        sink = progress_sink,
        protocol = "any",
        options = {"all"},
        verify = "none",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; rublock/2.3)"
        }
    }
    
    local total_time = os.time() - start_time
    
    if status_code == 200 then
        local speed = ""
        if total_time > 0 then
            speed = " (" .. format_size(bytes_received / total_time) .. "/с)"
        end
        log_spinner_done(string.format("Загружено: %s%s", format_size(bytes_received), speed))
        return table.concat(response)
    else
        io.stdout:write(COLORS.move_start .. COLORS.clear_line .. "\n")
        io.stdout:flush()
        return nil, "HTTP " .. tostring(status_code)
    end
end

--------------------------------------------------------------------------------
-- Распаковка gzip с прогрессом
--------------------------------------------------------------------------------
local function gunzip_file(gz_path, output_path)
    local safe_gz = gz_path:gsub("'", "'\\''")
    local safe_out = output_path:gsub("'", "'\\''")
    
    log_info("Распаковка архива...")
    
    local cmd = string.format("gunzip -c '%s' > '%s' 2>&1", safe_gz, safe_out)
    
    local handle = io.popen(cmd)
    if not handle then
        return false, "Не удалось запустить gunzip"
    end
    
    local result = handle:read("*a") or ""
    local success = handle:close()
    
    if success then
        local size = get_file_size(output_path)
        log_success(string.format("Распаковано: %s", format_size(size)))
        return true
    else
        return false, result
    end
end

--------------------------------------------------------------------------------
-- Чтение файла
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- Валидация домена
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- Проверка исключений
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- Очистка и нормализация домена
--------------------------------------------------------------------------------
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

--------------------------------------------------------------------------------
-- Парсинг CSV с прогресс-баром
--------------------------------------------------------------------------------
local function parse_csv(content, domains, seen)
    local count = 0
    local line_num = 0
    
    -- Подсчёт строк для прогресса
    local total_lines = 1
    for _ in content:gmatch("\n") do
        total_lines = total_lines + 1
    end
    
    log_info(string.format("Парсинг CSV: %s строк", format_number(total_lines)))
    
    local last_progress_update = 0
    local start_time = os.time()
    
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        
        -- Обновляем прогресс-бар каждые 1% или каждые 10000 строк
        local progress_step = math.max(math.floor(total_lines / 100), 10000)
        if line_num - last_progress_update >= progress_step or line_num == total_lines then
            local elapsed = os.time() - start_time
            local eta = ""
            if line_num > 0 and elapsed > 0 and line_num < total_lines then
                local remaining = math.floor((total_lines - line_num) * elapsed / line_num)
                if remaining > 0 then
                    eta = string.format("ETA: %s", format_time(remaining))
                end
            end
            log_progress_bar(line_num, total_lines, "Обработка", eta)
            last_progress_update = line_num
        end
        
        -- Пропускаем заголовок и метаданные
        if line_num > 1 and not line:match("^Updated:") and not line:match("^%s*$") then
            local separator = ";"
            if not line:find(";") and line:find("|") then
                separator = "|"
            end
            
            local fields = {}
            for field in (line .. separator):gmatch("([^" .. separator .. "]*)" .. separator) do
                table.insert(fields, field)
            end
            
            -- Поле 2: домены
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
            
            -- Поле 3: URL
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
    
    -- Завершаем прогресс-бар (переход на новую строку)
    log_progress_done()
    
    return count
end

--------------------------------------------------------------------------------
-- Парсинг простого списка доменов с прогрессом
--------------------------------------------------------------------------------
local function parse_list(content, domains, seen)
    local count = 0
    local line_num = 0
    
    -- Подсчёт строк
    local total_lines = 1
    for _ in content:gmatch("\n") do
        total_lines = total_lines + 1
    end
    
    local last_update = 0
    local update_interval = math.max(math.floor(total_lines / 10), 1000)
    
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        
        -- Обновляем прогресс каждые 10%
        if line_num - last_update >= update_interval then
            log_spinner(string.format("Обработано: %s / %s строк...",
                format_number(line_num),
                format_number(total_lines)
            ))
            last_update = line_num
        end
        
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local domain = clean_domain(line)
            
            if domain and is_valid_domain(domain) and not seen[domain] and not is_excluded(domain) then
                seen[domain] = true
                table.insert(domains, domain)
                count = count + 1
            end
        end
    end
    
    -- Очищаем строку спиннера (если был)
    if total_lines > update_interval then
        io.stdout:write(COLORS.move_start .. COLORS.clear_line)
        io.stdout:flush()
    end
    
    return count
end

--------------------------------------------------------------------------------
-- Запись файла с прогрессом
--------------------------------------------------------------------------------
local function write_output_file(domains)
    log_info("Запись в файл: " .. CONFIG.output_file)
    
    local file, file_err = io.open(CONFIG.temp_file, "w")
    if not file then
        return false, "Не удалось создать файл: " .. (file_err or "unknown")
    end
    
    -- Заголовок
    file:write("# " .. string.rep("=", 70) .. "\n")
    file:write("# rublock domains list for dnsmasq\n")
    file:write("# \n")
    file:write("# Generated:  " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    file:write("# Domains:    " .. format_number(#domains) .. "\n")
    file:write("# Tor DNS:    " .. CONFIG.tor_dns .. "\n")
    file:write("# \n")
    file:write("# " .. string.rep("=", 70) .. "\n")
    file:write("\n")
    
    local total = #domains
    local last_progress = 0
    
    for i, domain in ipairs(domains) do
        file:write("server=/" .. domain .. "/" .. CONFIG.tor_dns .. "\n")
        
        -- Прогресс-бар каждые 1%
        local progress_step = math.max(math.floor(total / 100), 1000)
        if i - last_progress >= progress_step or i == total then
            log_progress_bar(i, total, "Запись")
            last_progress = i
        end
    end
    
    file:close()
    
    -- Завершаем прогресс-бар
    log_progress_done()
    
    -- Атомарная замена
    os.execute("mv '" .. CONFIG.temp_file:gsub("'", "'\\''") .. "' '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
    os.execute("chmod 644 '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
    
    log_success("Файл сохранён")
    return true
end

--------------------------------------------------------------------------------
-- Главная функция
--------------------------------------------------------------------------------
local function main()
    local total_start = os.time()
    
    -- Заголовок
    io.stdout:write("\n")
    io.stdout:write(COLORS.cyan .. COLORS.bold)
    io.stdout:write("╔══════════════════════════════════════════════════════════════════════╗\n")
    io.stdout:write("║                                                                      ║\n")
    io.stdout:write("║              rublock - Обновление списков блокировок                 ║\n")
    io.stdout:write("║                          Version 2.3                                 ║\n")
    io.stdout:write("║                                                                      ║\n")
    io.stdout:write("╚══════════════════════════════════════════════════════════════════════╝\n")
    io.stdout:write(COLORS.reset .. "\n")
    
    local all_domains = {}
    local seen = {}
    local stats = {
        sources_total = 0,
        sources_ok = 0
    }
    
    -- Очистка временных файлов
    os.remove(CONFIG.temp_gz)
    os.remove(CONFIG.temp_csv)
    os.remove(CONFIG.temp_file)
    
    -- ========================================================================
    -- [1] Основной источник: dump.csv.gz
    -- ========================================================================
    stats.sources_total = stats.sources_total + 1
    
    io.stdout:write(COLORS.bold .. "\n[1/4] " .. COLORS.reset)
    io.stdout:write("Основной источник: " .. COLORS.cyan .. "zapret-info (РКН dump)" .. COLORS.reset .. "\n")
    
    local ok, err = download_with_progress(
        CONFIG.source_url_gz, 
        CONFIG.temp_gz, 
        "dump.csv.gz"
    )
    
    if ok then
        local size = get_file_size(CONFIG.temp_gz)
        
        if size > 0 then
            local gunzip_ok, gunzip_err = gunzip_file(CONFIG.temp_gz, CONFIG.temp_csv)
            
            if gunzip_ok then
                local content, read_err = read_file(CONFIG.temp_csv)
                
                if content then
                    local count = parse_csv(content, all_domains, seen)
                    stats.sources_ok = stats.sources_ok + 1
                    log_success(string.format("Извлечено доменов: %s", format_number(count)))
                else
                    log_error("Ошибка чтения CSV: " .. (read_err or "unknown"))
                end
                
                content = nil
                collectgarbage("collect")
                os.remove(CONFIG.temp_csv)
            else
                log_error("Ошибка распаковки: " .. (gunzip_err or "unknown"))
            end
        else
            log_error("Загруженный файл пустой")
        end
        
        os.remove(CONFIG.temp_gz)
    else
        log_error("Ошибка загрузки: " .. (err or "unknown"))
    end
    
    -- ========================================================================
    -- [2+] Дополнительные источники
    -- ========================================================================
    for i, source in ipairs(CONFIG.extra_sources) do
        stats.sources_total = stats.sources_total + 1
        
        io.stdout:write(COLORS.bold .. string.format("\n[%d/%d] ", i + 1, #CONFIG.extra_sources + 1) .. COLORS.reset)
        io.stdout:write("Дополнительный: " .. COLORS.cyan .. source.name .. COLORS.reset .. "\n")
        
        local content, err = download_to_memory_with_progress(source.url, source.name)
        
        if content then
            local count = parse_list(content, all_domains, seen)
            stats.sources_ok = stats.sources_ok + 1
            log_spinner_done(string.format("Извлечено доменов: %s", format_number(count)))
            
            content = nil
            collectgarbage("collect")
        else
            log_error("Ошибка: " .. (err or "unknown"))
        end
    end
    
    -- ========================================================================
    -- Статистика загрузки
    -- ========================================================================
    io.stdout:write("\n")
    io.stdout:write(COLORS.cyan .. "────────────────────────────────────────────────────────────────────────\n" .. COLORS.reset)
    log_info(string.format("Источников: %d/%d успешно", stats.sources_ok, stats.sources_total))
    log_info(string.format("Уникальных доменов: %s", format_number(#all_domains)))
    io.stdout:write(COLORS.cyan .. "────────────────────────────────────────────────────────────────────────\n" .. COLORS.reset)
    
    if #all_domains == 0 then
        io.stdout:write("\n")
        log_error("КРИТИЧЕСКАЯ ОШИБКА: Список пуст!")
        log_error("Проверьте подключение к интернету")
        os.exit(1)
    end
    
    -- ========================================================================
    -- Сортировка
    -- ========================================================================
    io.stdout:write("\n")
    log_info("Сортировка доменов по алфавиту...")
    
    local sort_start = os.time()
    table.sort(all_domains)
    local sort_time = os.time() - sort_start
    
    log_success(string.format("Сортировка завершена за %s", format_time(sort_time)))
    
    -- ========================================================================
    -- Запись файла
    -- ========================================================================
    io.stdout:write("\n")
    local write_ok, write_err = write_output_file(all_domains)
    
    if not write_ok then
        log_error("Ошибка записи: " .. (write_err or "unknown"))
        os.exit(1)
    end
    
    -- ========================================================================
    -- Перезагрузка dnsmasq
    -- ========================================================================
    io.stdout:write("\n")
    log_info("Перезагрузка dnsmasq...")
    
    local reload_result = os.execute("systemctl reload dnsmasq 2>/dev/null")
    if reload_result ~= 0 and reload_result ~= true then
        log_warning("reload не сработал, пробую restart...")
        os.execute("systemctl restart dnsmasq 2>/dev/null")
    end
    log_success("dnsmasq обновлён")
    
    -- ========================================================================
    -- Финал
    -- ========================================================================
    local total_time = os.time() - total_start
    
    io.stdout:write("\n")
    io.stdout:write(COLORS.green .. COLORS.bold)
    io.stdout:write("╔══════════════════════════════════════════════════════════════════════╗\n")
    io.stdout:write("║                                                                      ║\n")
    io.stdout:write("║           ✓ ✓ ✓   ОБНОВЛЕНИЕ ЗАВЕРШЕНО УСПЕШНО   ✓ ✓ ✓              ║\n")
    io.stdout:write("║                                                                      ║\n")
    io.stdout:write("╚══════════════════════════════════════════════════════════════════════╝\n")
    io.stdout:write(COLORS.reset .. "\n")
    
    io.stdout:write(string.format("  %sДоменов:%s       %s\n", 
        COLORS.bold, COLORS.reset, format_number(#all_domains)))
    io.stdout:write(string.format("  %sВремя:%s         %s\n", 
        COLORS.bold, COLORS.reset, format_time(total_time)))
    io.stdout:write(string.format("  %sФайл:%s          %s\n", 
        COLORS.bold, COLORS.reset, CONFIG.output_file))
    io.stdout:write("\n")
end

--------------------------------------------------------------------------------
-- Запуск с обработкой ошибок
--------------------------------------------------------------------------------
local status, err = pcall(main)

if not status then
    io.stdout:write("\n")
    io.stdout:write(COLORS.error .. "╔══════════════════════════════════════════════════════════════════════╗\n")
    io.stdout:write("║                      ФАТАЛЬНАЯ ОШИБКА                                ║\n")
    io.stdout:write("╚══════════════════════════════════════════════════════════════════════╝\n" .. COLORS.reset)
    io.stdout:write("\n" .. tostring(err) .. "\n\n")
    os.exit(1)
end
