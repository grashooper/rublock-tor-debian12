#!/usr/bin/env lua

--[[
rublock-tor Multi-Source List Updater
Version: 3.3 (fixed)

Features:
- Multiple sources with fallback
- Custom lists support
- Graceful degradation when sources fail
- Smart caching of previous successful lists
- Detailed statistics

Usage:
  lua rublupdate.lua [source]
  
Sources:
  antifilter    - Antifilter.download (recommended, fast)
  antizapret    - Antizapret API (slow, may timeout)
  zapret-info   - Zapret-Info GitHub archive (medium)
  rublacklist   - RuBlacklist API (often unavailable)
  all           - Merge all available sources (default)
  custom        - Only custom lists
]]

local config = {
    -- Источник по умолчанию
    defaultSource = "all",

    -- Минимальное количество записей для считается успешным
    blMinimumEntries = 1000,

    -- Кэширование: сохранять предыдущий успешный результат
    enableCaching = true,
    cacheDir = "/var/cache/rublock",

    -- Таймауты для источников (секунды)
    timeouts = {
        antifilter = 90,
        antizapret = 300,  -- 5 минут (медленный API)
        zapretinfo = 180,  -- 3 минуты
        rublacklist = 60,
    },

    -- Поведение при недоступности источников
    failureMode = "degrade",  -- "fail" или "degrade"

    groupBySld = 32,
    neverGroupMasks = { "^%a%a%a?.%a%a$" },
    neverGroupDomains = {
        ["livejournal.com"] = true,
        ["facebook.com"] = true,
        ["vk.com"] = true,
        ["instagram.com"] = true,
        ["twitter.com"] = true,
        ["youtube.com"] = true,
        ["google.com"] = true,
        ["wikipedia.org"] = true,
    },

    stripWww = true,
    convertIdn = false,
    torifyNsLookups = false,

    dnsmasqConfigPath = "/etc/rublock/runblock.dnsmasq",
    ipsetConfigPath = "/etc/rublock/runblock.ipset",
    customListPath = "/etc/rublock/custom.list",

    ipsetDns = "rublack-dns",
    ipsetIp = "rublack-ip",
    torDnsAddr = "127.0.0.1#9053",

    -- URLs
    urls = {
        antizapret_domains = "https://api.antizapret.info/group.php?data=domain",
        antizapret_ips = "https://api.antizapret.info/group.php?data=ip",
        zapretinfo_archive = "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump.csv.gz",
        antifilter_fqdn = "https://antifilter.download/list/domains.lst",
        antifilter_ip = "https://antifilter.download/list/ip.lst",
        antifilter_net = "https://antifilter.download/list/subnet.lst",
        antifilter_ip_full = "https://antifilter.download/list/ipresolve.lst",
        rublacklist = "https://reestr.rublacklist.net/api/current",
    }
}

-- Парсинг аргументов
local selected_source = arg[1] or config.defaultSource
selected_source = selected_source:lower()

-- Валидация источника
local valid_sources = {
    ["antifilter"] = true,
    ["antizapret"] = true,
    ["zapret-info"] = true,
    ["zapretinfo"] = true,
    ["rublacklist"] = true,
    ["all"] = true,
    ["custom"] = true,
}

if not valid_sources[selected_source] then
    print(string.format("Invalid source: %s", selected_source))
    print("\nValid sources:")
    print("  antifilter  - Antifilter.download (recommended)")
    print("  antizapret  - Antizapret API (slow)")
    print("  zapret-info - Zapret-Info GitHub")
    print("  rublacklist - RuBlacklist API")
    print("  all         - Merge all sources (default)")
    print("  custom      - Only custom lists")
    os.exit(1)
end

if selected_source == "zapretinfo" then
    selected_source = "zapret-info"
end

-- ============================================================================
-- ANSI Colors
-- ============================================================================

