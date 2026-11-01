-- LuCI controller for Sing-Box VPN Manager
-- api_version bumped when breaking UI/controller fixes ship (check status JSON).
module("luci.controller.singbox", package.seeall)

local SB_API_VERSION = 4

function index()
    if not nixio.fs.access("/usr/bin/sb-manager") then
        return
    end

    entry({"admin", "services", "singbox"}, template("singbox_panel"), _("Sing-Box VPN"), 60).dependent = false

    entry({"admin", "services", "singbox", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "singbox", "start"}, call("action_start")).leaf = true
    entry({"admin", "services", "singbox", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "services", "singbox", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "services", "singbox", "switch"}, call("action_switch")).leaf = true
    entry({"admin", "services", "singbox", "addnode"}, call("action_addnode")).leaf = true
    entry({"admin", "services", "singbox", "delnode"}, call("action_delnode")).leaf = true
    entry({"admin", "services", "singbox", "listnodes"}, call("action_listnodes")).leaf = true
    entry({"admin", "services", "singbox", "mode"}, call("action_mode")).leaf = true
    entry({"admin", "services", "singbox", "watchdog"}, call("action_watchdog")).leaf = true
    entry({"admin", "services", "singbox", "log"}, call("action_log")).leaf = true
end

-- Run a shell command; return trimmed stdout as a SINGLE string.
-- IMPORTANT: never return string.gsub(...) directly — gsub returns
-- (result, nsubs), and callers like tonumber(run(...)) would treat nsubs
-- as the numeric base (e.g. tonumber("0", 1) → "base out of range").
local function run(cmd)
    local f = io.popen(cmd)
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

-- Parse an integer from a string safely (ignore gsub secondary returns, junk).
local function to_int(s, default)
    if s == nil then return default end
    if type(s) == "number" then
        if s ~= s then return default end -- NaN
        return math.floor(s)
    end
    s = tostring(s):match("^%s*([-+]?%d+)") or ""
    if s == "" then return default end
    return tonumber(s, 10) or default
end

-- Shell-quote a single argument to prevent command injection via LuCI params.
local function shq(s)
    s = s or ""
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Node ids are restricted to safe filename characters only.
local function valid_id(id)
    return id ~= nil and id ~= "" and id:match("^[A-Za-z0-9_%-]+$") ~= nil
end

function action_status()
    local running = run("/usr/bin/sb-manager status")
    local active = run("/usr/bin/sb-manager active")
    local mode = run("/usr/bin/sb-manager mode_status")
    local led = run("/usr/bin/sb-manager led_status")
    local watchdog = run("/usr/bin/sb-manager watchdog_status")
    local proto = run("/usr/bin/sb-manager nodetype")
    local mgr_ver = run("/usr/bin/sb-manager version")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running = running,
        active_node = active,
        mode = mode,
        led = led,
        watchdog = watchdog,
        proto = proto,
        api_version = SB_API_VERSION,
        manager_version = mgr_ver,
    })
end

