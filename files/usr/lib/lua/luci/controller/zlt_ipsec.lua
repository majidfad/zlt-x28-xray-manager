module("luci.controller.zlt_ipsec", package.seeall)

function index()
    entry({"admin", "services", "zlt_ipsec"}, template("zlt_ipsec_panel"), _("ZLT IPsec"), 60)
    entry({"admin", "services", "zlt_ipsec", "api"}, call("action_api")).leaf = true
end

local function q(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function readf(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local d = f:read("*a") or ""
    f:close()
    return d
end

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then return "" end
    local o = p:read("*a") or ""
    p:close()
    return (o:gsub("%s+$", ""))
end

local function mgr()
    local f = io.open("/data/zi-bin/zi-manager", "r")
    if f then
        f:close()
        return "/data/zi-bin/zi-manager"
    end
    return "/usr/bin/zi-manager"
end

local function ok_rc(rc)
    if rc == true or rc == 0 then return true end
    if type(rc) == "number" and rc == 0 then return true end
    return false
end

function action_api()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    local act = http.formvalue("act") or "status"
    local m = mgr()

    if act == "status" then
        local status = run(m .. " status")
        local ver = run(m .. " version")
        local host = readf("/etc/zlt-ipsec/material/host"):gsub("%s+$", "")
        local user = readf("/etc/zlt-ipsec/material/user"):gsub("%s+$", "")
        local fails = readf("/etc/zlt-ipsec/ping_fails"):gsub("%s+$", "")
        local active = readf("/etc/zlt-ipsec/active"):gsub("%s+$", "")
        local log = run("tail -n 80 /var/log/zlt-ipsec.log")
        http.write(jsonc.stringify({
            ok = true,
            status = status,
            version = ver,
            host = host,
            user = user,
            ping_fails = fails,
            active = active,
            log = log
        }))
        return
    end

    if act == "stop" then
        os.execute(m .. " stop >/dev/null 2>&1")
        http.write('{"ok":true}')
        return
    end

    if act == "start" then
        os.execute(m .. " start >/tmp/zi_start.log 2>&1 &")
        http.write('{"ok":true}')
        return
    end

    if act == "restart" then
        os.execute(m .. " restart >/tmp/zi_start.log 2>&1 &")
        http.write('{"ok":true}')
        return
    end

    if act == "import" then
        local body = http.formvalue("config") or ""
        if body == "" then
            http.write('{"ok":false,"error":"empty config"}')
            return
        end
        local tmp = "/tmp/zi_import_cfg"
        local f = io.open(tmp, "w")
        if not f then
            http.write('{"ok":false,"error":"cannot write tmp"}')
            return
        end
        f:write(body)
        f:close()
        local rc = os.execute(m .. " import " .. q(tmp) .. " >/tmp/zi_import.log 2>&1")
        if ok_rc(rc) then
            http.write('{"ok":true}')
        else
            http.write(jsonc.stringify({ ok = false, error = readf("/tmp/zi_import.log") }))
        end
        return
    end

    if act == "import_manual" then
        local host = http.formvalue("host") or ""
        local id = http.formvalue("id") or ""
        local pass = http.formvalue("password") or ""
        local ike = http.formvalue("ike") or "aes256-sha256-modp2048"
        local esp = http.formvalue("esp") or "aes128gcm16"
        local p12b64 = http.formvalue("p12_b64") or ""
        if host == "" or id == "" or p12b64 == "" then
            http.write('{"ok":false,"error":"host, id and p12 required"}')
            return
        end
        local p12path = "/tmp/zi_manual.p12"
        local b64f = io.open("/tmp/zi_manual.b64", "w")
        if not b64f then
            http.write('{"ok":false,"error":"cannot write b64"}')
            return
        end
        b64f:write(p12b64)
        b64f:close()
        os.execute("openssl base64 -d -A -in /tmp/zi_manual.b64 -out " .. p12path .. " 2>/tmp/zi_b64.err")
        local rc = os.execute(string.format("%s import-manual %s %s %s %s %s %s >/tmp/zi_import.log 2>&1",
            m, q(host), q(id), q(p12path), q(pass), q(ike), q(esp)))
        if ok_rc(rc) then
            http.write('{"ok":true}')
        else
            http.write(jsonc.stringify({ ok = false, error = readf("/tmp/zi_import.log") }))
        end
        return
    end

    http.write('{"ok":false,"error":"unknown act"}')
end
