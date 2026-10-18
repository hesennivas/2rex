-- luajit tests/test_agents.lua
local root = (arg[0]:match('^(.*)/[^/]+$') or '.') .. '/../agents'
local function use(name) return assert(loadfile(root .. '/lib/' .. name .. '.lua'))(root) end
local core, rows, term, providers, json = use('core'), use('rows'), use('term'), use('providers'), use('json')
require('ffi').cdef('char *setlocale(int, const char *);')
require('ffi').C.setlocale(0, 'en_US.UTF-8')

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print('fail: ' .. name .. ': ' .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error((what or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local claude, codex = providers[1], providers[2]

test('identify agents and wrappers', function()
  eq(core.identify({path = '/opt/bin/codex'}, providers), codex)
  eq(core.identify({path = '/usr/bin/node', script = '/p/node_modules/@anthropic-ai/claude-code/cli.js'}, providers), claude)
  eq(core.identify({path = '/Users/u/.local/share/claude/versions/2.1.301'}, providers), claude)
  eq(core.identify({path = '/x/-codex'}, providers), codex)
  eq(core.identify({path = '/usr/bin/node', name = 'node'}, providers), nil)
  eq(core.identify({path = '/usr/bin/python3', script = '/tmp/claude.py'}, providers), nil)
end)

test('agent found in ancestors of a tool process', function()
  local p = core.agent({foreground = {path = '/usr/bin/git', pid = 9}, ancestors = {{path = '/opt/bin/codex', pid = 3}}}, providers)
  eq(p, codex)
end)

test('agent behind login for command blocks', function()
  local info = {foreground = {pid = 10, name = 'login', path = '/usr/bin/login'}}
  local function run(cmd)
    if cmd[1] == '/bin/ps' then return '   10     1 /usr/bin/login\n   11    10 -codex\n' end
    return 'p11\nfcwd\nn/work/repo\n'
  end
  local provider, proc = core.behind_login(info, providers, run)
  eq(provider, codex)
  eq(proc.pid, 11)
  eq(proc.via, 10)
  eq(proc.cwd, '/work/repo')
  eq(core.behind_login({foreground = {pid = 5, name = 'zsh'}}, providers, run), nil)
end)

test('status record must belong to the agent', function()
  local records = {{owner = {pid = 3}, state = 'blocked', app = 'codex', title = 'approve'},
    {owner = {pid = 3}, id = 'worker', state = 'working', app = 'codex'}}
  eq(core.status(records, {pid = 3}, codex), records[1])
  eq(core.status(records, {pid = 4}, codex), nil)
  eq(core.status(records, {pid = 4, via = 3}, codex), records[1])
  eq(core.status({{owner = {pid = 3}, state = 'working', app = 'claude-code'}}, {pid = 3}, codex), nil)
  eq(core.category('blocked'), 'needs')
  eq(core.category('error'), 'needs')
  eq(core.category('working'), 'running')
  eq(core.category('idle'), 'idle')
  eq(core.category('done'), 'idle')
end)

test('title fallbacks', function()
  eq(core.title({provider = claude, status_title = '✳ fix parser'}, 'shell'), 'fix parser')
  eq(core.title({provider = claude, status_title = 'claude'}, 'api work'), 'api work')
  eq(core.title({provider = claude, term_title = 'Claude Code'}, 'zsh'), 'claude')
  eq(core.title({provider = claude, term_title = 'review pr'}, 'zsh'), 'review pr')
  eq(core.title({provider = claude, term_title = '✳ review pr'}, 'Block df168c01'), 'review pr')
  eq(core.title({provider = codex}, 'bad\27[31m'), 'bad [31m')
end)

test('project root joins worktrees and subfolders', function()
  local fs = {['/w/repo/.git'] = '', ['/w/repo-wt/.git'] = 'gitdir: /w/repo/.git/worktrees/repo-wt\n'}
  local read = function(p) return fs[p] end
  eq(core.project('/w/repo/src/a', read, '/home'), '/w/repo')
  eq(core.project('/w/repo-wt/x', read, '/home'), '/w/repo')
  eq(core.project('/w/plain/', read, '/home'), '/w/plain')
  eq(core.project('/home/u', function() return nil end, '/home/u'), '/home/u')
end)

test('times and sizes', function()
  eq(core.timestamp('1970-01-01T00:01:00Z'), 60)
  eq(core.timestamp('2026-10-18T01:00:00+05:30'), core.timestamp('2026-10-17T19:30:00Z'))
  local t = os.time({year = 2026, month = 10, day = 17, hour = 9, min = 5})
  eq(core.clock(t, t + 3600), '09:05'); eq(core.clock(t, t + 86400), 'oct 17')
  eq(core.ago(5), '5s'); eq(core.ago(125), '2m'); eq(core.ago(7300), '2h'); eq(core.ago(200000), '2d')
  eq(core.block_columns({desired = {{columns = 120}, {columns = 80}}}), 120)
  eq(core.block_columns({desired = {}, owner = 'c1', columns = 90}, {c1 = true}), 90)
  eq(core.block_columns({desired = {}, owner = nil, columns = 80}, {}), nil)
  eq(core.window_columns(100, 0.5), 200)
end)

test('panel needs a wide enough window', function()
  eq(core.min_columns, 90)
  local layout = core.panel_layout({luajit = '/l', root = '/r', state = '/s', home = '/h'})
  eq(layout.block.label, 'agents')
  eq(layout.block.options.command[2], '/r/view.lua')
end)

test('panel keeps its columns at any window width', function()
  eq(core.panel_ratio(200), 0.17)
  eq(core.panel_ratio(90), 0.36)
  eq(core.panel_ratio(200, 50), 0.25)
  eq(core.panel_ratio(100, 95), 0.9)
end)

test('full height rebuild keeps the tree', function()
  local function leaf(b) return {block_id = b} end
  local function split(d, r, a, b) return {split = {direction = d, ratio = r, before = a, after = b}} end
  eq(core.full_height(split('horizontal', 0.2, leaf('P'), leaf('a')), 'P'), true)
  -- panel placed beside the top block of a top/bottom split
  local layout = split('vertical', 0.5, split('horizontal', 0.2, leaf('P'), leaf('a')), split('horizontal', 0.6, leaf('b'), leaf('c')))
  eq(core.full_height(layout, 'P'), false)
  local rest = core.without(layout, 'P')
  eq(rest.split.direction, 'vertical'); eq(rest.split.before.block_id, 'a'); eq(rest.split.after.split.ratio, 0.6)
  local steps = core.rebuild_steps(rest, 'P', 0.2)
  local text = {}
  for _, st in ipairs(steps) do text[#text + 1] = st.block_id .. '>' .. st.anchor_block_id .. ':' .. st.direction .. ':' .. st.ratio end
  eq(table.concat(text, ' '), 'a>P:horizontal:0.2 b>a:vertical:0.5 c>b:horizontal:0.6')
  eq(core.without(leaf('P'), 'P'), nil)
end)

local function agent(token, state, root, changed)
  return {token = token, state = state, root = root, changed = changed, title = token, provider = 'claude'}
end

local function kinds(list)
  local out = {}
  for _, r in ipairs(list) do
    out[#out + 1] = r.kind == 'section' and ('[' .. r.state .. ']') or r.kind == 'project' and r.root or r.agent.token
  end
  return table.concat(out, ' ')
end

test('a project shows once under its most urgent state', function()
  local list = {agent('a1', 'running', '/a', 5), agent('a2', 'needs', '/a', 1), agent('b1', 'running', '/b', 9),
    agent('c1', 'unread', '/c', 3), agent('d1', 'resting', '/d', 2)}
  eq(kinds(rows.build(list, {})), '[needs] /a a1 a2 [running] /b b1 [unread] /c c1 [resting] /d d1')
  eq(kinds(rows.build(list, {folded = {resting = true}})), '[needs] /a a1 a2 [running] /b b1 [unread] /c c1 [resting]')
end)

test('rows keep a fixed order, collapse, search and next needing', function()
  local list = {agent('a1', 'needs', '/a', 5), agent('b1', 'needs', '/b', 9), agent('b2', 'running', '/b', 1)}
  eq(kinds(rows.build(list, {collapsed = {['/b'] = true}})), '[needs] /a a1 /b')
  eq(kinds(rows.build(list, {query = 'a1'})), '[needs] /a a1')
  list[1].changed = 1; list[2].changed = 99
  eq(kinds(rows.build(list, {})), '[needs] /a a1 /b b1 b2')
  local n = rows.needing(list)
  eq(n[1].token, 'a1'); eq(n[2].token, 'b1'); eq(#n, 2)
end)

test('git branch and changes', function()
  local g = core.git_status('# branch.oid abcdef1234\n# branch.head main\n# branch.ab +2 -1\n1 .M N... 1 2 3 4 5 a.lua\n? b\n')
  eq(g.branch, 'main'); eq(g.ahead, 2); eq(g.behind, 1); eq(g.changed, 2)
  eq(core.git_status('# branch.oid abcdef1234\n# branch.head (detached)\n').branch, 'abcdef1')
  eq(core.git_status(''), nil)
end)

test('project heading is the folder name', function()
  eq(rows.folder('/Users/u/code/vc_revamp'), 'vc_revamp'); eq(rows.folder('/'), '/')
end)

test('unicode safe clipping', function()
  eq(term.width('界界a'), 5)
  eq(term.clip('界界a', 4), '界…')
  eq(term.clip('abc', 3), 'abc')
  eq(term.clip('héllo wörld', 6), 'héllo…')
  eq(core.clean('a\27b\7c'), 'a b c')
end)

test('adapters are declarative', function()
  for _, p in ipairs(providers) do
    assert(type(p.name) == 'string' and p.name == p.name:lower(), 'lowercase name')
    assert(type(p.bins) == 'table' and #p.bins > 0, 'bins')
    assert(type(p.apps) == 'table', 'apps')
  end
end)

test('json round trip keeps empty objects', function()
  eq(json.encode(json.object({})), '{}')
  eq(json.decode('{"a":[1,2]}').a[2], 2)
end)

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