local colors = {
    reset = "\27[0m",
    bold = "\27[1m",
    dim = "\27[2m",
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    magenta = "\27[35m",
    cyan = "\27[36m",
    white = "\27[37m",
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function print_header(text)
    local width = 70
    local padding = math.floor((width - #text - 2) / 2)
    print(string.format("\n%s%s┌%s┐%s", colors.cyan, colors.bold, string.rep("─", width), colors.reset))
    print(string.format("%s%s│%s%s%s%s│%s", colors.cyan, colors.bold, string.rep(" ", padding), colors.white, text, string.rep(" ", width - padding - #text), colors.reset))
    print(string.format("%s%s└%s┘%s\n", colors.cyan, colors.bold, string.rep("─", width), colors.reset))
end

local function print_info(icon, text)
    print(string.format("%s%s[%s]%s %s", colors.blue, colors.bold, icon, colors.reset, text))
end

local function print_success(icon, text)
    print(string.format("%s%s[%s]%s %s", colors.green, colors.bold, icon, colors.reset, text))
end

local function print_warning(icon, text)
    print(string.format("%s%s[%s]%s %s", colors.yellow, colors.bold, icon, colors.reset, text))
end

local function print_error(icon, text)
    print(string.format("%s%s[%s]%s %s", colors.red, colors.bold, icon, colors.reset, text))
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

local function format_size(bytes)
    local units = {"B", "KB", "MB", "GB"}
    local size = bytes
    local unit_index = 1
    while size >= 1024 and unit_index < #units do
        size = size / 1024
        unit_index = unit_index + 1
    end
    return string.format("%.2f %s", size, units[unit_index])
end

local function table_count(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function print_progress(current, total, label)
    local percent = math.floor((current / total) * 100)
    local bar_width = 40
    local filled = math.floor((percent / 100) * bar_width)
    local empty = bar_width - filled
    io.write(string.format("\r  %s%s%s [%s%s%s%s%s] %3d%% (%s/%s)%s",
        colors.cyan, colors.bold, label or "Progress",
        colors.green, string.rep("█", filled),
        colors.dim, string.rep("░", empty),
        colors.reset, percent,
        format_number(current), format_number(total), colors.reset))
    io.flush()
    if current >= total then print() end
end

local timer = {
    start_time = nil,
    start = function(self)
        self.start_time = os.time()
    end,
    elapsed = function(self)
        if not self.start_time then return 0 end
        return os.difftime(os.time(), self.start_time)
    end,
    format_elapsed = function(self)
        local seconds = self:elapsed()
        if seconds < 60 then
            return string.format("%.1fs", seconds)
        elseif seconds < 3600 then
            return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
        else
            return string.format("%dh %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
        end
    end
}

-- ============================================================================
-- Dependencies
-- ============================================================================

local function prequire(package)
    local result, err = pcall(function() require(package) end)
    if not result then return nil, err end
    return require(package)
end

local idn = prequire("idn")
if (not idn) and (config.convertIdn) then
    print_warning("⚠", "IDN conversion disabled (lua-idn not found)")
end

local ltn12 = prequire("ltn12")
if not ltn12 then
    error("luasocket (ltn12) not found. Install: apt install lua-socket")
end

-- ============================================================================
-- Cache Management
-- ============================================================================

local function ensure_cache_dir()
    if config.enableCaching then
        os.execute("mkdir -p " .. config.cacheDir .. " 2>/dev/null")
    end
end

local function save_cache(source_name, data, data_type)
    if not config.enableCaching then return end
    ensure_cache_dir()

    local cache_file = string.format("%s/%s_%s.cache", config.cacheDir, source_name, data_type)
    local file = io.open(cache_file, "w")
    if file then
        file:write(data)
        file:close()
        return true
    end
    return false
end

local function load_cache(source_name, data_type)
    if not config.enableCaching then return nil end

    local cache_file = string.format("%s/%s_%s.cache", config.cacheDir, source_name, data_type)
    local file = io.open(cache_file, "r")
    if file then
        local data = file:read("*a")
        file:close()
        return data
    end
    return nil
end

local function get_cache_age(source_name, data_type)
    if not config.enableCaching then return nil end

    local cache_file = string.format("%s/%s_%s.cache", config.cacheDir, source_name, data_type)
    local handle = io.popen("stat -c %Y " .. cache_file .. " 2>/dev/null")
    if handle then
        local timestamp = handle:read("*a")
        handle:close()
        if timestamp and timestamp ~= "" then
            return os.time() - tonumber(timestamp)
        end
    end
    return nil
end

-- ============================================================================
-- HTTP Functions with Timeout
-- ============================================================================

local function http_fetch(url, sink, timeout)
    timeout = timeout or 90
    local cmd = string.format("timeout %d curl -fsSL --compressed --max-time %d '%s' 2>/dev/null",
        timeout, timeout, url)
    local handle = io.popen(cmd, "r")
    if not handle then return false, "curl failed to start" end

    local chunk_size = 8192
    repeat
        local chunk = handle:read(chunk_size)
        if chunk then sink(chunk) end
    until not chunk

    local ok, exit_type, exit_code = handle:close()
    local success = (ok == true) or (exit_code == 0) or (exit_type == "exit" and exit_code == 0)
    return success, exit_code
end

local function http_fetch_gunzip(url, sink, timeout)
    timeout = timeout or 120
    -- ИСПРАВЛЕНО: Правильное экранирование кавычек
    local cmd = string.format(
        [[timeout %d bash -c "curl -fsSL --max-time %d '%s' 2>/dev/null | gunzip -c 2>/dev/null"]],
        timeout, timeout, url)
    local handle = io.popen(cmd, "r")
    if not handle then return false, "curl/gunzip failed" end

    local chunk_size = 8192
    repeat
        local chunk = handle:read(chunk_size)
        if chunk then sink(chunk) end
    until not chunk

    local ok, exit_type, exit_code = handle:close()
    local success = (ok == true) or (exit_code == 0) or (exit_type == "exit" and exit_code == 0)
    return success, exit_code
end

-- ============================================================================
-- Validation Functions
-- ============================================================================

local function is_valid_ipv4(ip)
    local chunks = {ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
    if #chunks == 4 then
        for _, v in pairs(chunks) do
            local num = tonumber(v)
            if not num or num < 0 or num > 255 then return false end
        end
        return true
    end
    return false
end

local function is_valid_subnet(subnet)
    local ip, mask = subnet:match("^([^/]+)/(%d+)$")
    if ip and mask then
        local mask_num = tonumber(mask)
        return is_valid_ipv4(ip) and mask_num >= 0 and mask_num <= 32
    end
    return false
end

-- ИСПРАВЛЕНО: Полностью переписанная функция normalize_ip
local function normalize_ip(ip)
    -- Убираем пробелы по краям
    ip = ip:match("^%s*(.-)%s*$")
    if not ip or ip == "" then
        return nil
    end
    
    -- Убираем /32 (это эквивалент одиночного IP)
    ip = ip:gsub("/32$", "")
    
    -- Проверяем валидность
    if is_valid_ipv4(ip) or is_valid_subnet(ip) then
        return ip
    end
    
    return nil
end

local function normalize_domain(domain)
    if not domain or domain == "" then return nil end
    domain = domain:match("^%s*(.-)%s*$"):lower()
    if config.stripWww then domain = domain:gsub("^www%.", "") end
    if idn and config.convertIdn then domain = idn.encode(domain) end
    if #domain > 255 or #domain < 3 then return nil end
    if not domain:match("%.") then return nil end
    if is_valid_ipv4(domain) then return nil end
    return domain
end

-- ============================================================================
-- Data Processing
-- ============================================================================

local function hex2unicode(code)
    local n = tonumber(code, 16)
    if (n < 128) then
        return string.char(n)
    elseif (n < 2048) then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096),
                          128 + (((n % 4096) - (n % 64)) / 64),
                          128 + (n % 64))
    end
end

local function addEntry(bltables, entry, source_name)
    if not entry or entry == "" then return end

    local normalized_ip = normalize_ip(entry)
    if normalized_ip then
        if not bltables.ips[normalized_ip] then
            bltables.ips[normalized_ip] = { sources = {} }
        end
        if not bltables.ips[normalized_ip].sources[source_name] then
            table.insert(bltables.ips[normalized_ip].sources, source_name)
            bltables.ips[normalized_ip].sources[source_name] = true
        end
        return
    end

    local normalized_domain = normalize_domain(entry)
    if normalized_domain then
        local subDomain, secondLevelDomain = normalized_domain:match("^([a-z0-9%-%.]-)([a-z0-9%-]+%.[a-z0-9%-]+)$")
        if secondLevelDomain then
            if not bltables.fqdn[normalized_domain] then
                bltables.fqdn[normalized_domain] = { sld = secondLevelDomain, sources = {} }
            end
            if not bltables.fqdn[normalized_domain].sources[source_name] then
                table.insert(bltables.fqdn[normalized_domain].sources, source_name)
                bltables.fqdn[normalized_domain].sources[source_name] = true
            end
            bltables.sdcount[secondLevelDomain] = (bltables.sdcount[secondLevelDomain] or 0) + 1
        end
    end
end

-- ============================================================================
-- Extractors
-- ============================================================================

local function antizapretExtractDomains()
    local currentRecord, buffer, bufferPos, streamEnded = "", "", 1, false
    return function(chunk)
        if chunk == nil then
            streamEnded = true
        else
            buffer = buffer .. chunk
        end
        local newlinePosition = buffer:find("\n", bufferPos)
        if newlinePosition then
            currentRecord = currentRecord .. buffer:sub(bufferPos, newlinePosition - 1)
            bufferPos = newlinePosition + 1
            local retVal = currentRecord
            currentRecord = ""
            return retVal
        else
            currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
            buffer = ""
            bufferPos = 1
            if streamEnded then
                local retVal = currentRecord ~= "" and currentRecord or nil
                currentRecord = ""
                return retVal
            end
        end
    end
end

local function rublacklistExtractDomains()
    local currentRecord, buffer, bufferPos, streamEnded = "", "", 1, false
    return function(chunk)
        if chunk == nil then
            streamEnded = true
        else
            buffer = buffer .. chunk
        end
        while true do
            local escapeStart, escapeEnd, escapedChar = buffer:find("\\(.)", bufferPos)
            if escapedChar then
                currentRecord = currentRecord .. buffer:sub(bufferPos, escapeStart - 1)
                bufferPos = escapeEnd + 1
                if escapedChar == "n" then
                    local retVal = currentRecord
                    currentRecord = ""
                    local extracted = retVal:match("^[^;]*;([^;]+);")
                    return extracted and extracted:gsub("\\u(%x%x%x%x)", hex2unicode) or ""
                elseif escapedChar == "u" then
                    currentRecord = currentRecord .. "\\u"
                else
                    currentRecord = currentRecord .. escapedChar
                end
            else
                currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
                buffer, bufferPos = "", 1
                if streamEnded then
                    return currentRecord ~= "" and currentRecord or nil
                end
                break
            end
        end
    end
end

-- ============================================================================
-- Custom List Loader
-- ============================================================================

local function load_custom_list(bltables, filepath)
    local file = io.open(filepath, "r")
    if not file then return 0, 0 end

    local domains_count, ips_count = 0, 0
    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local is_ip = normalize_ip(line)
            if is_ip then
                ips_count = ips_count + 1
            else
                domains_count = domains_count + 1
            end
            addEntry(bltables, line, "custom")
        end
    end
    file:close()
    return domains_count, ips_count
end

-- ============================================================================
-- Source Fetchers with Graceful Degradation
-- ============================================================================

local function fetch_antifilter(bltables)
    print_header("Fetching from Antifilter")
    local source_timer = {start_time = os.time()}
    local stats = {domains = 0, ips = 0, subnets = 0, resolved = 0}
    local timeout = config.timeouts.antifilter

    print_info("🌐", "Downloading domains...")
    local buf = {}
    if http_fetch(config.urls.antifilter_fqdn, ltn12.sink.table(buf), timeout) then
        local data = table.concat(buf)
        save_cache("antifilter", data, "domains")
        for line in data:gmatch("[^\r\n]+") do
            addEntry(bltables, line, "antifilter")
            stats.domains = stats.domains + 1
        end
        print_success("✓", string.format("Domains: %s", format_number(stats.domains)))
    else
        print_warning("⚠", "Failed to download domains, trying cache...")
        local cached = load_cache("antifilter", "domains")
        if cached then
            for line in cached:gmatch("[^\r\n]+") do
                addEntry(bltables, line, "antifilter-cache")
                stats.domains = stats.domains + 1
            end
            local age = get_cache_age("antifilter", "domains")
            print_info("💾", string.format("Loaded from cache (%s, age: %dd)",
                format_number(stats.domains), math.floor((age or 0) / 86400)))
        else
            print_error("✗", "No cache available")
            return false
        end
    end

    print_info("🌐", "Downloading IPs...")
    buf = {}
    if http_fetch(config.urls.antifilter_ip, ltn12.sink.table(buf), timeout) then
        local data = table.concat(buf)
        save_cache("antifilter", data, "ips")
        for line in data:gmatch("[^\r\n]+") do
            addEntry(bltables, line, "antifilter")
            stats.ips = stats.ips + 1
        end
        print_success("✓", string.format("IPs: %s", format_number(stats.ips)))
    else
        print_warning("⚠", "IPs download failed (non-critical)")
    end

    print_info("🌐", "Downloading subnets...")
    buf = {}
    if http_fetch(config.urls.antifilter_net, ltn12.sink.table(buf), timeout) then
        local data = table.concat(buf)
        save_cache("antifilter", data, "subnets")
        for line in data:gmatch("[^\r\n]+") do
            addEntry(bltables, line, "antifilter")
            stats.subnets = stats.subnets + 1
        end
        print_success("✓", string.format("Subnets: %s (CIDR notation)", format_number(stats.subnets)))
    else
        print_warning("⚠", "Subnets download failed (non-critical)")
    end

    print_info("🌐", "Downloading resolved IPs...")
    buf = {}
    if http_fetch(config.urls.antifilter_ip_full, ltn12.sink.table(buf), timeout) then
        local data = table.concat(buf)
        save_cache("antifilter", data, "resolved")
        for line in data:gmatch("[^\r\n]+") do
            addEntry(bltables, line, "antifilter")
            stats.resolved = stats.resolved + 1
        end
        print_success("✓", string.format("Resolved: %s", format_number(stats.resolved)))
    else
        print_warning("⚠", "Resolved IPs download failed (non-critical)")
    end

    local elapsed = os.difftime(os.time(), source_timer.start_time)
    print_success("✓", string.format("Completed in %.1fs", elapsed))
    return stats.domains > 0
end

local function fetch_zapretinfo(bltables)
    print_header("Fetching from Zapret-Info")
    local source_timer = {start_time = os.time()}
    local timeout = config.timeouts.zapretinfo

    print_info("🌐", "Downloading archive (dump.csv.gz)...")
    local buf = {}
    if not http_fetch_gunzip(config.urls.zapretinfo_archive, ltn12.sink.table(buf), timeout) then
        print_warning("⚠", "Failed to download, trying cache...")
        local cached = load_cache("zapretinfo", "archive")
        if cached then
            buf = {cached}
            local age = get_cache_age("zapretinfo", "archive")
            print_info("💾", string.format("Using cached data (age: %dd)", math.floor((age or 0) / 86400)))
        else
            print_error("✗", "Download failed and no cache available")
            return false
        end
    else
        local data = table.concat(buf)
        save_cache("zapretinfo", data, "archive")
    end

    local data = table.concat(buf)
    print_success("✓", string.format("Downloaded %s", format_size(#data)))

    print_info("🔍", "Processing CSV...")
    local totalLines, stats = 0, {domains = 0, ips = 0}
    for _ in data:gmatch("[^\r\n]+") do totalLines = totalLines + 1 end

    local lineCount = 0
    for line in data:gmatch("[^\r\n]+") do
        lineCount = lineCount + 1
        if lineCount % 50000 == 0 then
            print_progress(lineCount, totalLines, "Processing")
        end

        local ip_str, fqdn_str = line:match("^([^;]*);([^;]*);")
        if fqdn_str and fqdn_str ~= "" then
            addEntry(bltables, fqdn_str, "zapret-info")
            stats.domains = stats.domains + 1
        end
        if ip_str and ip_str ~= "" then
            addEntry(bltables, ip_str, "zapret-info")
            stats.ips = stats.ips + 1
        end
    end

    print_progress(totalLines, totalLines, "Processing")
    print_success("✓", string.format("Domains: %s, IPs: %s",
        format_number(stats.domains), format_number(stats.ips)))

    local elapsed = os.difftime(os.time(), source_timer.start_time)
    print_success("✓", string.format("Completed in %.1fs", elapsed))
    return true
end

local function fetch_antizapret(bltables)
    print_header("Fetching from Antizapret API")
    print_warning("⏳", "This source is slow (5-10 min). Press Ctrl+C to skip.")
    local source_timer = {start_time = os.time()}
    local timeout = config.timeouts.antizapret

    print_info("🌐", "Downloading domains...")
    local domain_count = 0
    local last_update = os.time()

    local domainSink = function(chunk)
        if chunk and chunk ~= "" then
            addEntry(bltables, chunk, "antizapret")
            domain_count = domain_count + 1

            local now = os.time()
            if os.difftime(now, last_update) >= 2 then
                io.write(string.format("\r  %sProcessed: %s domains (%.0fs)...%s",
                    colors.cyan, format_number(domain_count),
                    os.difftime(now, source_timer.start_time), colors.reset))
                io.flush()
                last_update = now
            end
        end
        return 1
    end

    local extractSink = ltn12.sink.chain(antizapretExtractDomains(), domainSink)
    if http_fetch(config.urls.antizapret_domains, extractSink, timeout) then
        print(string.format("\r  Processed: %s domains                              ",
            format_number(domain_count)))
        print_success("✓", string.format("Domains: %s", format_number(domain_count)))
    else
        print()
        print_error("✗", "Failed to download domains (timeout or network error)")
        return false
    end

    print_info("🌐", "Downloading IPs...")
    local ipBuf = {}
    if http_fetch(config.urls.antizapret_ips, ltn12.sink.table(ipBuf), timeout) then
        local ip_count = 0
        for line in table.concat(ipBuf):gmatch("[^\r\n]+") do
            addEntry(bltables, line, "antizapret")
            ip_count = ip_count + 1
        end
        print_success("✓", string.format("IPs: %s", format_number(ip_count)))
    else
        print_error("✗", "Failed to download IPs")
        return false
    end

    local elapsed = os.difftime(os.time(), source_timer.start_time)
    print_success("✓", string.format("Completed in %.1fs", elapsed))
    return true
end

local function fetch_rublacklist(bltables)
    print_header("Fetching from RuBlacklist")
    local source_timer = {start_time = os.time()}
    local timeout = config.timeouts.rublacklist

    print_info("🌐", "Downloading from API...")
    local domain_count = 0
    local domainSink = function(chunk)
        if chunk and chunk ~= "" then
            addEntry(bltables, chunk, "rublacklist")
            domain_count = domain_count + 1
        end
        return 1
    end

    local extractSink = ltn12.sink.chain(rublacklistExtractDomains(), domainSink)
    if http_fetch(config.urls.rublacklist, extractSink, timeout) then
        print_success("✓", string.format("Domains: %s", format_number(domain_count)))
        local elapsed = os.difftime(os.time(), source_timer.start_time)
        print_success("✓", string.format("Completed in %.1fs", elapsed))
        return true
    else
        print_error("✗", "Failed (API unavailable)")
        return false
    end
end

-- ============================================================================
-- Config Generators
-- ============================================================================

local function compactDomainList(fqdnList, subdomainsCount)
    print_info("🔄", "Compacting domain list...")
    local domainTable, grouped = {}, 0

    if config.groupBySld and (config.groupBySld > 0) then
        for sld in pairs(subdomainsCount) do
            if config.neverGroupDomains[sld] then
                subdomainsCount[sld] = 0
            else
                for _, pattern in ipairs(config.neverGroupMasks) do
                    if sld:find(pattern) then
                        subdomainsCount[sld] = 0
                        break
                    end
                end
            end
        end
    end

    for fqdn, data in pairs(fqdnList) do
        local sld = data.sld
        if (not fqdnList[sld]) or (fqdn == sld) then
            local keyValue
            if config.groupBySld and (config.groupBySld > 0) and (subdomainsCount[sld] > config.groupBySld) then
                keyValue = sld
                grouped = grouped + 1
            else
                keyValue = fqdn
            end
            if not domainTable[keyValue] then
                domainTable[keyValue] = data.sources
            end
        end
    end

    if grouped > 0 then
        print_success("✓", string.format("Grouped %s SLDs", format_number(grouped)))
    end
    return domainTable
end

local function generateDnsmasqConfig(configPath, domainList)
    print_info("💾", "Generating dnsmasq config...")
    local configFile = assert(io.open(configPath, "w"), "cannot open dnsmasq config")
    local count, total = 0, table_count(domainList)

    for fqdn in pairs(domainList) do
        if config.torifyNsLookups then
            configFile:write(string.format("server=/%s/%s\n", fqdn, config.torDnsAddr))
        end
        configFile:write(string.format("ipset=/%s/%s\n", fqdn, config.ipsetDns))
        count = count + 1
        if count % 50000 == 0 then
            print_progress(count, total, "Writing domains")
        end
    end

    if total > 0 then
        print_progress(total, total, "Writing domains")
    end
    configFile:close()

    local file = io.open(configPath, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        print_success("✓", string.format("Saved %s domains (%s)", format_number(count), format_size(size)))
    end
    return count
end

local function generateIpsetConfig(configPath, ipList)
    print_info("💾", "Generating ipset config...")
    local configFile = assert(io.open(configPath, "w"), "cannot open ipset config")

    -- Создаём основной и временный набор
    configFile:write(string.format("create %s hash:ip family inet hashsize 131072 maxelem 2097152 -exist\n",
        config.ipsetIp))
    configFile:write(string.format("create %s-tmp hash:ip family inet hashsize 131072 maxelem 2097152 -exist\n",
        config.ipsetIp))
    configFile:write(string.format("flush %s-tmp\n", config.ipsetIp))

    local count, total = 0, table_count(ipList)
    local subnets_count = 0

    for ipaddr in pairs(ipList) do
        configFile:write(string.format("add %s-tmp %s\n", config.ipsetIp, ipaddr))
        count = count + 1
        if ipaddr:match("/") then
            subnets_count = subnets_count + 1
        end
        if count % 50000 == 0 then
            print_progress(count, total, "Writing IPs")
        end
    end

    if total > 0 then
        print_progress(total, total, "Writing IPs")
    end

    -- Атомарная замена: swap и удаление временного
    configFile:write(string.format("swap %s %s-tmp\n", config.ipsetIp, config.ipsetIp))
    configFile:write(string.format("destroy %s-tmp\n", config.ipsetIp))  -- ИСПРАВЛЕНО: добавлена очистка
    configFile:close()

    local file = io.open(configPath, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        print_success("✓", string.format("Saved %s IPs (%s single + %s subnets) - %s",
            format_number(count),
            format_number(count - subnets_count),
            format_number(subnets_count),
            format_size(size)))
    end
    return count
end

-- ============================================================================
-- Statistics
-- ============================================================================

local function print_statistics(bltables)
    print_header("Statistics")
    print(string.format("  %sUnique domains:%s %s%s%s",
        colors.dim, colors.reset, colors.white, format_number(table_count(bltables.fqdn)), colors.reset))
    print(string.format("  %sUnique IPs/subnets:%s %s%s%s",
        colors.dim, colors.reset, colors.white, format_number(table_count(bltables.ips)), colors.reset))

    local source_stats = {}
    for _, data in pairs(bltables.fqdn) do
        for _, src in ipairs(data.sources) do
            source_stats[src] = (source_stats[src] or 0) + 1
        end
    end

    if table_count(source_stats) > 0 then
        print(string.format("\n  %sDomains by source:%s", colors.dim, colors.reset))
        for src, count in pairs(source_stats) do
            print(string.format("    • %-20s %s", src .. ":", format_number(count)))
        end
    end

    local ip_stats = {}
    for _, data in pairs(bltables.ips) do
        for _, src in ipairs(data.sources) do
            ip_stats[src] = (ip_stats[src] or 0) + 1
        end
    end

    if table_count(ip_stats) > 0 then
        print(string.format("\n  %sIPs by source:%s", colors.dim, colors.reset))
        for src, count in pairs(ip_stats) do
            print(string.format("    • %-20s %s", src .. ":", format_number(count)))
        end
    end
end

-- ============================================================================
-- Main Execution
-- ============================================================================

print_header("rublock-tor Multi-Source Updater v3.3")
print_info("📦", string.format("Source: %s%s%s", colors.yellow, selected_source, colors.reset))
print_info("🔧", string.format("Mode: %s", config.failureMode == "degrade" and "Graceful degradation" or "Strict"))
print_info("⏰", string.format("Started at %s", os.date("%H:%M:%S")))

timer:start()
ensure_cache_dir()

local bltables = { fqdn = {}, sdcount = {}, ips = {} }
local success = false
local failed_sources = {}

-- Выбор источника
if selected_source == "all" then
    local sources_to_try = {
        {name = "antifilter", func = fetch_antifilter},
        {name = "zapret-info", func = fetch_zapretinfo},
    }

    local success_count = 0
    for _, src in ipairs(sources_to_try) do
        local src_success = src.func(bltables)
        if src_success then
            success_count = success_count + 1
        else
            table.insert(failed_sources, src.name)
        end
    end

    success = success_count > 0

    if success_count == 0 then
        print_error("✗", "All sources failed!")
    elseif #failed_sources > 0 then
        print_warning("⚠", string.format("%d source(s) failed but continuing with available data",
            #failed_sources))
    end

elseif selected_source == "antifilter" then
    success = fetch_antifilter(bltables)
elseif selected_source == "antizapret" then
    success = fetch_antizapret(bltables)
elseif selected_source == "zapret-info" then
    success = fetch_zapretinfo(bltables)
elseif selected_source == "rublacklist" then
    success = fetch_rublacklist(bltables)
elseif selected_source == "custom" then
    success = true -- custom list only
end

-- Load custom list (always, if exists)
local custom_file = config.customListPath
local custom_handle = io.open(custom_file, "r")
if custom_handle then
    custom_handle:close()
    print_header("Loading Custom List")
    local custom_domains, custom_ips = load_custom_list(bltables, custom_file)
    if custom_domains > 0 or custom_ips > 0 then
        print_success("✓", string.format("Loaded %s domains + %s IPs from custom list",
            format_number(custom_domains), format_number(custom_ips)))
    end
end

if not success and selected_source ~= "custom" then
    print_header("Update Failed")
    print_error("✗", "Failed to fetch blocklists from any source")
    if #failed_sources > 0 then
        for _, src in ipairs(failed_sources) do
            print_error(" ", "• " .. src)
        end
    end
    os.exit(1)
end

print_statistics(bltables)
print_header("Generating Configurations")

local domainTable = compactDomainList(bltables.fqdn, bltables.sdcount)
local domain_count = generateDnsmasqConfig(config.dnsmasqConfigPath, domainTable)
local ip_count = generateIpsetConfig(config.ipsetConfigPath, bltables.ips)

if domain_count < config.blMinimumEntries and selected_source ~= "custom" then
    print_error("✗", string.format("Too few entries (%d < %d)", domain_count, config.blMinimumEntries))
    print_warning("ℹ", "This might indicate a failure. Check logs above.")
    os.exit(1)
end

print()
print_header("Blocklists Updated Successfully")
print_success("✓", string.format("Source: %s%s%s", colors.yellow, selected_source, colors.reset))
print_success("✓", string.format("Domains: %s%s%s", colors.white, format_number(domain_count), colors.reset))
print_success("✓", string.format("IPs: %s%s%s", colors.white, format_number(ip_count), colors.reset))
print_success("✓", string.format("Time: %s%s%s", colors.white, timer:format_elapsed(), colors.reset))
if #failed_sources > 0 then
    print_warning("⚠", string.format("Failed sources: %s", table.concat(failed_sources, ", ")))
end
print_info("⏰", string.format("Finished at %s\n", os.date("%H:%M:%S")))

os.exit(0)
