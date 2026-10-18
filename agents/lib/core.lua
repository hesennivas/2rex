-- shared by the collector, the config actions and the view (lua 5.1)
local M = {}

M.collector_label = 'rex-agents-collector'
M.panel_label = 'agents'
M.min_columns = 90
M.panel_columns = 34
M.terminal = 'com.superlogical.terminal'

local default_states = {working = 'running', blocked = 'needs', error = 'needs', idle = 'idle', done = 'idle'}
local generic_labels = {[''] = true, shell = true, zsh = true, bash = true, fish = true, sh = true, nu = true, login = true}

function M.clean(s)
  s = tostring(s or ''):gsub('[%z\1-\31\127]', ' '):gsub('\194[\128-\159]', ' ')
  return s
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

local function basename(s)
  local b = (s or ''):match('([^/]+)/*$') or ''
  b = b:gsub('^%-', ''):gsub('%.exe$', '')
  return b
end
M.basename = basename

function M.identify(proc, providers)
  if not proc then return nil end
  for _, p in ipairs(providers) do
    for _, key in ipairs({'path', 'invoked_path', 'argv0', 'script'}) do
      local s = proc[key]
      if type(s) == 'string' and s ~= '' then
        if contains(p.bins, basename(s)) then return p end
        for _, frag in ipairs(p.paths or {}) do
          if s:find(frag, 1, true) then return p end
        end
      end
    end
  end
end

