-- turn published agents into panel rows: state sections, project headings, agents
local M = {}

M.order = {'needs', 'running', 'unread', 'resting'}
M.titles = {needs = 'needs you', running = 'running', unread = 'unread', resting = 'resting'}
local rank = {needs = 1, running = 2, unread = 3, resting = 4}

-- a fixed order, so rows don't move as agents change: agents by the order their
-- blocks were made in (block ids grow over time), folders by name
local function older(a, b)
  if (a.block_id or '') ~= (b.block_id or '') then return (a.block_id or '') < (b.block_id or '') end
  return (a.token or '') < (b.token or '')
end

local function matches(a, query)
  if query == '' then return true end
  local hay = table.concat({a.title or '', a.provider or '', a.root or '', a.cwd or '', a.session or ''}, '\n'):lower()
  return hay:find(query:lower(), 1, true) ~= nil
end

-- ui = {collapsed = {[root] = true}, folded = {[state] = true}, query = string}
function M.build(agents, ui)
  local query = ui.query or ''
  local projects, list = {}, {}
  for _, a in ipairs(agents or {}) do
    if matches(a, query) then
      local root = a.root or ''
      local p = projects[root]
      if not p then
        p = {root = root, name = M.folder(root):lower(), agents = {}, rank = 5}
        projects[root] = p
        list[#list + 1] = p
      end
      p.agents[#p.agents + 1] = a
      p.rank = math.min(p.rank, rank[a.state] or 4)
    end
  end
  for _, p in ipairs(list) do table.sort(p.agents, older) end
  table.sort(list, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.root < b.root
  end)
  local rows = {}
  for i, state in ipairs(M.order) do
    local section, count = {}, 0
    for _, p in ipairs(list) do
      if p.rank == i then section[#section + 1] = p; count = count + #p.agents end
    end
    if #section > 0 then
      local folded = (ui.folded or {})[state] and query == '' or false
      rows[#rows + 1] = {kind = 'section', state = state, count = count, folded = folded,
        key = 's:' .. state, selectable = true}
      if not folded then
        for _, p in ipairs(section) do
          local collapsed = (ui.collapsed or {})[p.root] and query == '' or false
          rows[#rows + 1] = {kind = 'project', state = state, root = p.root, count = #p.agents,
            collapsed = collapsed, key = 'p:' .. p.root, selectable = true}
          if not collapsed then
            for _, a in ipairs(p.agents) do
              rows[#rows + 1] = {kind = 'agent', agent = a, key = 'a:' .. (a.token or ''), selectable = true}
            end
          end
        end
      end
    end
  end
  return rows
end

-- agents needing you in panel order, ignoring folds and search
function M.needing(agents)
  local rows = M.build(agents, {collapsed = {}, query = ''})
  local out = {}
  for _, r in ipairs(rows) do
    if r.kind == 'agent' and r.agent.state == 'needs' then out[#out + 1] = r.agent end
  end
  return out
end

-- a project heading is its folder's name
function M.folder(root)
  return (root or ''):match('([^/]+)/*$') or root or ''
end

return M