function action_start()
    run("/usr/bin/sb-manager start >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_stop()
    run("/usr/bin/sb-manager stop >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_restart()
    run("/usr/bin/sb-manager restart >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_switch()
    local id = luci.http.formvalue("id")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    run("/usr/bin/sb-manager switch " .. shq(id))
    luci.http.write_json({ ok = true })
end

function action_addnode()
    local id = luci.http.formvalue("id")
    local link = luci.http.formvalue("link")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    if not link or link == "" then
        luci.http.write_json({ ok = false, error = "empty config (use POST; GET truncates long payloads)" })
        return
    end

    -- Accept vless://, Amnezia vpn:// share links, or IPsec JSON.
    local trimmed = link:match("^%s*(.-)%s*$") or link
    local is_ipsec = trimmed:sub(1, 1) == "{"
    local is_vless = trimmed:match("^[Vv][Ll][Ee][Ss][Ss]://") ~= nil
    local is_vpn = trimmed:match("^[Vv][Pp][Nn]://") ~= nil
    if not is_ipsec and not is_vless and not is_vpn then
        luci.http.write_json({
            ok = false,
            error = "paste vless://, vpn:// (Amnezia), or IPsec JSON ({cert, hostName, ...})"
        })
        return
    end

    local payload = link
    if is_vless or is_vpn then
        -- Strip whitespace/newlines inside share links (vpn:// is one token).
        payload = link:gsub("^[%s\"']+", ""):gsub("[%s\"']+$", ""):gsub("%s+", "")
    else
        -- Keep JSON structure; only trim outer whitespace.
        payload = trimmed
    end

    -- Guard against truncated POSTs (uhttpd body limits) for Amnezia JSON.
    if is_ipsec then
        local opens = select(2, payload:gsub("%{", ""))
        local closes = select(2, payload:gsub("%}", ""))
        if opens ~= closes or not payload:find('"cert"') then
            luci.http.write_json({
                ok = false,
                error = "IPsec JSON looks truncated or incomplete (missing cert / unbalanced braces). Try vpn:// in LuCI (browser decode) or a smaller paste."
            })
            return
        end
    end

    local tmp = "/tmp/sb_link_" .. id .. ".txt"
    local rc_file = "/tmp/sb_addnode_" .. id .. ".rc"
    local err_file = "/tmp/sb_addnode_" .. id .. ".err"
    if not write_file(tmp, payload) then
        luci.http.write_json({ ok = false, error = "failed to write temp file" })
        return
    end

    -- Unique rc/err paths avoid races if two adds overlap.
    run("/usr/bin/sb-manager addnode " .. shq(id) .. " " .. shq(tmp)
        .. " >" .. shq(err_file) .. " 2>&1; echo $? > " .. shq(rc_file))
    os.remove(tmp)

    local rc = to_int(read_file(rc_file), 1)
    os.remove(rc_file)

    if rc ~= 0 then
        local err = read_file(err_file)
        os.remove(err_file)
        if err == "" then
            err = "failed to parse config (rc=" .. tostring(rc) .. ")"
        end
        -- Keep error message bounded for the UI.
        if #err > 400 then
            err = err:sub(1, 400) .. "..."
        end
        luci.http.write_json({ ok = false, error = err })
        return
    end
    os.remove(err_file)

    -- Activate the new node so Start/Restart actually uses it.
    run("/usr/bin/sb-manager switch " .. shq(id))
    local ntype = run("/usr/bin/sb-manager nodetype " .. shq(id))
    luci.http.write_json({ ok = true, activated = id, proto = ntype })
end

function action_delnode()
    local id = luci.http.formvalue("id")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    run("/usr/bin/sb-manager delnode " .. shq(id))
    luci.http.write_json({ ok = true })
end

function action_listnodes()
    local out = run("/usr/bin/sb-manager listnodes")
    local nodes = {}
    for id in out:gmatch("[^\n]+") do
        table.insert(nodes, id)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ nodes = nodes })
end

function action_mode()
    local mode = luci.http.formvalue("mode")
    luci.http.prepare_content("application/json")
    if mode ~= "tunnel" and mode ~= "proxy" then
        luci.http.write_json({ ok = false, error = "mode must be 'tunnel' or 'proxy'" })
        return
    end
    run("/usr/bin/sb-manager mode_toggle " .. shq(mode))
    luci.http.write_json({ ok = true })
end

function action_watchdog()
    local state = luci.http.formvalue("state")
    luci.http.prepare_content("application/json")
    if state ~= "0" and state ~= "1" then
        luci.http.write_json({ ok = false, error = "state must be 0 or 1" })
        return
    end
    run("/usr/bin/sb-manager watchdog_toggle " .. shq(state))
    luci.http.write_json({ ok = true })
end

function action_log()
    -- Return JSON so LuCI XHR.get can parse it (text/plain left data=null in the UI).
    local text = ""
    local f = io.open("/var/log/singbox.log", "r")
    if f then
        local size = f:seek("end")
        if size and size > 8000 then
            f:seek("set", size - 8000)
        else
            f:seek("set", 0)
        end
        text = f:read("*a") or ""
        f:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ log = text })
end
