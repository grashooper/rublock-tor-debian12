#!/usr/bin/env lua

local config = {
    blSource = "antifilter", -- antifilter, zapret-info, antizapret, rublacklist
    groupBySld = 32, -- количество поддоменов после которого в список вносится весь домен второго уровня целиком
    neverGroupMasks = { "^%a%a%a?.%a%a$" }, -- не распространять на org.ru, net.ua и аналогичные
    neverGroupDomains = { ["livejournal.com"] = true, ["facebook.com"] = true , ["vk.com"] = true },
    stripWww = true,
    convertIdn = false, -- в Debian 12 по умолчанию нет lua-idn. Включите при наличии.
    torifyNsLookups = false, -- отправлять DNS запросы заблокированных доменов через TOR
    blMinimumEntries = 1000, -- костыль если список получился короче, значит что-то пошло не так и конфиги не обновляем
    dnsmasqConfigPath = "/etc/rublock/runblock.dnsmasq",
    ipsetConfigPath = "/etc/rublock/runblock.ipset",
    ipsetDns = "rublack-dns",
    ipsetIp = "rublack-ip",
    torDnsAddr = "127.0.0.1#9053",
    antizapretDomainUrl = "https://api.antizapret.info/group.php?data=domain",
    antizapretIpUrl = "https://api.antizapret.info/group.php?data=ip",
    zapretInfoUrls = {
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-00.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-01.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-02.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-03.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-04.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-05.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-06.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-07.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-08.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-09.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-10.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-11.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-12.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-13.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-14.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-15.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-16.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-17.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-18.csv",
        "https://raw.githubusercontent.com/zapret-info/z-i/refs/heads/master/dump-19.csv",
    },
    antifilter = {
        fqdn = "https://antifilter.download/list/domains.lst",
        ip = "https://antifilter.download/list/ip.lst",
        net = "https://antifilter.download/list/subnet.lst",
        ip_full = "https://antifilter.download/list/ipresolve.lst",
    },
    rublacklistUrl = "https://reestr.rublacklist.net/api/current" -- может быть недоступен; оставлен для совместимости
}


local function prequire(package)
    local result, err = pcall(function() require(package) end)
    if not result then
        return nil, err
    end
    return require(package) -- return the package value
end

local idn = prequire("idn")
if (not idn) and (config.convertIdn) then
    error("you need either put idn.lua (github.com/haste/lua-idn) in script dir  or set 'convertIdn' to false")
end

local http = prequire("socket.http")
local ltn12 = prequire("ltn12")
if not ltn12 then
    error("you need either install luasocket package (prefered) or put ltn12.lua in script dir")
end

local function http_fetch(url, sink)
    -- стараемся использовать curl (работает с https без lua-sec), иначе socket.http
    local cmd = string.format("curl -fsSL --max-time 90 '%s'", url)
    if http then
        local ok, code = http.request { url = url, sink = sink }
        if ok == 1 and (code == 200 or code == 301 or code == 302) then
            return true, code
        end
    end
    local fh = io.popen(cmd)
    if not fh then
        return false, "curl open failed"
    end
    local ok, pumpCode = ltn12.pump.all(ltn12.source.file(fh), sink)
    fh:close()
    return ok == 1, pumpCode
end

local function hex2unicode(code)
    local n = tonumber(code, 16)
    if (n < 128) then
        return string.char(n)
    elseif (n < 2048) then
        return string.char(192 + ((n - (n % 64)) / 64), 128 + (n % 64))
    else
        return string.char(224 + ((n - (n % 4096)) / 4096), 128 + (((n % 4096) - (n % 64)) / 64), 128 + (n % 64))
    end
end

local function rublacklistExtractDomains()
    local currentRecord = ""
    local buffer = ""
    local bufferPos = 1
    local streamEnded = false
    return function(chunk)
        local retVal = ""
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
                    retVal = currentRecord
                    break
                elseif escapedChar == "u" then
                    currentRecord = currentRecord .. "\\u"
                else
                    currentRecord = currentRecord .. escapedChar
                end
            else
                currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
                buffer = ""
                bufferPos = 1
                if streamEnded then
                    if currentRecord == "" then
                        retVal = nil
                    else
                        retVal = currentRecord
                    end
                end
                break
            end
        end
        if retVal and (retVal ~= "") then
            currentRecord = ""
            retVal = retVal:match("^[^;]*;([^;]+);[^;]*;[^;]*;[^;]*;[^;]*.*$")
            if retVal then
                retVal = retVal:gsub("\\u(%x%x%x%x)", hex2unicode)
            else
                retVal = ""
            end
        end
        return (retVal)
    end
end

