-- LuCI controller for ZLT IPsec (zi-manager)
module("luci.controller.zlt_ipsec", package.seeall)

local ZI_API_VERSION = 7
local BYPASS_FILE = "/etc/zlt-ipsec/bypass_domains"
local BYPASS_SUFFIX_FILE = "/etc/zlt-ipsec/bypass_suffixes"
local BYPASS_IPS_FILE = "/tmp/zi_bypass_ips"
local IMPORT_TMP = "/tmp/zi_import_cfg"

function index()
    entry({"admin", "services", "zlt_ipsec"}, template("zlt_ipsec_panel"), _("ZLT IPsec"), 60).dependent = false

    entry({"admin", "services", "zlt_ipsec", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "start"}, call("action_start")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import"}, call("action_import")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import_begin"}, call("action_import_begin")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import_chunk"}, call("action_import_chunk")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import_commit"}, call("action_import_commit")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import_manual"}, call("action_import_manual")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "log"}, call("action_log")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "ss_check"}, call("action_ss_check")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "sa"}, call("action_sa")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "confirm"}, call("action_confirm")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "emergency"}, call("action_emergency")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "bypass_list"}, call("action_bypass_list")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "bypass_add"}, call("action_bypass_add")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "bypass_del"}, call("action_bypass_del")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "bypass_suffix_set"}, call("action_bypass_suffix_set")).leaf = true
end



local function run(cmd)
    local f = io.popen(cmd .. " 2>/dev/null")
    local out = f and f:read("*a") or ""
    if f then f:close() end
    out = tostring(out or "")
    out = out:gsub("%s+$", "")
    return out
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local data = f:read("*a") or ""
    f:close()
    data = data:gsub("%s+$", "")
    return data
end

local function write_file(path, data)
    local fh = io.open(path, "w")
    if not fh then return false end
    fh:write(data or "")
    fh:close()
    return true
end

local function shq(s)
    s = s or ""
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function mat(name)
    return read_file("/etc/zlt-ipsec/material/" .. name)
end

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end


local function mgr()
    local f = io.open("/data/zi-bin/zi-manager", "r")
    if f then
        f:close()
        return "/data/zi-bin/zi-manager"
    end
    f = io.open("/usr/bin/zi-manager", "r")
    if f then
        f:close()
        return "/usr/bin/zi-manager"
    end
    return "/data/zi-bin/zi-manager"
end

local function mgr_exists()
    local m = mgr()
    local f = io.open(m, "r")
    if f then f:close(); return true end
    return false
end

local function normalize_bypass_entry(d)
    d = tostring(d or "")
    d = d:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r", "")
    d = d:lower()
    d = d:gsub("^https?://", ""):gsub("/.*$", ""):gsub("^%*%.", "")
    if d == "" then return "" end
    if d:sub(1, 1) == "." then return d end
    if not d:find(".", 1, true) then return "." .. d end
    return d
end

local function normalize_domain(d)
    return normalize_bypass_entry(d)
end

local function list_bypass_domains()
    local seen = {}
    local out = {}
    local function add_file(path)
        local raw = read_file(path)
        for line in string.gmatch(raw .. "\n", "([^\n]*)\n") do
            line = normalize_bypass_entry(line)
            if line ~= "" and not line:match("^#") and not seen[line] then
                seen[line] = true
                out[#out + 1] = line
            end
        end
    end
    add_file(BYPASS_FILE)
    add_file(BYPASS_SUFFIX_FILE)
    return out, table.concat(out, "\n")
end

function action_status()
    local m = mgr()
    local status = "Stopped"
    local ver = ""
    if mgr_exists() then
        status = run(m .. " status")
        ver = run(m .. " version")
    else
        status = "manager missing — reinstall"
    end

    local conf = read_file("/tmp/zi_swanctl/conf.d/zivpn.conf")
    if conf == "" then
        conf = read_file("/etc/zlt-ipsec/profile.json")
    end
    -- trim huge cert from profile preview
    if conf:find('"cert"') then
        conf = conf:gsub('"cert"%s*:%s*"[^"]*"', '"cert":"(pkcs12 omitted)"')
    end

    local bypass_list = select(1, list_bypass_domains())
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        ok = true,
        running = status,
        host = mat("host"),
        user = mat("user"),
        ike = mat("ike"),
        esp = mat("esp"),
        dns1 = mat("dns1"),
        rsa_pss = mat("rsa_pss"),
        has_p12 = exists("/etc/zlt-ipsec/material/client.p12") and "1" or "0",
        has_cert = exists("/etc/zlt-ipsec/material/client.pem") and "1" or "0",

        ping_fails = read_file("/etc/zlt-ipsec/ping_fails"),
        active = read_file("/etc/zlt-ipsec/active"),
        stack_root = read_file("/etc/zlt-ipsec/stack.root"),
        stack_ver = read_file("/etc/zlt-ipsec/stack.ver"),
        conf_preview = conf,
        bypass_domains = table.concat(bypass_list, "\n"),
        bypass_ips = read_file(BYPASS_IPS_FILE),
        api_version = ZI_API_VERSION,
        manager_version = ver,
        manager_path = m
    })