-- the foreground process, then its ancestors, then the block's child
function M.agent(info, providers)
  if not info then return nil end
  local list = {}
  if info.foreground then list[#list + 1] = info.foreground end
  for _, p in ipairs(info.ancestors or {}) do list[#list + 1] = p end
  if info.child then list[#list + 1] = info.child end
  for _, p in ipairs(list) do
    local provider = M.identify(p, providers)
    if provider then return provider, p end
  end
end

-- rex reports login as the foreground of a block started with a command,
-- so look through login's process group. run(argv) -> stdout
function M.behind_login(info, providers, run)
  local fg = info and info.foreground
  if not fg or fg.name ~= 'login' or type(fg.pid) ~= 'number' then return nil end
  for line in run({'/bin/ps', '-o', 'pid=,ppid=,comm=', '-g', tostring(fg.pid)}):gmatch('[^\n]+') do
    local pid, comm = line:match('^%s*(%d+)%s+%d+%s+(.-)%s*$')
    pid = tonumber(pid)
    if pid and pid ~= fg.pid then
      local proc = {pid = pid, name = M.basename(comm), path = comm, argv0 = comm, via = fg.pid}
      local provider = M.identify(proc, providers)
      if provider then
        proc.cwd = run({'/usr/sbin/lsof', '-a', '-p', tostring(pid), '-d', 'cwd', '-Fn'}):match('\nn(/[^\n]*)') or ''
        return provider, proc
      end
    end
  end
end

-- the root status record the agent process itself reported (or login for it)
function M.status(records, proc, provider)
  for _, r in ipairs(records or {}) do
    local owner = type(r.owner) == 'table' and r.owner.pid
    if (r.id == nil or r.id == '') and owner and (owner == proc.pid or owner == proc.via) then
      local app = (r.effective_app or r.app or ''):lower()
      if app == '' or contains(provider.apps, app) then return r end
    end
  end
end

function M.category(raw, provider)
  if not raw then return nil end
  return ((provider and provider.states) or default_states)[raw]
end

-- drop spinner and status glyphs agents put in front of their title
function M.strip_title(s)
  s = M.clean(s)
  local before
  repeat
    before = s
    s = s:gsub('^[%s%*%-%.·]+', '')
    s = s:gsub('^\226[\150-\163][\128-\191]', '')
    s = s:gsub('^\194[\160-\191]', '')
  until s == before
  return (s:gsub('%s+$', ''))
end

-- program status title, else block label, else terminal title, else agent name
function M.title(a, label)
  local provider = a.provider
  local function usable(s)
    s = M.strip_title(s)
    local lower = s:lower()
    if generic_labels[lower] or lower == provider.name or contains(provider.titles, lower) then return nil end
    -- rex names a block nobody labelled after its id
    if lower:match('^block %x+$') then return nil end
    return s
  end
  return usable(a.status_title) or usable(label) or usable(a.term_title) or provider.name
end

-- repo root for a folder; worktrees join their main repo
function M.project(cwd, read, home)
  if type(cwd) ~= 'string' or cwd:sub(1, 1) ~= '/' then return cwd or '' end
  local dir = cwd:gsub('/+$', '')
  if dir == '' then dir = '/' end
  while true do
    if dir == home and dir ~= cwd then break end
    local git = read(dir .. (dir == '/' and '' or '/') .. '.git')
    if git then
      local gitdir = git:match('^gitdir:%s*(.-)%s*$')
      local main = gitdir and gitdir:match('^(/.*)/%.git/worktrees/[^/]+/?$')
      return main or dir
    end
    if dir == '/' then break end
    dir = dir:match('^(.*)/[^/]*$')
    if dir == '' then dir = '/' end
  end
  return (cwd:gsub('/+$', ''))
end

function M.read(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s or ''
end

function M.timestamp(s)
  if type(s) ~= 'string' then return nil end
  local y, m, d, h, mi, se = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)')
  if not y then return nil end
  y, m, d, h, mi, se = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
  local offset = 0
  local sign, oh, om = s:match('([+-])(%d%d):(%d%d)$')
  if sign then offset = (tonumber(oh) * 60 + tonumber(om)) * 60 * (sign == '+' and 1 or -1) end
  return days * 86400 + h * 3600 + mi * 60 + se - offset
end

function M.ago(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then return seconds .. 's' end
  if seconds < 3600 then return math.floor(seconds / 60) .. 'm' end
  if seconds < 86400 then return math.floor(seconds / 3600) .. 'h' end
  return math.floor(seconds / 86400) .. 'd'
end

-- local clock time of t: 14:05 today, oct 17 before
function M.clock(t, now)
  if os.date('%Y%m%d', t) == os.date('%Y%m%d', now) then return os.date('%H:%M', t) end
  return os.date('%b', t):lower() .. ' ' .. tonumber(os.date('%d', t))
end

-- branch and changes from git status --porcelain=v2 --branch
function M.git_status(out)
  local g = {ahead = 0, behind = 0, changed = 0}
  for line in (out or ''):gmatch('[^\n]+') do
    local head = line:match('^# branch%.head (.+)$')
    local oid = line:match('^# branch%.oid (%x+)')
    local ahead, behind = line:match('^# branch%.ab %+(%d+) %-(%d+)')
    if head then g.branch = head
    elseif oid then g.oid = oid:sub(1, 7)
    elseif ahead then g.ahead, g.behind = tonumber(ahead), tonumber(behind)
    elseif line:match('^[12u?] ') then g.changed = g.changed + 1 end
  end
  if g.branch == '(detached)' then g.branch = g.oid end
  g.oid = nil
  return g.branch and g or nil
end

function M.find_git()
  for _, p in ipairs({'/opt/homebrew/bin/git', '/usr/local/bin/git', '/usr/bin/git'}) do
    if M.exists(p) then return p end
  end
end

function M.leaves(node, out)
  out = out or {}
  if node and node.block_id then out[#out + 1] = node
  elseif node and node.split then
    M.leaves(node.split.before, out)
    M.leaves(node.split.after, out)
  end
  return out
end

function M.tiled(window)
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == 'tiled' and layer.layout then return layer end
  end
end

-- columns an app shows for a block, nil when no app has sized it.
-- apps is a set of app client ids
function M.block_columns(size, apps)
  if type(size) ~= 'table' then return nil end
  local best
  for _, d in ipairs(size.desired or {}) do
    if (d.columns or 0) > (best or 0) then best = d.columns end
  end
  if best then return best end
  if size.owner and apps and apps[size.owner] and (size.columns or 0) > 0 then return size.columns end
end

function M.app_set(clients)
  local set = {}
  for _, c in ipairs(clients) do set[c.client_id] = true end
  return set
end

function M.window_columns(columns, rect_width)
  if not columns or not rect_width or rect_width <= 0 then return nil end
  return math.floor(columns / rect_width + 0.5)
end

-- output of a shell command; rex's lua has no io.popen, only rex.exec
local function sh(cmd)
  if rex and rex.exec then
    local r = rex.exec({'/bin/sh', '-c', cmd})
    return r and r.ok and r.stdout or ''
  end
  local ok, out = pcall(function()
    local h = io.popen(cmd)
    local text = h:read('*a')
    h:close()
    return text
  end)
  return ok and out or ''
end

function M.find_luajit()
  for _, p in ipairs({'/opt/homebrew/bin/luajit', '/usr/local/bin/luajit', '/opt/local/bin/luajit', '/usr/bin/luajit'}) do
    if M.exists(p) then return p end
  end
  local p = (sh('command -v luajit 2>/dev/null'):match('[^\n]*')):gsub('%s+$', '')
  if p ~= '' then return p end
end

function M.home() return os.getenv('HOME') or '' end

M.rex_paths = {'/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex',
  '/Applications/Rex.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex'}

function M.exists(path)
  local f = io.open(path, 'r')
  if f then f:close() end
  return f ~= nil
end

-- the app keeps updated servers in its support folder; pick the newest build
local function installed_versions()
  local base = M.home() .. '/Library/Application Support/com.superlogical.rex/RexServer/Versions'
  local best
  for v in sh('ls -1 ' .. M.shell_quote(base) .. ' 2>/dev/null'):gmatch('[^\n]+') do
    if tonumber(v) and (not best or tonumber(v) > tonumber(best)) then best = v end
  end
  return best and base .. '/' .. best .. '/Rex Server.app/Contents/MacOS/rex'
end

function M.rex_bin()
  local dir = os.getenv('REX_BIN_DIR')
  if dir and dir ~= '' and M.exists(dir .. '/rex') then return dir .. '/rex' end
  local newest = installed_versions()
  if newest and M.exists(newest) then return newest end
  for _, p in ipairs(M.rex_paths) do if M.exists(p) then return p end end
  return 'rex'
end

function M.shell_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

function M.state_dir()
  local base = os.getenv('XDG_STATE_HOME')
  if not base or base == '' then base = M.home() .. '/.local/state' end
  return base .. '/rex/agents'
end

function M.panel_layout(cfg)
  return {block = {flavor = M.terminal .. '.shell', label = M.panel_label, options = {
    shell = 'none', cwd = cfg.home,
    command = {cfg.luajit, cfg.root .. '/view.lua', cfg.state},
    exit = {on_completion = true},
  }}}
end

-- the panel spans the window's full height when the root splits left and right
-- with the panel first
function M.full_height(layout, panel)
  local split = layout and layout.split
  return split ~= nil and split.direction == 'horizontal' and split.before.block_id == panel
end

local function first_leaf(node)
  while node.split do node = node.split.before end
  return node.block_id
end

-- the tiled tree without the panel; its sibling takes its parent's place
function M.without(node, panel)
  if node.block_id then return node.block_id ~= panel and node or nil end
  local before, after = M.without(node.split.before, panel), M.without(node.split.after, panel)
  if not before or not after then return before or after end
  return {split = {direction = node.split.direction, ratio = node.split.ratio, before = before, after = after}}
end

-- session.move_block steps that rebuild tree to the right of a lone panel
function M.rebuild_steps(tree, panel, ratio)
  local steps = {{block_id = first_leaf(tree), anchor_block_id = panel, direction = 'horizontal', side = 'after', ratio = ratio}}
  local function walk(node)
    if not node.split then return end
    steps[#steps + 1] = {block_id = first_leaf(node.split.after), anchor_block_id = first_leaf(node.split.before),
      direction = node.split.direction, side = 'after', ratio = node.split.ratio}
    walk(node.split.before)
    walk(node.split.after)
  end
  walk(tree)
  return steps
end

-- share of the window the panel takes; the default width shrinks in narrow
-- windows, a width the user dragged to is kept as long as it fits
function M.panel_ratio(window, panel)
  if not panel then return math.min(0.36, M.panel_columns / window) end
  return math.max(0.02, math.min(0.9, panel / window))
end

-- split a panel in front of the window's first tiled block
function M.place(call, sid, anchor, columns, cfg, panel)
  local ratio = M.panel_ratio(columns, panel)
  local result = call('session.new_split', {session_id = sid, anchor_block_id = anchor, direction = 'horizontal',
    side = 'before', ratio = ratio, focus = false, layout = M.panel_layout(cfg)})
  local bid = result.block_ids and result.block_ids[1]
  if not bid then error('rex did not create the panel', 0) end
  call('session.disown_block', {session_id = sid, block_ids = {bid}})
  return bid
end

local function connected(c) return c.connection_state == nil or c.connection_state == 'connected' end

function M.find_collector(call)
  for _, c in ipairs(call('client.list', {}).clients or {}) do
    if (c.info or {}).label == M.collector_label and connected(c) then return c end
  end
end

function M.app_clients(call)
  local out = {}
  for _, c in ipairs(call('client.list', {kinds = {'app'}}).clients or {}) do
    if (c.info or {}).kind == 'app' and connected(c) then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.client_id < b.client_id end)
  return out
end

function M.config(root)
  local luajit = M.find_luajit()
  if not luajit then error('luajit not found; install it with: brew install luajit', 0) end
  return {root = root, state = M.state_dir(), luajit = luajit, home = M.home()}
end

-- collector arguments; host is the panel block that starts it, nil at config load
function M.collector_args(cfg, host)
  return {root = cfg.root, state = cfg.state, luajit = cfg.luajit, host = host}
end

local function find_window(view, block_id)
  for _, w in ipairs(view.windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        if b.block_id == block_id then return w end
      end
    end
  end
  for _, w in ipairs(view.windows or {}) do
    if w.window_id == view.active_window_id then return w end
  end
end
M.find_window = find_window

-- used by the show action when no collector runs yet; the new panel starts it
function M.first_panel(call, ctx, cfg)
  if not ctx.session_id then error('open a rex session first', 0) end
  pcall(call, 'session.attach', {session_id = ctx.session_id})
  local view = call('session.view', {session_id = ctx.session_id})
  local w = find_window(view, ctx.block_id)
  if not w then error('window no longer exists', 0) end
  if w.zoomed_block_id then error('unzoom the window first', 0) end
  local layer = M.tiled(w)
  if not layer then error('window has no tiled layout', 0) end
  local first = M.leaves(layer.layout)[1]
  local columns
  local apps = M.app_set(M.app_clients(call))
  for _, leaf in ipairs(M.leaves(layer.layout)) do
    local size = call(M.terminal .. '.size', {session_id = ctx.session_id, block_id = leaf.block_id, args = {}})
    columns = M.window_columns(M.block_columns(size, apps), leaf.rect and leaf.rect[3])
    if columns then break end
  end
  if not columns then error('window size unknown; show the window first', 0) end
  if columns < M.min_columns then error('window is narrower than ' .. M.min_columns .. ' columns', 0) end
  local bid = M.place(call, ctx.session_id, first.block_id, columns, cfg)
  return {ok = true, block_id = bid}
end

return M
