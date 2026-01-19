#!/usr/bin/env lua

--[[
================================================================================
  rublock.lua - Обновление списков заблокированных доменов для Tor
  Version: 2.0
  
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
        "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst",
        "https://community.antifilter.download/list/domains.lst",
        "https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst"
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
-- Логирование
--------------------------------------------------------------------------------
local function log(msg)
    io.stdout:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
    io.stdout:flush()
end

local function log_separator(char)
    char = char or "="
    log(string.rep(char, 70))
end

local function log_progress(current, total, msg)
    if current % CONFIG.progress_interval == 0 then
        log(string.format("    Прогресс: %d/%d %s", current, total, msg or ""))
    end
end

--------------------------------------------------------------------------------
-- Загрузка файла через curl/wget
--------------------------------------------------------------------------------
local function download_with_curl(url, filepath)
    -- Экранирование кавычек в путях
    local safe_filepath = filepath:gsub("'", "'\\''")
    local safe_url = url:gsub("'", "'\\''")
    
    -- Пробуем curl
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
        
        -- Проверяем что файл создан и не пустой
        local test_file = io.open(filepath, "r")
        if success and test_file then
            test_file:close()
            return true
        end
    end
    
    -- Если curl не сработал, пробуем wget
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

--------------------------------------------------------------------------------
-- Загрузка в память (для небольших файлов)
--------------------------------------------------------------------------------
local function download_to_memory(url)
    local response = {}
    
    local result, status_code = https.request{
        url = url,
        sink = ltn12.sink.table(response),
        protocol = "any",
        options = {"all"},
        verify = "none",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; rublock/2.0; +https://github.com/rublock)"
        }
    }
    
    if status_code == 200 then
        return table.concat(response)
    else
        return nil, "HTTP " .. tostring(status_code)
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
-- Форматирование размера
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

--------------------------------------------------------------------------------
-- Распаковка gzip
--------------------------------------------------------------------------------
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
    -- Проверка длины
    if not domain or #domain < 4 or #domain > 253 then
        return false
    end
    
    -- Должна быть хотя бы одна точка
    if not domain:find(".", 1, true) then
        return false
    end
    
    -- Не должен начинаться или заканчиваться точкой/дефисом
    if domain:match("^[%.%-]") or domain:match("[%.%-]$") then
        return false
    end
    
    -- Только буквы, цифры, точка, дефис
    if not domain:match("^[%w%.%-]+$") then
        return false
    end
    
    -- Не IP адрес
    if domain:match("^%d+%.%d+%.%d+%.%d+$") then
        return false
    end
    
    -- Не должно быть двойных точек
    if domain:find("..", 1, true) then
        return false
    end
    
    -- Минимум две части (example.com)
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
    -- Прямое совпадение
    if CONFIG.exclude_domains[domain] then
        return true
    end
    
    -- Проверка родительских доменов (sub.example.com -> example.com)
    local parts = {}
    for part in domain:gmatch("[^.]+") do
        table.insert(parts, part)
    end
    
    -- Проверяем все уровни доменов
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
    
    -- Приводим к нижнему регистру
    domain = domain:lower()
    
    -- Убираем пробелы по краям
    domain = domain:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Убираем www.
    domain = domain:gsub("^www%.", "")
    
    -- Убираем wildcard *
    domain = domain:gsub("^%*%.", "")
    
    -- Убираем протокол
    domain = domain:gsub("^https?://", "")
    domain = domain:gsub("^ftp://", "")
    
    -- Убираем путь, порт, параметры
    domain = domain:gsub("[:/].*$", "")
    domain = domain:gsub("%?.*$", "")
    
    -- Убираем точку в конце
    domain = domain:gsub("%.$", "")
    
    return domain
end

--------------------------------------------------------------------------------
-- Парсинг CSV (формат zapret-info)
-- Формат: IP;domain;url;organization;date;decision_number
--------------------------------------------------------------------------------
local function parse_csv(content, domains, seen)
    local count = 0
    local line_num = 0
    local total_lines = select(2, content:gsub("\n", "\n")) + 1
    
    log("    Всего строк в CSV: " .. total_lines)
    
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        
        -- Показываем прогресс
        if line_num % 10000 == 0 then
            log(string.format("    Обработано строк: %d/%d", line_num, total_lines))
        end
        
        -- Пропускаем заголовок и метаданные
        if line_num > 1 and not line:match("^Updated:") and not line:match("^%s*$") then
            -- Определяем разделитель
            local separator = ";"
            if not line:find(";") and line:find("|") then
                separator = "|"
            end
            
            -- Разбиваем строку на поля
            local fields = {}
            for field in (line .. separator):gmatch("([^" .. separator .. "]*)" .. separator) do
                table.insert(fields, field)
            end
            
            -- Поле 2: домены (может быть несколько через запятую)
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
            
            -- Поле 3: URL (извлекаем домен из URL)
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

--------------------------------------------------------------------------------
-- Парсинг простого списка доменов
--------------------------------------------------------------------------------
local function parse_list(content, domains, seen)
    local count = 0
    
    for line in content:gmatch("[^\r\n]+") do
        -- Пропускаем комментарии и пустые строки
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

--------------------------------------------------------------------------------
-- Главная функция
--------------------------------------------------------------------------------
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
    
    -- Очистка временных файлов
    os.remove(CONFIG.temp_gz)
    os.remove(CONFIG.temp_csv)
    os.remove(CONFIG.temp_file)
    
    -- ========================================================================
    -- [1] Основной источник: dump.csv.gz (zapret-info)
    -- ========================================================================
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
                
                -- Очищаем
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
    
    -- ========================================================================
    -- [2+] Дополнительные источники
    -- ========================================================================
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
            
            -- Очищаем память
            content = nil
            collectgarbage("collect")
        else
            log("    ✗ Ошибка: " .. (err or "unknown"))
        end
    end
    
    -- ========================================================================
    -- Статистика
    -- ========================================================================
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
    
    -- ========================================================================
    -- Сортировка и запись
    -- ========================================================================
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
    
    -- Заголовок
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
    
    -- Записываем домены
    log("  Запись доменов...")
    for i, domain in ipairs(all_domains) do
        file:write("server=/" .. domain .. "/" .. CONFIG.tor_dns .. "\n")
        
        if i % 50000 == 0 then
            log(string.format("  Записано: %d/%d", i, #all_domains))
        end
    end
    
    file:close()
    log("✓ Запись завершена")
    
    -- Атомарная замена файла
    log("")
    log("Применение изменений...")
    os.execute("mv '" .. CONFIG.temp_file:gsub("'", "'\\''") .. "' '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
    os.execute("chmod 644 '" .. CONFIG.output_file:gsub("'", "'\\''") .. "'")
    log("✓ Файл сохранён: " .. CONFIG.output_file)
    
    -- ========================================================================
    -- Перезагрузка dnsmasq
    -- ========================================================================
    log("")
    log("Перезагрузка dnsmasq...")
    
    local reload_result = os.execute("systemctl reload dnsmasq 2>/dev/null")
    if reload_result ~= 0 and reload_result ~= true then
        log("  reload не сработал, пробую restart...")
        os.execute("systemctl restart dnsmasq 2>/dev/null")
    end
    
    log("✓ dnsmasq обновлён")
    
    -- ========================================================================
    -- Финал
    -- ========================================================================
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

--------------------------------------------------------------------------------
-- Запуск с обработкой ошибок
--------------------------------------------------------------------------------
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
