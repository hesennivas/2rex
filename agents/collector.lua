-- agent collector: rex do --all collector.lua --args {...}
-- started by the config at load or by the first panel. the only writer of the
-- state folder; exits when the user closes the last panel
local args = rex.args or {}
local root, state = assert(args.root, 'missing root'), assert(args.state, 'missing state')
local function use(name) return assert(loadfile(root .. '/lib/' .. name .. '.lua'))(root) end
local json, core, providers = use('json'), use('core'), use('providers')

local function log(s) io.stderr:write(os.date('%H:%M:%S ') .. tostring(s) .. '\n'); io.stderr:flush() end

local function call(method, value)
  local result, err = rex.call(method, value or {})
  if result == nil and err ~= nil then error(tostring(err), 0) end
  return result or {}
end
local function try(method, value)
  local ok, result = pcall(call, method, value)
  if ok then return result end
end
local function term(method, sid, bid)
  return try(core.terminal .. '.' .. method, {session_id = sid, block_id = bid, args = {}})
end

local function put(name, text)
  local path = state .. '/' .. name
  local f = assert(io.open(path .. '.tmp', 'w'))
  f:write(text)
  f:close()
  assert(os.rename(path .. '.tmp', path))
end
local function write(name, value) put(name, json.encode(value) .. '\n') end
local function load(name)
  local s = core.read(state .. '/' .. name)
  local ok, value = pcall(json.decode, s or '')
  if ok and type(value) == 'table' then return value end
end

-- identity and singleton
local instance = call('server.status').instance_id
local pid = (call('server.whoami').principal or {}).pid
call('client.set_label', {label = core.collector_label})
local me
local others = {}
local function alive(p)
  if type(p) ~= 'number' then return false end
  local ok, r = pcall(rex.exec, {'/bin/kill', '-0', tostring(p)})
  return ok and type(r) == 'table' and r.code == 0