local function antizapretExtractDomains()
    local currentRecord = ""
    local buffer = ""
    local bufferPos = 1
    local streamEnded = false
    return function(chunk)
        local haveOutput = 0
        local retVal = ""
        if chunk == nil then
            streamEnded = true
        else
            buffer = buffer .. chunk
        end
        local newlinePosition = buffer:find("\n", bufferPos)
        if newlinePosition then
            currentRecord = currentRecord .. buffer:sub(bufferPos, newlinePosition - 1)
            bufferPos = newlinePosition + 1
            retVal = currentRecord
        else
            currentRecord = currentRecord .. buffer:sub(bufferPos, #buffer)
            buffer = ""
            bufferPos = 1
            if streamEnded then
                if currentRecord == "" then
                    retVal = nil
                else
                    retVal = currentRecord
                end
            end
        end
        if retVal and (retVal ~= "") then
            currentRecord = ""
        end
        return (retVal)
    end
end

local function normalizeFqdn()
    return function(chunk)
        if chunk and (chunk ~= "") then
            if config["stripWww"] then chunk = chunk:gsub("^www%.", "") end
            if idn and config["convertIdn"] then chunk = idn.encode(chunk) end
            if #chunk > 255 then chunk = "" end
            chunk = chunk:lower()
        end
        return (chunk)
    end
end

local function cunstructTables(bltables)
    bltables = bltables or { fqdn = {}, sdcount = {}, ips = {} }
    local f = function(blEntry, err)
        if blEntry and (blEntry ~= "") then
            if blEntry:match("^%d+%.%d+%.%d+%.%d+$") then
                -- ip адреса - в отдельную таблицу для iptables
                if not bltables.ips[blEntry] then
                    bltables.ips[blEntry] = true
                end
            else
                -- как можем проверяем, FQDN ли это. заодно выделяем домен 2 уровня (если в bl станут попадать TLD - дело плохо :))
                local subDomain, secondLevelDomain = blEntry:match("^([a-z0-9%-%.]-)([a-z0-9%-]+%.[a-z0-9%-]+)$")
                if secondLevelDomain then
                    bltables.fqdn[blEntry] = secondLevelDomain
                    if 1 > 0 then
                        bltables.sdcount[secondLevelDomain] = (bltables.sdcount[secondLevelDomain] or 0) + 1
                    end
                end
            end
        end
        return 1
    end
    return f, bltables
end

local function compactDomainList(fqdnList, subdomainsCount)
    local domainTable = {}
    local numEntries = 0
    if config.groupBySld and (config.groupBySld > 0) then
        for sld in pairs(subdomainsCount) do
            if config.neverGroupDomains[sld] then
                subdomainsCount[sld] = 0
                break
            end
            for _, pattern in ipairs(config.neverGroupMasks) do
                if sld:find(pattern) then
                    subdomainsCount[sld] = 0
                    break
                end
            end
        end
    end
    for fqdn, sld in pairs(fqdnList) do
        if (not fqdnList[sld]) or (fqdn == sld) then
            local keyValue;
            if config.groupBySld and (config.groupBySld > 0) and (subdomainsCount[sld] > config.groupBySld) then
                keyValue = sld
            else
                keyValue = fqdn
            end
            if not domainTable[keyValue] then
                domainTable[keyValue] = true
                numEntries = numEntries + 1
            end
        end
    end
    return domainTable, numEntries
end

local function generateDnsmasqConfig(configPath, domainList)
    local configFile = assert(io.open(configPath, "w"), "could not open dnsmasq config")
    for fqdn in pairs(domainList) do
        if config.torifyNsLookups then
            configFile:write(string.format("server=/%s/%s\n", fqdn, config.torDnsAddr))
        end
        configFile:write(string.format("ipset=/%s/%s\n", fqdn, config.ipsetDns))
    end
    configFile:close()
end

local function generateIpsetConfig(configPath, ipList)
    local configFile = assert(io.open(configPath, "w"), "could not open ipset config")
    configFile:write(string.format("create %s hash:ip family inet hashsize 65536 maxelem 1048576 -exist\n", config.ipsetIp))
    configFile:write(string.format("create %s-tmp hash:ip family inet hashsize 65536 maxelem 1048576 -exist\n", config.ipsetIp))
    configFile:write(string.format("flush %s-tmp\n", config.ipsetIp))
    for ipaddr in pairs(ipList) do
        configFile:write(string.format("add %s-tmp %s\n", config.ipsetIp, ipaddr))
    end
    configFile:write(string.format("swap %s %s-tmp\n", config.ipsetIp, config.ipsetIp))
    configFile:close()
end

