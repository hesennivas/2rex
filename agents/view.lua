-- agent panel view. runs in a panel block: luajit view.lua STATE_DIR
-- draws model.json and sends every change to the collector
local root = (arg[0]:match('^(.*)/[^/]+$') or '.')
if root:sub(1, 1) ~= '/' then root = (os.getenv('PWD') or '.') .. '/' .. root end
local state = assert(arg[1], 'usage: view.lua STATE_DIR')
local function use(name) return assert(loadfile(root .. '/lib/' .. name .. '.lua'))(root) end
local json, core, rows, term = use('json'), use('core'), use('rows'), use('term')

local SID, BID = os.getenv('REX_SESSION'), os.getenv('REX_BLOCK')
local REX = core.rex_bin()
local LUAJIT = arg[-1] and arg[-1]:sub(1, 1) == '/' and arg[-1] or core.find_luajit()

local function rgb(hex, bg)
  return string.format('\27[%d;2;%d;%d;%dm', bg and 48 or 38, tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16))
end
local red, yellow, blue, grey, text = rgb('#f38ba8'), rgb('#f9e2af'), rgb('#89b4fa'), rgb('#6c7086'), rgb('#cdd6f4')
local select_bg, bold, reset = rgb('#313244', true), '\27[1m', '\27[0m'
local colors = {needs = red, running = yellow, unread = blue, resting = grey}
local icons = {needs = '●', unread = '•', resting = '○'}
local spinner = {'◐', '◓', '◑', '◒'}

local function load_json(path)
  local s = core.read(path)
  local ok, v = pcall(json.decode, s or '')
  if ok and type(v) == 'table' then return v end
end

-- folds and exact (clock times instead of ages) are shared by every panel through
-- the collector; the search is this panel's own
local ui = {collapsed = {}, folded = {}, query = '', exact = false}
local current
local typing, selected_key, offset, client_index = false, nil, 1, 1
local message, message_until = '', 0
local model, targets, last_lines = nil, {}, {}
local registered, spawned_at, last_needs = nil, 0, nil
local width, height = term.size()

local function say(s, seconds)
  message = core.clean(s)
  message_until = term.now() + (seconds or 6)
end

local function collector_alive(m)
  return m and m.connected and m.collector and term.alive(m.collector.pid)
end

-- requests go to the collector over rex's client.perform
local function request(action, payload)
  if not collector_alive(model) then return nil, 'agent panel is reconnecting' end
  local body = json.encode({client_id = model.collector.client_id, action = action, args = payload, timeout_ms = 8000})
  local out, code = term.run({REX, '--autostart=false', '--timeout=10s', '--color=never', 'api', 'call', 'client.perform', body})
  if code ~= 0 then
    local why = out:gsub('%s+$', ''):gsub('^Error:%s*', '')
    why = why:match('%(status=%d+ code=[%w_]+%)$') and why:gsub('%s*%(status=.*$', '') or why
    return nil, (why:match('.*: (.-)$') or why)
  end
  local ok, v = pcall(json.decode, out)
  return ok and v and v.result or {}
end

local function start_collector()
  if term.now() - spawned_at < 2 then return end
  local lock = term.trylock(state .. '/spawn.lock')
  if not lock then return end
  model = load_json(state .. '/model.json')
  if collector_alive(model) then term.unlock(lock); return end
  spawned_at = term.now()
  local args = json.encode(core.collector_args({root = root, state = state, luajit = LUAJIT},
    {session_id = SID, block_id = BID}))
  local pid = term.spawn_detached({REX, '--autostart=false', 'do', '--all', root .. '/collector.lua', '--args', args},
    state .. '/collector.log')
  local deadline = term.now() + 5
  repeat
    term.sleep(0.01)
    model = load_json(state .. '/model.json')
  until (model and model.collector and model.collector.pid == pid) or not term.alive(pid) or term.now() > deadline
  if model and model.collector and model.collector.pid == pid and model.connected then registered = pid end
  term.unlock(lock)
end

local function keep_collector()
  if not collector_alive(model) then start_collector() end
  if collector_alive(model) and registered ~= model.collector.pid then
    local ok, err = request('register', {session_id = SID, block_id = BID})
    if ok then registered = model.collector.pid else say(err) end
  end
end