end
for _, c in ipairs(call('client.list').clients or {}) do
  local cpid = (c.principal or {}).pid
  if (c.info or {}).label == core.collector_label then
    if cpid == pid then me = c.client_id
    elseif (c.connection_state == nil or c.connection_state == 'connected') and alive(cpid) then
      others[#others + 1] = c.client_id
    end
  end
end
for _, other in ipairs(others) do
  if me and other < me then
    log('another collector is running')
    return
  end
end
put('collector.pid', tostring(pid) .. '\n')

local cfg = {root = root, state = state, luajit = args.luajit or core.find_luajit(), home = core.home()}
local only = (load('settings.json') or {}).only
if type(only) ~= 'string' or only == '' then only = nil end

-- live state
local sessions = {}   -- sid -> {label, view, windows}
local blocks = {}     -- bid -> {session_id, window_id, label, rect}
local agents = {}     -- bid -> agent
local columns = {}    -- bid -> columns an app shows
local widths = {}     -- sid -> window columns last seen in that session
local any_width      -- window columns last seen anywhere
local failed = {}    -- 'sid/wid' -> last reason a panel could not be added
local user_closed = false -- the last panel went away because the user closed it
local held = {}      -- 'sid/wid' -> {ratio, leaves, width, timer, till}: the panel border as last set
local stopping = false
local generation = {} -- bid -> process generation
local focus_of = {}   -- sid -> focused block
local current         -- block the user looked at last
local current_agent   -- agent block the user looked at last
local apps = {}
local closing = {}    -- panel blocks the collector is closing itself
local projects = {}   -- cwd -> repo root
local attached = {}   -- sid -> attached, needed for block methods
local taking_stock = false -- agents found now were already running, not just started

-- persisted state
local saved = load('collector.json') or {}
-- window and panel widths outlive a restart
if type(saved.width) == 'number' and saved.width > 0 then any_width = saved.width end
local size = type(saved.size) == 'number' and saved.size > 0 and saved.size or nil
-- and the folds and time format every panel shows
local view_state = type(saved.ui) == 'table' and saved.ui or json.object()
if saved.instance_id ~= instance then saved = {} end
local panels = saved.panels or {}  -- bid -> {session_id, window_id}
local hidden = saved.hidden or {}  -- 'sid/wid' -> true
local seen = saved.seen or {}      -- bid -> time the user last focused or prompted it
local finished = saved.finished or {} -- bid -> {pid, at}

local function now() return os.time() end
local function key(sid, wid) return sid .. '/' .. wid end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function in_scope(label)
  return not only or (label or ''):sub(1, #only) == only
end

local function project(cwd)
  if not projects[cwd] then projects[cwd] = core.project(cwd, core.read, cfg.home) end
  return projects[cwd]
end

local function display(a)
  if a.cat == 'needs' or a.cat == 'running' then return a.cat end
  if a.finished and (seen[a.block_id] or 0) < a.finished then return 'unread' end
  return 'resting'
end

local function restate(a, t)
  local d = display(a)
  if d ~= a.state then a.state = d; a.changed = t or now() end
end

local function active(cat) return cat == 'running' or cat == 'needs' end

-- record is the agent's root program status, nil when it has none
local function apply(a, record, initial)
  local cat = core.category(record and record.state, a.provider)
  a.status_title = record and record.title or nil
  if cat ~= a.cat or not a.since then
    local t = initial and core.timestamp(record and record.updated_at) or now()
    if active(a.cat) and not active(cat) then
      a.finished = t
      finished[a.block_id] = {pid = a.pid, at = t}
    end
    -- a change in the block the user is in, like a prompt sent, is them using it
    if current == a.block_id and not initial then seen[a.block_id] = t end
    a.cat, a.since = cat, t
  end
  restate(a, initial and a.since or nil)
end

local function forget_agent(bid)
  agents[bid] = nil
  finished[bid] = nil
end

-- rex's lua runs programs only through rex.exec
local function run(argv)
  local ok, r = pcall(rex.exec, argv)
  if not ok or type(r) ~= 'table' then return '', -1 end
  return r.stdout or '', r.code
end

-- branch and changes of every folder agents work in, kept fresh on a timer
local git_bin = core.find_git()
local git = {}  -- dir -> {branch, ahead, behind, changed}

local function refresh_git()
  if not git_bin then return end
  local dirs, fresh = {}, {}
  for _, a in pairs(agents) do
    if a.root ~= '' then dirs[a.root] = true end
    if a.cwd ~= '' then dirs[a.cwd] = true end
  end
  for dir in pairs(dirs) do
    local out, code = run({git_bin, '--no-optional-locks', '-C', dir, 'status', '--porcelain=v2', '--branch'})
    fresh[dir] = code == 0 and core.git_status(out) or nil
  end
  git = fresh
end

local function identify(sid, bid, info)
  info = info or term('process', sid, bid)
  local provider, proc = core.agent(info, providers)
  if not provider then provider, proc = core.behind_login(info, providers, run) end
  return provider, proc
end

local function probe(sid, bid, info)
  if panels[bid] then return end
  local provider, proc = identify(sid, bid, info)
  local a = agents[bid]
  if not provider then
    if a then forget_agent(bid) end
    return
  end
  if a and a.pid == proc.pid and a.provider == provider then
    if proc.cwd and proc.cwd ~= '' then a.cwd = proc.cwd; a.root = project(proc.cwd) end
    return
  end
  a = {block_id = bid, session_id = sid, provider = provider, pid = proc.pid, via = proc.via, path = proc.path or '',
    generation = generation[bid] or 0, cwd = proc.cwd or '', detected = now()}
  a.root = project(a.cwd)
  local f = finished[bid]
  if f and f.pid == a.pid then a.finished = f.at else finished[bid] = nil end
  local status = term('program_status', sid, bid)
  apply(a, core.status(status and status.records, proc, provider), true)
  -- starting an agent is using it; one found already running keeps its last use
  if not taking_stock then a.started = now() end
  local title = term('title', sid, bid)
  if title and type(title.owner) == 'table' and (title.owner.pid == a.pid or title.owner.pid == a.via) then
    a.term_title = title.title
  end
  agents[bid] = a
end

local function mark_seen(bid)
  current = bid
  seen[bid] = now()
  local a = agents[bid]
  if a then current_agent = bid; restate(a) end
end

local function rect_width(layer, bid)
  for _, leaf in ipairs(core.leaves(layer.layout)) do
    if leaf.block_id == bid then return leaf.rect and leaf.rect[3] end
  end
end

-- median width from the window's blocks, else its session's other windows
local function own_width(w)
  local layer = core.tiled(w)
  if not layer then return nil end
  local found = {}
  for _, leaf in ipairs(core.leaves(layer.layout)) do
    local b = blocks[leaf.block_id]
    local c = core.window_columns(columns[leaf.block_id], b and b.width)
    if c then found[#found + 1] = c end
  end
  table.sort(found)
  return found[math.floor((#found + 1) / 2)]
end

local function measure(sid)
  local s = sessions[sid]
  for _, w in pairs(s and s.windows or {}) do
    local c = own_width(w)
    if c then widths[sid] = c; any_width = c; return end
  end
end

local function window_width(sid, w)
  return own_width(w) or widths[sid] or any_width
end

local function panel_in(sid, wid)
  for bid, p in pairs(panels) do
    if p.session_id == sid and p.window_id == wid then return bid end
  end
end

local place, straighten, refresh_session, hold, quiet, settle

-- hold the panel border once seconds pass without another call
local function hold_later(sid, wid, h, field, seconds)
  if h[field] then h[field]:cancel() end
  h[field] = rex.after(seconds, function()
    h[field] = nil
    if stopping then return end
    local ok, err = pcall(hold, sid, wid, true)
    if not ok then log('hold: ' .. tostring(err)) end
    settle()
  end)
end

local function ensure(sid, wid, explicit)
  local ok, why = place(sid, wid, explicit)
  local k = key(sid, wid)
  if not ok and why and failed[k] ~= why then log('no panel in ' .. wid .. ': ' .. why) end
  failed[k] = not ok and why or nil
  return ok, why
end

place = function(sid, wid, explicit)
  local s = sessions[sid]
  local w = s and s.windows[wid]
  if not w then return nil, 'window no longer exists' end
  if panel_in(sid, wid) then return true end
  if hidden[key(sid, wid)] and not explicit then return nil end
  if #apps == 0 then return nil, 'no rex app is connected' end
  if w.zoomed_block_id then return nil, 'unzoom the window first' end
  local layer = core.tiled(w)
  if not layer then return nil, 'window has no tiled layout' end
  local width = window_width(sid, w)
  if not width then return nil, 'window size unknown; show the window first' end
  if width < core.min_columns then return nil, 'window is narrower than ' .. core.min_columns .. ' columns' end
  local first = core.leaves(layer.layout)[1]
  local ok, bid = pcall(core.place, call, sid, first.block_id, width, cfg, size)
  if not ok then return nil, tostring(bid) end
  panels[bid] = {session_id = sid, window_id = wid}
  blocks[bid] = {session_id = sid, window_id = wid, label = core.panel_label}
  user_closed = false
  log('panel ' .. bid .. ' in ' .. wid)
  quiet(sid, wid, 3)
  straighten(sid, wid)
  return true
end

local function window_in(view, wid)
  for _, w in ipairs(view and view.windows or {}) do
    if w.window_id == wid then return w end
  end
end

local function placed(sid)
  local set = {}
  local view = try('session.view', {session_id = sid})
  for _, w in ipairs(view and view.windows or {}) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do set[b.block_id] = true end
    end
  end
  return set
end

-- for a while, any border move is the app's and the panel's width is put back
quiet = function(sid, wid, seconds)
  local h = held[key(sid, wid)] or {}
  held[key(sid, wid)] = h
  local till = os.time() + seconds
  if h.timer and h.till >= till then return end
  h.till = till
  hold_later(sid, wid, h, 'timer', seconds)
end

-- keep the panel's width in columns. border moves outside the app's own layout
-- passes are the user dragging, and set the panel width
hold = function(sid, wid, settled)
  local bid = panel_in(sid, wid)
  if not bid then return end
  local k = key(sid, wid)
  local w = window_in(try('session.view', {session_id = sid}), wid)
  local layer = w and not w.zoomed_block_id and core.tiled(w)
  local root = layer and layer.layout.split
  if not root or root.direction ~= 'horizontal' or root.before.block_id ~= bid then return end
  local h = held[k] or {}
  held[k] = h
  -- a column or two of rounding is no reason to move the border
  local measured = settled and not h.timer and own_width(w)
  if measured then
    h.measured = true
    if not h.width or math.abs(measured - h.width) >= 3 then h.width = measured end
  end
  h.width = h.width or window_width(sid, w)
  local ids = {}
  for _, leaf in ipairs(core.leaves(layer.layout)) do ids[#ids + 1] = leaf.block_id end
  ids = table.concat(ids, ' ')
  if ids ~= h.leaves then
    if h.leaves then quiet(sid, wid, 1) end
    h.leaves = ids
  elseif h.ratio and not h.timer and math.abs(root.ratio - h.ratio) > 0.001 then
    h.ratio = root.ratio
    local dragged = h.width and math.floor(root.ratio * h.width + 0.5)
    if dragged and dragged ~= size then
      size = dragged
      -- one width for every panel: the others follow the one dragged
      for _, p in pairs(panels) do
        if key(p.session_id, p.window_id) ~= k then hold(p.session_id, p.window_id) end
      end
    end
    return
  end
  if not h.width then return end
  h.ratio = core.panel_ratio(h.width, size)
  if math.abs(root.ratio - h.ratio) * h.width > 0.5 then
    try('session.resize_pane', {session_id = sid, direction = 'horizontal', before_block_id = bid,
      after_block_id = core.leaves(root.after)[1].block_id, ratio = h.ratio})
  else
    h.ratio = root.ratio
  end
end

local straightening = false
-- keep the panel full height by moving the other blocks beside it
straighten = function(sid, wid)
  local bid = panel_in(sid, wid)
  if not bid or straightening then return end
  local view = try('session.view', {session_id = sid})
  local w = window_in(view, wid)
  if not w or w.zoomed_block_id then return end
  local layer = core.tiled(w)
  if not layer or core.full_height(layer.layout, bid) then return end
  local rest = core.without(layer.layout, bid)
  if not rest then return end
  local width = window_width(sid, w)
  local ratio = width and core.panel_ratio(width, size) or 0.2
  local leaves = core.leaves(rest)
  straightening = true
  local ok, err = pcall(function()
    for _, leaf in ipairs(leaves) do call('session.detach_block', {session_id = sid, block_id = leaf.block_id}) end
    for _, step in ipairs(core.rebuild_steps(rest, bid, ratio)) do
      step.session_id = sid
      call('session.move_block', step)
    end
  end)
  if not ok then
    -- never leave a block hidden: put anything still detached back beside the panel
    local set = placed(sid)
    for _, leaf in ipairs(leaves) do
      if not set[leaf.block_id] then
        try('session.move_block', {session_id = sid, block_id = leaf.block_id, anchor_block_id = bid,
          direction = 'vertical', side = 'after'})
      end
    end
    log('panel ' .. bid .. ' could not be made full height: ' .. tostring(err))
  end
  local moved = window_in(try('session.view', {session_id = sid}), wid)
  if ok then quiet(sid, wid, 1) end
  if moved and w.focused_block_id and moved.focused_block_id ~= w.focused_block_id then
    try('session.focus_block', {session_id = sid, block_id = w.focused_block_id})
    if view.active_window_id ~= wid then
      try('session.focus_window', {session_id = sid, window_id = view.active_window_id})
    end
  end
  straightening = false
  refresh_session(sid)
  if ok then log('panel ' .. bid .. ' made full height in ' .. wid) end
end

-- per window state of a session, for the windows not in live (all when nil)
local function forget_windows(sid, live)
  for _, t in ipairs({hidden, held}) do
    for k, v in pairs(t) do
      local wid = k:sub(1, #sid + 1) == sid .. '/' and k:sub(#sid + 2)
      if wid and not (live and live[wid]) then
        if t == held and v.timer then v.timer:cancel() end
        if t == held and v.measuring then v.measuring:cancel() end
        t[k] = nil
      end
    end
  end
end

local function drop_session(sid)
  sessions[sid] = nil
  attached[sid] = nil
  focus_of[sid] = nil
  widths[sid] = nil
  for bid, b in pairs(blocks) do
    if b.session_id == sid then blocks[bid] = nil; forget_agent(bid) end
  end
  for bid, p in pairs(panels) do if p.session_id == sid then panels[bid] = nil end end
  forget_windows(sid)
end

-- with later set, new blocks are returned to probe after panels are placed
refresh_session = function(sid, initial, later)
  if not attached[sid] then attached[sid] = try('session.attach', {session_id = sid}) ~= nil end
  local view = try('session.view', {session_id = sid})
  if not view or not in_scope(view.label) then drop_session(sid); return end
  local s = {label = view.label, windows = {}}
  local live, fresh = {}, {}
  for _, w in ipairs(view.windows or {}) do
    s.windows[w.window_id] = w
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        live[b.block_id] = true
        if not blocks[b.block_id] and b.creator_name == core.terminal then fresh[#fresh + 1] = b.block_id end
        local width = layer.layout and rect_width(layer, b.block_id)
        -- columns from before a layout change no longer match the block's share
        if blocks[b.block_id] and blocks[b.block_id].width ~= width then columns[b.block_id] = nil end
        blocks[b.block_id] = {session_id = sid, window_id = w.window_id, label = b.label,
          terminal = b.creator_name == core.terminal, width = width}
      end
    end
  end
  sessions[sid] = s
  for bid, b in pairs(blocks) do
    if b.session_id == sid and not live[bid] then
      blocks[bid] = nil
      columns[bid] = nil
      forget_agent(bid)
      local p = panels[bid]
      if p then
        panels[bid] = nil
        if s.windows[p.window_id] and not closing[bid] then
          hidden[key(sid, p.window_id)] = true
          user_closed = true
        end
        closing[bid] = nil
      end
    end
  end
  forget_windows(sid, s.windows)
  if not later then
    for _, bid in ipairs(fresh) do probe(sid, bid) end
  end
  local active = s.windows[view.active_window_id]
  local focused = active and active.focused_block_id
  if focused and focused ~= focus_of[sid] then
    focus_of[sid] = focused
    if not initial then mark_seen(focused) end
  end
  return fresh
end

local function refresh_apps()
  apps = core.app_clients(call)
end

local function ensure_session(sid)
  local s = sessions[sid]
  if not s then return end
  measure(sid)
  for wid in pairs(s.windows) do ensure(sid, wid) end
end

local function ensure_all()
  for sid in pairs(sessions) do ensure_session(sid) end
end

local function inventory()
  taking_stock = true
  refresh_apps()
  local live = {}
  for _, s in ipairs(call('session.list').sessions or {}) do
    live[s.session_id] = true
    refresh_session(s.session_id, true)
  end
  for sid in pairs(sessions) do if not live[sid] then drop_session(sid) end end
  for bid, b in pairs(blocks) do
    if b.terminal and not panels[bid] and not columns[bid] then
      local size = term('size', b.session_id, bid)
      columns[bid] = core.block_columns(size, core.app_set(apps))
    end
  end
  for bid in pairs(panels) do if not blocks[bid] then panels[bid] = nil end end
  for bid in pairs(seen) do if not blocks[bid] then seen[bid] = nil end end
  for bid in pairs(finished) do if not agents[bid] then finished[bid] = nil end end
  taking_stock = false
end

-- publishing
local last_model, last_saved = '', ''

local function token(a)
  return table.concat({instance, a.session_id, a.block_id, tostring(a.pid), tostring(a.generation)}, '|')
end

-- last time the user focused, prompted or started the agent; else its last change
local function interacted(a)
  local t = math.max(seen[a.block_id] or 0, a.started or 0)
  return t > 0 and t or a.since
end

local function projects_git()
  local out = {}
  for _, a in pairs(agents) do
    local g = git[a.root]
    if g then out[a.root] = {branch = core.clean(g.branch), ahead = g.ahead, behind = g.behind, changed = g.changed} end
  end
  return out
end

local function publish(extra)
  local list = {}
  for bid, a in pairs(agents) do
    local b = blocks[bid]
    local s = sessions[a.session_id]
    if b and s then
      list[#list + 1] = {token = token(a), session_id = a.session_id, window_id = b.window_id, block_id = bid,
        provider = a.provider.name, title = core.title(a, b.label), state = a.state,
        interacted = interacted(a),
        changed = a.changed, root = a.root, cwd = a.cwd, session = core.clean(s.label),
        branch = git[a.cwd] and core.clean(git[a.cwd].branch)}
    end
  end
  table.sort(list, function(x, y) return x.token < y.token end)
  local clients = {}
  for _, c in ipairs(apps) do clients[#clients + 1] = {id = c.client_id, label = core.clean((c.info or {}).label or c.client_id)} end
  local model = {version = 1, connected = true, instance_id = instance, collector = {client_id = me, pid = pid},
    clients = clients, agents = list, panels = count(panels), ui = view_state, git = json.object(projects_git()),
    current = agents[current_agent] and token(agents[current_agent]) or nil}
  for k, v in pairs(extra or {}) do model[k] = v end
  local encoded = json.encode(model)
  if encoded ~= last_model then
    last_model = encoded
    write('model.json', model)
  end
  local keep = {version = 1, instance_id = instance, width = any_width, size = size, ui = view_state, panels = json.object(panels),
    hidden = json.object(hidden), seen = json.object(seen), finished = json.object(finished)}
  encoded = json.encode(keep)
  if encoded ~= last_saved then
    last_saved = encoded
    write('collector.json', keep)
  end
end

local function stop(message, off)
  stopping = true
  publish({connected = false, agents = {}, message = message})
  if off then put('off', 'closed ' .. os.date('!%Y-%m-%dT%H:%M:%SZ') .. '\n') end
  os.remove(state .. '/collector.pid')
  log('stopped: ' .. message)
  rex.stop(0)
end

-- panels that vanish with their window or session keep the collector running
settle = function()
  if stopping then return end
  if count(panels) == 0 and user_closed then return stop('agent panel closed', true) end
  publish()
end

-- requests from views and config actions
local function window_of(req)
  local sid = req.session_id
  if not sid then return nil, nil, 'open a rex session first' end
  if not sessions[sid] then refresh_session(sid) end
  local s = sessions[sid]
  if not s then return nil, nil, 'session not found' end
  local b = req.block_id and blocks[req.block_id]
  if b and b.session_id == sid then return sid, b.window_id end
  if req.window_id and s.windows[req.window_id] then return sid, req.window_id end
  local view = try('session.view', {session_id = sid})
  local w = view and core.find_window(view, req.block_id)
  if w then return sid, w.window_id end
  return nil, nil, 'window no longer exists'
end

local function pick_app(wanted)
  refresh_apps()
  if #apps == 0 then return nil, 'no rex app is connected' end
  for _, c in ipairs(apps) do if c.client_id == wanted then return c end end
  if #apps == 1 then return apps[1] end
  return nil, 'several rex apps are connected; press tab to pick one'
end

local handlers = {}

function handlers.register(req)
  local sid, bid = req.session_id, req.block_id
  if not sid or not bid then return nil, 'missing panel block' end
  refresh_session(sid)
  local b = blocks[bid]
  if not b or b.session_id ~= sid then return nil, 'panel block not found' end
  for other, p in pairs(panels) do
    if other ~= bid and p.session_id == sid and p.window_id == b.window_id then
      closing[bid] = true
      try('block.close', {session_id = sid, block_id = bid})
      return nil, 'this window already has an agent panel'
    end
  end
  panels[bid] = {session_id = sid, window_id = b.window_id}
  hidden[key(sid, b.window_id)] = nil
  user_closed = false
  os.remove(state .. '/off')
  forget_agent(bid)
  return {ok = true}
end

-- folds and time format, the same in every panel
function handlers.ui(req)
  local collapsed = {}
  for root, v in pairs(type(req.collapsed) == 'table' and req.collapsed or {}) do
    if type(root) == 'string' and v == true then collapsed[root] = true end
  end
  local folded = {}
  for state, v in pairs(type(req.folded) == 'table' and req.folded or {}) do
    if type(state) == 'string' and v == true then folded[state] = true end
  end
  view_state = {collapsed = json.object(collapsed), folded = json.object(folded), exact = req.exact == true}
  return {ok = true}
end

function handlers.focus(req)
  local a
  for _, x in pairs(agents) do if token(x) == req.token then a = x end end
  if not a then return nil, 'agent exited or was replaced' end
  if call('server.status').instance_id ~= instance then return nil, 'rex restarted' end
  local provider, proc = identify(a.session_id, a.block_id)
  if provider ~= a.provider or not proc or proc.pid ~= a.pid then
    probe(a.session_id, a.block_id)
    return nil, 'agent exited or was replaced'
  end
  local app, err = pick_app(req.client)
  if not app then return nil, err end
  local b = blocks[a.block_id]
  call('client.perform', {client_id = app.client_id, action = 'session.select',
    args = {session_id = a.session_id, window_id = b.window_id}, timeout_ms = 5000})
  call('session.focus_block', {session_id = a.session_id, block_id = a.block_id})
  focus_of[a.session_id] = a.block_id
  mark_seen(a.block_id)
  return {ok = true}
end

function handlers.show(req)
  local sid, wid, err = window_of(req)
  if not sid then return nil, err end
  hidden[key(sid, wid)] = nil
  os.remove(state .. '/off')
  local ok, why = ensure(sid, wid, true)
  if not ok then return nil, why end
  return {ok = true}
end

function handlers.hide(req)
  local sid, wid, err = window_of(req)
  if not sid then return nil, err end
  hidden[key(sid, wid)] = true
  local bid = panel_in(sid, wid)
  if bid then
    panels[bid] = nil
    closing[bid] = true
    user_closed = true
    try('block.close', {session_id = sid, block_id = bid})
  end
  return {ok = true}
end

function handlers.repair(req)
  agents, blocks, sessions, projects = {}, {}, {}, {}
  inventory()
  local seen_windows = {}
  for bid, p in pairs(panels) do
    local k = key(p.session_id, p.window_id)
    if seen_windows[k] then
      panels[bid] = nil
      closing[bid] = true
      try('block.close', {session_id = p.session_id, block_id = bid})
    end
    seen_windows[k] = true
  end
  if req.session_id then
    local sid, wid = window_of(req)
    if sid then hidden[key(sid, wid)] = nil end
  end
  ensure_all()
  for _, p in pairs(panels) do hold(p.session_id, p.window_id) end
  return {ok = true, panels = count(panels), agents = count(agents)}
end

function handlers.quit()
  for bid, p in pairs(panels) do
    closing[bid] = true
    try('block.close', {session_id = p.session_id, block_id = bid})
  end
  panels = {}
  user_closed = true
  return {ok = true}
end

-- events
local function on(name, fn)
  rex.on(name, function(ctx, ev)
    if stopping then return end
    local ok, err = pcall(fn, ctx or {}, ev or {})
    if not ok then log(name .. ': ' .. tostring(err)) end
    settle()
  end)
end

local function session_changed(ctx, ev)
  ev = ev or {}
  -- session_created carries its session in the event, not the context
  if not ctx.session_id and type(ev.session) == 'table' then ctx = {session_id = ev.session.session_id} end
  if not ctx.session_id or straightening then return end
  local fresh = refresh_session(ctx.session_id, false, true)
  ensure_session(ctx.session_id)
  for _, p in pairs(panels) do
    if p.session_id == ctx.session_id then
      straighten(p.session_id, p.window_id)
      hold(p.session_id, p.window_id)
    end
  end
  for _, bid in ipairs(fresh or {}) do
    local b = blocks[bid]
    if b and b.session_id == ctx.session_id then probe(ctx.session_id, bid) end
  end
end

for _, name in ipairs({'session_created', 'window_created', 'window_closed',
    'session_view_changed', 'block_created', 'block_closed', 'session_label_changed'}) do
  on(name, session_changed)
end

-- the app lays out the window it switches to
on('active_window_changed', function(ctx, ev)
  for _, p in pairs(panels) do
    if p.session_id == ctx.session_id then quiet(p.session_id, p.window_id, 1) end
  end
  session_changed(ctx, ev)
end)

on('session_destroyed', function(ctx, ev)
  drop_session(ctx.session_id or ev.session_id or (type(ev.session) == 'table' and ev.session.session_id))
end)

on('terminal.process_changed', function(ctx, ev)
  local sid, bid = ctx.session_id, ctx.block_id
  if not blocks[bid] then return session_changed(ctx) end
  generation[bid] = ev.generation or generation[bid]
  probe(sid, bid, ev.foreground and {foreground = ev.foreground, ancestors = ev.ancestors, child = ev.child} or nil)
end)

on('terminal.child_exited', function(ctx) probe(ctx.session_id, ctx.block_id) end)

on('terminal.program_status_changed', function(ctx, ev)
  local a = agents[ctx.block_id]
  if not a then return end
  local record = ev.record
  if (ev.id == nil or ev.id == '') and record and core.status({record}, a, a.provider) then apply(a, record) end
end)

on('terminal.program_status_removed', function(ctx, ev)
  local a = agents[ctx.block_id]
  if not a then return end
  for _, id in ipairs(ev.ids or {}) do if id == '' then apply(a, nil) end end
end)

on('terminal.title_changed', function(ctx, ev)
  local a = agents[ctx.block_id]
  if a and type(ev.owner) == 'table' and (ev.owner.pid == a.pid or ev.owner.pid == a.via) then a.term_title = ev.title end
end)

on('terminal.size_changed', function(ctx, ev)
  local b = blocks[ctx.block_id]
  if not b or panels[ctx.block_id] then return end
  if columns[ctx.block_id] == ev.columns then return end
  columns[ctx.block_id] = ev.columns
  local sid, wid = b.session_id, b.window_id
  if not panel_in(sid, wid) then return ensure_session(sid) end
  -- sizes after the app's first layout can mean a resize
  local h = held[key(sid, wid)] or {}
  held[key(sid, wid)] = h
  if not h.measured then quiet(sid, wid, 1) end
  hold_later(sid, wid, h, 'measuring', 0.5)
end)

local function app_event(ev)
  local c = ev.client or {}
  if (c.info or {}).kind == 'app' then return true end
  for _, a in ipairs(apps) do if a.client_id == (ev.client_id or c.client_id) then return true end end
  return false
end
for _, name in ipairs({'client_joined', 'client_left', 'client_changed'}) do
  rex.on(name, function(_, ev)
    if stopping or not app_event(ev or {}) then return end
    local ok, err = pcall(function() refresh_apps(); ensure_all() end)
    if not ok then log(name .. ': ' .. tostring(err)) end
    settle()
  end)
end

rex.on('client_perform_requested', function(_, ev)
  ev = ev or {}
  local handler = handlers[ev.action or '']
  local ok, result, err
  if handler then
    ok, result, err = pcall(handler, ev.args or {})
    if not ok then result, err = nil, tostring(result) end
  else
    err = 'unknown request ' .. tostring(ev.action)
  end
  if result then
    try('client.reply', {call_id = ev.call_id, result = result})
  else
    try('client.reply', {call_id = ev.call_id, error = {code = handler and 'refused' or 'not_supported', message = err or 'failed'}})
  end
  settle()
end)

-- start
inventory()
local host = args.host
if host and host.session_id and host.block_id then
  local ok, err = handlers.register(host)
  if not ok then log('panel ' .. host.block_id .. ': ' .. tostring(err)) end
elseif core.read(state .. '/off') then
  return stop('agent panel is off')
end
for sid in pairs(sessions) do measure(sid) end
ensure_all()
for _, p in pairs(panels) do hold(p.session_id, p.window_id) end
local function git_tick()
  if stopping then return end
  local ok, err = pcall(refresh_git)
  if not ok then log('git: ' .. tostring(err)) end
  settle()
  rex.after(3, git_tick)
end
git_tick()
log('collector ' .. tostring(me) .. ' serving ' .. count(panels) .. ' panels, ' .. count(agents) .. ' agents')