local function fetch_antizapret(bltables)
    local domainOutput = ltn12.sink.chain(
        ltn12.filter.chain(antizapretExtractDomains(), normalizeFqdn()),
        cunstructTables(bltables)
    )
    local okDomains = http_fetch(config.antizapretDomainUrl, domainOutput)

    local ipBuf = {}
    local ipSink = ltn12.sink.table(ipBuf)
    local okIps = http_fetch(config.antizapretIpUrl, ipSink)
    if okIps then
        local ipData = table.concat(ipBuf)
        for ip in ipData:gmatch("[^\r\n]+") do
            ip = ip:match("^%s*(.-)%s*$")
            if ip and ip ~= "" then
                bltables.ips[ip] = true
            end
        end
    end
    return okDomains and okIps
end

local function fetch_antifilter(bltables)
    local normalize = normalizeFqdn()
    local sinkFn, _ = cunstructTables(bltables)
    -- FQDN
    do
        local buf = {}
        if http_fetch(config.antifilter.fqdn, ltn12.sink.table(buf)) then
            for line in table.concat(buf):gmatch("[^\r\n]+") do
                local fqdn = normalize(line:match("^%s*(.-)%s*$"))
                if fqdn and fqdn ~= "" then
                    sinkFn(fqdn)
                end
            end
        else
            return false
        end
    end
    -- IP (single)
    do
        local ipBuf = {}
        if http_fetch(config.antifilter.ip, ltn12.sink.table(ipBuf)) then
            local ipData = table.concat(ipBuf)
            for ip in ipData:gmatch("[^\r\n]+") do
                ip = ip:match("^%s*(.-)%s*$")
                if ip and ip ~= "" then bltables.ips[ip] = true end
            end
        else
            return false
        end
    end
    -- Subnets
    do
        local netBuf = {}
        if http_fetch(config.antifilter.net, ltn12.sink.table(netBuf)) then
            local netData = table.concat(netBuf)
            for net in netData:gmatch("[^\r\n]+") do
                net = net:match("^%s*(.-)%s*$")
                if net and net ~= "" then bltables.ips[net] = true end
            end
        else
            return false
        end
    end
    -- ipresolve (strips /32)
    do
        local ipBuf = {}
        if http_fetch(config.antifilter.ip_full, ltn12.sink.table(ipBuf)) then
            local ipData = table.concat(ipBuf):gsub("/32", "")
            for ip in ipData:gmatch("[^\r\n]+") do
                ip = ip:match("^%s*(.-)%s*$")
                if ip and ip ~= "" then bltables.ips[ip] = true end
            end
        else
            return false
        end
    end
    return true
end

local function fetch_zapretinfo(bltables)
    local success = false
    local normalize = normalizeFqdn()
    local sinkFn, _ = cunstructTables(bltables)
    for _, url in ipairs(config.zapretInfoUrls) do
        local buf = {}
        if http_fetch(url, ltn12.sink.table(buf)) then
            success = true
            for line in table.concat(buf):gmatch("[^\r\n]+") do
                local ip_str, fqdn_str = line:match("([^;]*);([^;]*);")
                if fqdn_str and fqdn_str ~= "" then
                    local fqdn = normalize(fqdn_str:match("^%s*(.-)%s*$"))
                    if fqdn and fqdn ~= "" then sinkFn(fqdn) end
                end
                if ip_str and ip_str ~= "" then
                    sinkFn(ip_str:match("^%s*(.-)%s*$"))
                end
            end
        end
    end
    return success
end

local function fetch_rublacklist(bltables)
    local output = ltn12.sink.chain(ltn12.filter.chain(rublacklistExtractDomains(), normalizeFqdn()), cunstructTables(bltables))
    local ok = http_fetch(config.rublacklistUrl, output)
    return ok
end

local bltables = { fqdn = {}, sdcount = {}, ips = {} }
local ok
if config.blSource == "antizapret" then
    ok = fetch_antizapret(bltables)
elseif config.blSource == "rublacklist" then
    ok = fetch_rublacklist(bltables)
elseif config.blSource == "antifilter" then
    ok = fetch_antifilter(bltables)
elseif config.blSource == "zapret-info" then
    ok = fetch_zapretinfo(bltables)
else
    error("blacklist source should be one of: 'rublacklist', 'antizapret', 'antifilter', 'zapret-info'")
end

if ok then
    local domainTable, recordsNum = compactDomainList(bltables.fqdn, bltables.sdcount)
    if recordsNum > config.blMinimumEntries then
        generateDnsmasqConfig(config.dnsmasqConfigPath, domainTable)
        generateIpsetConfig(config.ipsetConfigPath, bltables.ips)
        print(string.format("blacklists updated. %d entries.", recordsNum))
        os.exit(0)
    end
end

print("blacklists update failed or too few entries")
os.exit(1)