end

local function write_bypass_domains(list)
    run("mkdir -p /etc/zlt-ipsec")
    local fh = io.open(BYPASS_FILE, "w")
    if not fh then return false end
    for _, d in ipairs(list) do
        fh:write(d .. "\n")
    end
    fh:close()
    return true
end

local function apply_bypass_hot()
    local m = mgr()
    if mgr_exists() then
        run(m .. " bypass-apply >/dev/null 2>&1 &")
    end
end

function action_bypass_list()
    local list, raw = list_bypass_domains()
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        ok = true,
        api_version = ZI_API_VERSION,
        domains = table.concat(list, "\n"),
        bypass_domains = table.concat(list, "\n"),
        ips = read_file(BYPASS_IPS_FILE),
        bypass_ips = read_file(BYPASS_IPS_FILE),
        count = #list,
        raw = raw
    })
end

function action_bypass_suffix_set()
    -- compat: treat as bypass_add/del for any suffix/domain
    local suf = normalize_bypass_entry(luci.http.formvalue("suffix") or luci.http.formvalue("s") or luci.http.formvalue("domain") or "")
    local en = luci.http.formvalue("enable") or luci.http.formvalue("e") or "1"
    luci.http.prepare_content("application/json")
    if suf == "" then
        luci.http.write_json({ ok = false, error = "empty domain" })
        return
    end
    local list = select(1, list_bypass_domains())
    local want = (en == "1" or en == "true" or en == "on")
    local nextlist = {}
    for _, s in ipairs(list) do
        if s ~= suf then nextlist[#nextlist + 1] = s end
    end
    if want then nextlist[#nextlist + 1] = suf end
    if not write_bypass_domains(nextlist) then
        luci.http.write_json({ ok = false, error = "cannot write " .. BYPASS_FILE })
        return
    end
    -- clear legacy suffix file so list stays unified
    write_file(BYPASS_SUFFIX_FILE, "")
    apply_bypass_hot()
    luci.http.write_json({
        ok = true,
        domain = suf,
        enable = want,
        domains = table.concat(nextlist, "\n"),
        bypass_domains = table.concat(nextlist, "\n")
    })
end

function action_bypass_add()
    local domain = normalize_bypass_entry(luci.http.formvalue("domain") or luci.http.formvalue("d") or "")
    luci.http.prepare_content("application/json")
    if domain == "" then
        luci.http.write_json({ ok = false, error = "empty domain" })
        return
    end
    local list = select(1, list_bypass_domains())
    local found = false
    for _, d in ipairs(list) do
        if d == domain then found = true; break end
    end
    if not found then
        list[#list + 1] = domain
        if not write_bypass_domains(list) then
            luci.http.write_json({ ok = false, error = "cannot write " .. BYPASS_FILE })
            return
        end
    end
    write_file(BYPASS_SUFFIX_FILE, "")
    apply_bypass_hot()
    luci.http.write_json({
        ok = true,
        domain = domain,
        already = found,
        domains = table.concat(list, "\n"),
        bypass_domains = table.concat(list, "\n"),
        count = #list
    })
end

function action_bypass_del()
    local domain = normalize_bypass_entry(luci.http.formvalue("domain") or luci.http.formvalue("d") or "")
    luci.http.prepare_content("application/json")
    if domain == "" then
        luci.http.write_json({ ok = false, error = "empty domain" })
        return
    end
    local list = select(1, list_bypass_domains())
    local kept = {}
    for _, d in ipairs(list) do
        if d ~= domain then kept[#kept + 1] = d end
    end
    if not write_bypass_domains(kept) then
        luci.http.write_json({ ok = false, error = "cannot write " .. BYPASS_FILE })
        return
    end
    write_file(BYPASS_SUFFIX_FILE, "")
    apply_bypass_hot()
    luci.http.write_json({
        ok = true,
        domain = domain,
        domains = table.concat(kept, "\n"),
        bypass_domains = table.concat(kept, "\n"),
        count = #kept
    })
end


function action_sa()
    local sa = run("PATH=/tmp/zi-bin:$PATH swanctl --list-sas 2>/dev/null")
    if sa == "" then
        sa = run("PATH=/tmp/zi-bin:$PATH ipsec statusall 2>/dev/null")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true, sa = sa })
end

function action_start()
    local m = mgr()
    run(m .. " start >/tmp/zi_start.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        ok = true,
        failsafe_sec = 90,
        tip = "Click Confirm within 90s or tunnel auto-stops (LAN protection)"
    })
end

function action_stop()
    local m = mgr()
    run(m .. " emergency >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_confirm()
    local m = mgr()
    run(m .. " confirm >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_emergency()
    local m = mgr()
    run(m .. " emergency >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_restart()
    local m = mgr()
    run(m .. " restart >/tmp/zi_start.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_log()
    local log = run("tail -c 8192 /var/log/zlt-ipsec.log")
    if log == "" then
        log = read_file("/tmp/zi_start.log")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true, log = log })
end

function action_ss_check()
    local m = mgr()
    local out = mgr_exists() and run(m .. " ss_check") or "zi-manager not installed"
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true, check = out })
end

local function do_import_file(tmp)
    local m = mgr()
    local out = run(m .. " import " .. shq(tmp) .. " >/tmp/zi_import.log 2>&1; echo EXIT:$?")
    local err = read_file("/tmp/zi_import.log")
    if out:match("EXIT:0") then
        return true, err
    end
    return false, (err ~= "" and err or out)
end

function action_import_begin()
    write_file(IMPORT_TMP, "")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_import_chunk()
    -- small chunks avoid OEM uhttpd/LuCI POST truncation of huge cert JSON
    local data = luci.http.formvalue("data") or luci.http.formvalue("chunk") or ""
    luci.http.prepare_content("application/json")
    if data == "" then
        luci.http.write_json({ ok = false, error = "empty chunk" })
        return
    end
    local fh = io.open(IMPORT_TMP, "a")
    if not fh then
        luci.http.write_json({ ok = false, error = "cannot append import tmp" })
        return
    end
    fh:write(data)
    fh:close()
    luci.http.write_json({ ok = true, n = #data })
end

function action_import_commit()
    luci.http.prepare_content("application/json")
    local raw = read_file(IMPORT_TMP)
    if raw == "" then
        luci.http.write_json({ ok = false, error = "empty import buffer — Save again" })
        return
    end
    local ok, err = do_import_file(IMPORT_TMP)
    if ok then
        luci.http.write_json({ ok = true, bytes = #raw })
    else
        luci.http.write_json({ ok = false, error = err })
    end
end

function action_import()
    local body = luci.http.formvalue("config") or ""
    luci.http.prepare_content("application/json")
    if body == "" then
        luci.http.write_json({ ok = false, error = "empty config — use chunked save" })
        return
    end
    if not write_file(IMPORT_TMP, body) then
        luci.http.write_json({ ok = false, error = "cannot write tmp" })
        return
    end
    local ok, err = do_import_file(IMPORT_TMP)
    if ok then
        luci.http.write_json({ ok = true, bytes = #body })
    else
        luci.http.write_json({ ok = false, error = err })
    end
end

function action_import_manual()
    local host = luci.http.formvalue("host") or ""
    local id = luci.http.formvalue("id") or ""
    local pass = luci.http.formvalue("password") or ""
    local ike = luci.http.formvalue("ike") or "aes256-sha256-modp2048"
    local esp = luci.http.formvalue("esp") or "aes128gcm16"
    local p12b64 = luci.http.formvalue("p12_b64") or ""
    if host == "" or id == "" or p12b64 == "" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ ok = false, error = "host, id and p12 required" })
        return
    end
    write_file("/tmp/zi_manual.b64", p12b64)
    run("openssl base64 -d -A -in /tmp/zi_manual.b64 -out /tmp/zi_manual.p12")
    local m = mgr()
    local out = run(string.format(
        "%s import-manual %s %s %s %s %s %s >/tmp/zi_import.log 2>&1; echo EXIT:$?",
        m, shq(host), shq(id), shq("/tmp/zi_manual.p12"), shq(pass), shq(ike), shq(esp)))
    local err = read_file("/tmp/zi_import.log")
    luci.http.prepare_content("application/json")
    if out:match("EXIT:0") then
        luci.http.write_json({ ok = true })
    else
        luci.http.write_json({ ok = false, error = (err ~= "" and err or out) })
    end
end