local function clients() return (model and model.clients) or {} end
local function chosen_client()
  local cs = clients()
  if #cs == 0 then return nil end
  client_index = math.max(1, math.min(client_index, #cs))
  return cs[client_index].id
end

-- drawing
local function pad(s, n) return s .. string.rep(' ', math.max(0, n)) end

-- segs: list of {text, style}; fits them into the width
local function compose(segs, right, selected)
  local used, out = 0, {}
  local base = selected and select_bg or ''
  local rw = right and term.width(right[1]) or 0
  local room = width - (rw > 0 and rw + 1 or 0)
  for _, seg in ipairs(segs) do
    local s = term.clip(seg[1], room - used)
    if s ~= '' then
      out[#out + 1] = base .. (seg[2] or text) .. s .. reset
      used = used + term.width(s)
    end
    if used >= room then break end
  end
  if rw > 0 and width > rw then
    out[#out + 1] = base .. string.rep(' ', width - used - rw) .. (right[2] or grey) .. right[1] .. reset
    used = width
  end
  if selected then out[#out + 1] = base .. string.rep(' ', width - used) .. reset end
  return table.concat(out)
end

local function wrap(s, w)
  local lines, line = {}, ''
  for word in s:gmatch('%S+') do
    if line == '' then line = word
    elseif term.width(line) + 1 + term.width(word) <= w then line = line .. ' ' .. word
    else lines[#lines + 1] = line; line = word end
  end
  if line ~= '' then lines[#lines + 1] = line end
  return lines
end

local function agent_lines(a, now, selected)
  local icon = a.state == 'running' and spinner[math.floor(now * 4) % 4 + 1] or icons[a.state] or '○'
  local at = a.interacted or now
  local time = ui.exact and core.clock(at, now) or core.ago(now - at)
  -- a worktree on another branch than its folder names it
  local g = model.git and model.git[a.root]
  local branch = a.branch and not (g and g.branch == a.branch) and a.branch or nil
  return compose({{'      ', text}, {icon, colors[a.state]}, {' ', text}, {a.title or a.provider, text}}, {time, grey}, selected),
    compose({{'        ' .. a.provider .. (branch and ' · ' .. branch or ''), grey}}, nil, selected)
end

-- the folder, and below it its branch (*n files changed, ↑ ahead and ↓ behind
-- upstream) and how many agents it has
local function project_lines(r, selected)
  local arrow = r.collapsed and '▸ ' or '▾ '
  local segs = {{'    ', grey}}
  local g = model.git and model.git[r.root]
  if g then
    segs[#segs + 1] = {g.branch, blue}
    if (g.changed or 0) > 0 then segs[#segs + 1] = {' *' .. g.changed, yellow} end
    if (g.ahead or 0) > 0 then segs[#segs + 1] = {' ↑' .. g.ahead, grey} end
    if (g.behind or 0) > 0 then segs[#segs + 1] = {' ↓' .. g.behind, grey} end
    segs[#segs + 1] = {' · ', grey}
  end
  segs[#segs + 1] = {r.count .. (r.count == 1 and ' agent' or ' agents'), grey}
  return compose({{'  ' .. arrow, grey}, {rows.folder(r.root), bold .. text}}, nil, selected), compose(segs, nil, selected)
end

local function section_line(r, selected)
  local style = r.state == 'resting' and colors.resting or bold .. colors[r.state]
  return compose({{' ' .. rows.titles[r.state], style}, {r.folded and ' ▸' or ' ▾', grey}}, {tostring(r.count), grey}, selected)
end

local function render()
  local now = term.now()
  local lines, list = {}, {}
  targets = {}
  local connected = model and model.connected and collector_alive(model)
  -- rex's block header already names the panel
  local top = 0
  if typing or ui.query ~= '' then
    lines[1] = compose({{' / ', grey}, {ui.query, text}, {typing and '▏' or '', grey}})
    top = 2
  end
  local footer = {}
  if message ~= '' and now < message_until then
    for _, l in ipairs(wrap(message, width - 2)) do footer[#footer + 1] = compose({{' ' .. l, grey}}) end
  end
  local cs = clients()
  if #cs > 1 then
    chosen_client()
    footer[#footer + 1] = compose({{' app: ', grey}, {cs[client_index].label, text}, {'  tab', grey}})
  end
  -- key hints on as few lines as the width allows, none of them cut
  local hints, line = {'↑↓ move', '⏎ open', 'n next', '/ find', 't time', 'q hide'}, nil
  for _, h in ipairs(hints) do
    if line and term.width(line .. ' · ' .. h) <= width - 1 then line = line .. ' · ' .. h
    else
      if line then footer[#footer + 1] = compose({{' ' .. line, grey}}) end
      line = h
    end
  end
  footer[#footer + 1] = compose({{' ' .. line, grey}})
  local body_top, body_bottom = top + 1, height - #footer - 1
  local notice
  if not connected then
    notice = 'rex disconnected.'
    if now - spawned_at < 5 then notice = 'starting…'
    elseif model and model.message then notice = notice .. ' ' .. core.clean(model.message) end
  else
    list = rows.build(model.agents, ui)
    if #list == 0 then
      notice = ui.query ~= '' and 'no agents match.' or 'no agents running. start claude or codex in any rex terminal.'
    end
  end
  if notice then
    local y = body_top
    for _, l in ipairs(wrap(notice, width - 2)) do
      if y <= body_bottom then lines[y] = compose({{' ' .. l, grey}}); y = y + 1 end
    end
  end
  -- keep the selection on the same row identity
  local selectable, index = {}, nil
  for i, r in ipairs(list) do
    if r.selectable then
      selectable[#selectable + 1] = i
      if r.key == selected_key then index = #selectable end
    end
  end
  if not index and #selectable > 0 then index = 1; selected_key = list[selectable[1]].key end
  -- rows are big enough to tap with their text in the middle: a section is its
  -- heading between two padding lines, a folder its name over its branch, an
  -- agent its title over its program. a blank line before each section after the
  -- first and between the folders in one
  local placed, size, y = {}, {}, 0
  for i, r in ipairs(list) do
    if r.kind == 'section' and i > 1 then y = y + 1
    elseif r.kind == 'project' and list[i - 1].kind ~= 'section' then y = y + 1 end
    size[i] = r.kind == 'section' and 3 or 2
    placed[i] = y + 1
    y = y + size[i]
  end
  local capacity = body_bottom - body_top + 1
  local sel_row = index and selectable[index]
  if sel_row then
    local first, last = placed[sel_row], placed[sel_row] + size[sel_row] - 1
    if first < offset then offset = first end
    if last > offset + capacity - 1 then offset = last - capacity + 1 end
  end
  offset = math.max(1, math.min(offset, math.max(1, y - capacity + 1)))
  for i, r in ipairs(list) do
    local is_sel = sel_row == i
    local top = body_top + placed[i] - offset
    local drawn
    if r.kind == 'section' then drawn = {compose({}, nil, is_sel), section_line(r, is_sel), compose({}, nil, is_sel)}
    elseif r.kind == 'project' then drawn = {project_lines(r, is_sel)}
    else drawn = {agent_lines(r.agent, now, is_sel)} end
    for j, l in ipairs(drawn) do
      local sy = top + j - 1
      if sy >= body_top and sy <= body_bottom then lines[sy] = l; targets[sy] = r end
    end
  end
  for i, l in ipairs(footer) do lines[height - #footer + i] = l end
  -- one synchronized frame, so the terminal never shows a half drawn panel
  local out = {}
  for row = 1, height do
    local l = lines[row] or ''
    if l ~= last_lines[row] then out[#out + 1] = string.format('\27[%d;1H\27[2K%s', row, l) end
  end
  if #out > 0 and not last_lines[0] then table.insert(out, 1, '\27[2J') end
  last_lines = lines
  lines[0] = true
  if #out > 0 then term.write(1, '\27[?2026h' .. table.concat(out) .. '\27[?2026l') end
  return list, selectable, index
end

-- actions
local list, selectable, index = {}, {}, nil

-- take the shared folds, and highlight the agent the user is in once it changes
local function adopt(m)
  if not m then return m end
  local shared = type(m.ui) == 'table' and m.ui or {}
  ui.collapsed = type(shared.collapsed) == 'table' and shared.collapsed or {}
  ui.folded = type(shared.folded) == 'table' and shared.folded or {}
  ui.exact = shared.exact == true
  if m.current ~= current then
    current = m.current
    if current then selected_key = 'a:' .. current end
  end
  return m
end

local function share()
  local ok, err = request('ui', {collapsed = json.object(ui.collapsed), folded = json.object(ui.folded),
    exact = ui.exact})
  if not ok then say(err) end
end

local function open(a)
  local ok, err = request('focus', {token = a.token, client = chosen_client()})
  if not ok then say(err) end
end

local function activate(r)
  if not r then return end
  if r.kind == 'section' then ui.folded[r.state] = not ui.folded[r.state] or nil; share()
  elseif r.kind == 'project' then ui.collapsed[r.root] = not ui.collapsed[r.root] or nil; share()
  elseif r.kind == 'agent' then open(r.agent) end
end

local function move(delta)
  if #selectable == 0 then return end
  local i = math.max(1, math.min(#selectable, (index or 1) + delta))
  selected_key = list[selectable[i]].key
end

local function next_needing()
  local needing = rows.needing(model and model.agents or {})
  if #needing == 0 then say('no agent needs you', 3); return end
  local pick = needing[1]
  for i, a in ipairs(needing) do
    if a.token == last_needs then pick = needing[i % #needing + 1] end
  end
  last_needs = pick.token
  if ui.collapsed[pick.root] then ui.collapsed[pick.root] = nil; share() end
  selected_key = 'a:' .. pick.token
  open(pick)
end

local function hide()
  if collector_alive(model) then
    local ok, err = request('hide', {session_id = SID, block_id = BID})
    if not ok then say(err); return false end
  end
  return true
end

-- input
local pressed
local function mouse(button, y, release)
  if button == 64 then move(-1); return end
  if button == 65 then move(1); return end
  if button % 4 ~= 0 then return end
  local r = targets[y]
  if not release then
    pressed = r and r.key
    if r and r.selectable then selected_key = r.key end
  elseif r and r.key == pressed then
    pressed = nil
    activate(r)
  end
end

local running = true
local function handle(buf)
  while #buf > 0 do
    local consumed = 1
    local c = buf:sub(1, 1)
    local packet, b, _, y, ending = buf:match('^(\27%[<(%d+);(%d+);(%d+)([Mm]))')
    if packet then
      mouse(tonumber(b), tonumber(y), ending == 'm')
      consumed = #packet
    elseif buf:sub(1, 3) == '\27[<' then break
    elseif buf:sub(1, 3) == '\27[A' or buf:sub(1, 3) == '\27OA' then move(-1); consumed = 3
    elseif buf:sub(1, 3) == '\27[B' or buf:sub(1, 3) == '\27OB' then move(1); consumed = 3
    elseif buf:sub(1, 2) == '\27[' or buf:sub(1, 2) == '\27O' then
      local seq = buf:match('^\27[%[O][%d;]*[%a~]')
      if not seq then break end
      consumed = #seq
    elseif c == '\27' then
      typing, ui.query = false, ''
      message = ''
    elseif c == '\r' or c == '\n' then
      typing = false
      activate(index and list[selectable[index]])
    elseif c == '\t' then
      client_index = client_index % math.max(1, #clients()) + 1
    elseif c == '\127' or c == '\8' then
      if typing then ui.query = ui.query:gsub('[%z\1-\127\194-\244][\128-\191]*$', '') end
    elseif c == '\3' then
      if hide() then running = false end
    elseif typing then
      if c:byte() >= 32 then
        local _, nxt = term.rune(buf, 1)
        consumed = nxt - 1
        ui.query = ui.query .. buf:sub(1, consumed)
        selected_key = nil
      end
    elseif c == '/' then typing = true
    elseif c == 'n' then next_needing()
    elseif c == 't' then ui.exact = not ui.exact; share()
    elseif c == 'q' then
      if hide() then running = false end
    end
    buf = buf:sub(consumed + 1)
    list, selectable, index = render()
  end
  return buf
end

-- main loop
term.mkdir(state)
if not term.raw() then error('the agent panel needs a terminal', 0) end
local watch = term.watch(state)
-- no autowrap: a line drawn for a wider panel is cut, not wrapped, until redrawn
term.write(1, '\27[?1049h\27[?25l\27[?7l\27[?1000h\27[?1006h')
local ok, err = xpcall(function()
  model = adopt(load_json(state .. '/model.json'))
  list, selectable, index = render()
  term.write(1, '\27]0;agents\7')
  keep_collector()
  local pending, last_check = '', 0
  while running do
    local now = term.now()
    if now - last_check >= 1 then
      keep_collector()
      term.reap()
      last_check = now
    end
    local w, h = term.size()
    if w ~= width or h ~= height then width, height, last_lines = w, h, {} end
    list, selectable, index = render()
    local animating = false
    for _, r in ipairs(list) do if r.kind == 'agent' and r.agent.state == 'running' then animating = true end end
    -- a resize wakes the wait, so the panel redraws for its new size at once
    local input, changed = term.wait(watch, animating and 250 or 500)
    if input == nil then break end
    if changed then model = adopt(load_json(state .. '/model.json')) or model end
    if input ~= '' then
      pending = pending .. input
      if pending == '\27' then
        local more = term.wait(watch, 30)
        if more and more ~= '' then pending = pending .. more end
      end
      pending = handle(pending)
    end
  end
end, debug.traceback)
term.write(1, '\27[0m\27[?1000l\27[?1006l\27[?7h\27[?25h\27[?1049l')
term.restore()
if not ok then io.stderr:write(tostring(err), '\n'); os.exit(1) end
