-- agent panel for rex's init.lua: require("agents") from beside it
local source = (debug.getinfo(1, 'S') or {}).source or ''
local root = source:gsub('^@', ''):match('^(/.*)/[^/]+$') or ((os.getenv('HOME') or '') .. '/.config/rex/agents')
local core = assert(loadfile(root .. '/lib/core.lua'))(root)
local json = assert(loadfile(root .. '/lib/json.lua'))(root)

local function call(method, value)
  local result, err = rex.call(method, value or {})
  if result == nil and err ~= nil then error(tostring(err), 0) end
  return result or {}
end

-- every change goes through the running collector
local function ask(action, ctx)
  local c = core.find_collector(call)
  if not c then return nil end
  local r = call('client.perform', {client_id = c.client_id, action = action, timeout_ms = 8000,
    args = {session_id = ctx.session_id, block_id = ctx.block_id}})
  return r.result or {ok = true}
end

local function first(ctx) return core.first_panel(call, ctx, core.config(root)) end

local actions = {
  {'show_agent_panel', 'show agent panel', function(ctx) return ask('show', ctx) or first(ctx) end},
  {'hide_agent_panel', 'hide agent panel', function(ctx)
    return ask('hide', ctx) or error('agent panel is not running', 0)
  end},
  {'repair_agent_panel', 'repair agent panel', function(ctx) return ask('repair', ctx) or first(ctx) end},
}
for _, a in ipairs(actions) do
  rex.action{name = a[1], title = a[2], category = 'agents', run = a[3]}
end

-- the config can't call the api while it loads, so the collector starts beside
-- the server and adds panels once an app connects
local function start()
  if not rex.exec or not os.getenv('REX_SERVER') then return end
  local ok, cfg = pcall(core.config, root)
  if not ok then return end
  local q = core.shell_quote
  local script = table.concat({
    'case "$(/bin/ps -o args= -p $PPID)" in *" server run "*) ;; *) exit 0 ;; esac',
    'rex=$(/bin/ps -o comm= -p $PPID)',
    'case "$rex" in */rex) ;; *) rex=' .. q(core.rex_bin()) .. ' ;; esac',
    'state=' .. q(cfg.state),
    '[ -e "$state/off" ] && exit 0',
    'pid=$(cat "$state/collector.pid" 2>/dev/null)',
    '[ -n "$pid" ] && /bin/ps -o command= -p "$pid" 2>/dev/null | grep -qF ' .. q(root .. '/collector.lua') .. ' && exit 0',
    'mkdir -p "$state" && chmod 700 "$state"',
    '(',
    '  exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- </dev/null >>"$state/collector.log" 2>&1',
    '  unset REX_SERVER_START_LOCK_FD REX_SERVER_READY_FD REX_SERVER_LOG_PATH',
    '  i=0',
    '  until "$rex" --autostart=false --timeout=1s api call server.status "{}" >/dev/null 2>&1; do',
    '    i=$((i + 1)); [ $i -ge 150 ] && exit 0; sleep 0.2',
    '  done',
    '  exec "$rex" --autostart=false do --all ' .. q(root .. '/collector.lua') .. ' --args '
      .. q(json.encode(core.collector_args(cfg))),
    ') &',
  }, '\n')
  -- detached, so rex doesn't stop it once the config has loaded
  if rex.exec.start then
    rex.exec.start({'/bin/sh', '-c', script}, {detach = true})
  else
    rex.exec({'/bin/sh', '-c', script})
  end
end
start()
