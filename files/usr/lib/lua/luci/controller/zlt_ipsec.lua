-- LuCI controller for ZLT IPsec (zi-manager)
module("luci.controller.zlt_ipsec", package.seeall)

local ZI_API_VERSION = 1

function index()
    entry({"admin", "services", "zlt_ipsec"}, template("zlt_ipsec_panel"), _("ZLT IPsec"), 60).dependent = false

    entry({"admin", "services", "zlt_ipsec", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "start"}, call("action_start")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import"}, call("action_import")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "import_manual"}, call("action_import_manual")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "log"}, call("action_log")).leaf = true
    entry({"admin", "services", "zlt_ipsec", "ss_check"}, call("action_ss_check")).leaf = true
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
    return "/usr/bin/zi-manager"
end

local function mgr_exists()
    local m = mgr()
    local f = io.open(m, "r")
    if f then f:close(); return true end
    return false
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
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        ok = true,
        running = status,
        host = read_file("/etc/zlt-ipsec/material/host"),
        user = read_file("/etc/zlt-ipsec/material/user"),
        ping_fails = read_file("/etc/zlt-ipsec/ping_fails"),
        active = read_file("/etc/zlt-ipsec/active"),
        api_version = ZI_API_VERSION,
        manager_version = ver,
        manager_path = m
    })
end

function action_start()
    local m = mgr()
    run(m .. " start >/tmp/zi_start.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_stop()
    local m = mgr()
    run(m .. " stop >/dev/null 2>&1")
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
    local out = ""
    if mgr_exists() then
        out = run(m .. " ss_check")
    else
        out = "zi-manager not installed"
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true, check = out })
end

function action_import()
    local body = luci.http.formvalue("config") or ""
    if body == "" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ ok = false, error = "empty config" })
        return
    end
    local tmp = "/tmp/zi_import_cfg"
    if not write_file(tmp, body) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ ok = false, error = "cannot write tmp" })
        return
    end
    local m = mgr()
    local out = run(m .. " import " .. shq(tmp) .. " >/tmp/zi_import.log 2>&1; echo EXIT:$?")
    local err = read_file("/tmp/zi_import.log")
    local ok = out:match("EXIT:0") ~= nil
    luci.http.prepare_content("application/json")
    if ok then
        luci.http.write_json({ ok = true })
    else
        luci.http.write_json({ ok = false, error = (err ~= "" and err or out) })
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
