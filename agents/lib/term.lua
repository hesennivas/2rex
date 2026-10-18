-- macos terminal and process primitives for the luajit view
local ffi = require('ffi')
local M = {}

ffi.cdef[[
typedef long ssize_t; typedef unsigned long size_t;
int open(const char *, int, ...); int close(int); int dup2(int, int);
ssize_t read(int, void *, size_t); ssize_t write(int, const void *, size_t);
int pipe(int[2]); int fork(void); int execvp(const char *, char *const[]); void _exit(int);
int waitpid(int, int *, int); int kill(int, int); int setsid(void);
int mkdir(const char *, unsigned short); int chmod(const char *, unsigned short);
int flock(int, int); int ftruncate(int, long long); long long lseek(int, long long, int);
struct timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int, struct timespec *);
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *, unsigned long, int);
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
int ioctl(int, unsigned long, ...);
struct termios { unsigned long c_iflag, c_oflag, c_cflag, c_lflag; unsigned char c_cc[20]; unsigned long c_ispeed, c_ospeed; };
int tcgetattr(int, struct termios *); int tcsetattr(int, int, const struct termios *); void cfmakeraw(struct termios *);
char *setlocale(int, const char *); int wcwidth(int);
struct kevent { unsigned long ident; short filter; unsigned short flags; unsigned int fflags; long data; void *udata; };
int kqueue(void);
int kevent(int, const struct kevent *, int, struct kevent *, int, const struct timespec *);
]]
local C = ffi.C
assert(ffi.os == 'OSX', 'the agent panel supports macos')

local O_RDONLY, O_WRONLY, O_RDWR, O_APPEND, O_CREAT = 0, 1, 2, 0x8, 0x200
local O_EVTONLY, O_CLOEXEC = 0x8000, 0x1000000

function M.now()
  local ts = ffi.new('struct timespec[1]')
  C.clock_gettime(0, ts)
  return tonumber(ts[0].tv_sec) + tonumber(ts[0].tv_nsec) / 1e9
end

function M.sleep(seconds) C.poll(nil, 0, math.floor(seconds * 1000)) end

function M.mkdir(path)
  local current = ''
  for part in path:gmatch('[^/]+') do
    current = current .. '/' .. part
    C.mkdir(current, 448)
  end
  C.chmod(path, 448)
end

function M.write(fd, s)
  local offset = 0
  while offset < #s do
    local n = tonumber(C.write(fd, ffi.cast('const char *', s) + offset, #s - offset))
    if n <= 0 then
      if ffi.errno() ~= 4 then return false end
    else offset = offset + n end
  end
  return true
end

local function argv_array(argv)
  local arr = ffi.new('char *[?]', #argv + 1)
  local keep = {}
  for i, s in ipairs(argv) do
    keep[i] = ffi.new('char[?]', #s + 1, s)
    arr[i - 1] = keep[i]
  end
  return arr, keep
end

-- run argv and return its combined output and exit code
function M.run(argv)
  local arr, keep = argv_array(argv)
  local fds = ffi.new('int[2]')
  assert(C.pipe(fds) == 0, 'pipe failed')
  local devnull = C.open('/dev/null', O_RDONLY)
  local pid = C.fork()
  if pid == 0 then
    C.dup2(devnull, 0); C.dup2(fds[1], 1); C.dup2(fds[1], 2)
    C.execvp(arr[0], arr)
    C._exit(127)
  end
  C.close(fds[1]); C.close(devnull)
  local chunks, buf = {}, ffi.new('char[8192]')
  while true do
    local n = tonumber(C.read(fds[0], buf, 8192))
    if n > 0 then chunks[#chunks + 1] = ffi.string(buf, n)
    elseif n == 0 or ffi.errno() ~= 4 then break end
  end
  C.close(fds[0])
  local status = ffi.new('int[1]')
  while C.waitpid(pid, status, 0) < 0 and ffi.errno() == 4 do end
  local s = status[0]
  local code = (s % 128 == 0) and math.floor(s / 256) % 256 or 128 + s % 128
  keep = nil
  return table.concat(chunks), code
end

-- start argv in its own session so it outlives this panel
function M.spawn_detached(argv, log)
  local arr, keep = argv_array(argv)
  local out = C.open(log, O_WRONLY + O_CREAT + O_APPEND, ffi.cast('int', 384))
  if out >= 0 and C.lseek(out, 0, 2) > 1048576 then C.ftruncate(out, 0) end
  local devnull = C.open('/dev/null', O_RDONLY)
  local pid = C.fork()
  if pid == 0 then
    C.setsid()
    C.dup2(devnull, 0)
    if out >= 0 then C.dup2(out, 1); C.dup2(out, 2) end
    C.execvp(arr[0], arr)
    C._exit(127)
  end
  C.close(devnull)
  if out >= 0 then C.close(out) end
  keep = nil
  return tonumber(pid)
end

function M.reap()
  local status = ffi.new('int[1]')
  while C.waitpid(-1, status, 1) > 0 do end
end

function M.alive(pid)
  if type(pid) ~= 'number' or pid <= 0 then return false end
  return C.kill(pid, 0) == 0 or ffi.errno() == 1
end

function M.trylock(path)
  local fd = C.open(path, O_RDWR + O_CREAT + O_CLOEXEC, ffi.cast('int', 384))
  if fd < 0 then return nil end
  if C.flock(fd, 6) ~= 0 then C.close(fd); return nil end
  return fd
end

function M.unlock(fd) if fd then C.close(fd) end end

local EVFILT_VNODE, EVFILT_SIGNAL, SIGWINCH = -4, -6, 28

-- a queue for changes in dir and for the terminal being resized
function M.watch(dir)
  local fd = C.open(dir, O_EVTONLY)
  assert(fd >= 0, 'cannot watch ' .. dir)
  local kq = C.kqueue()
  local ev = ffi.new('struct kevent[2]')
  ev[0].ident = fd; ev[0].filter = EVFILT_VNODE; ev[0].flags = 0x25; ev[0].fflags = 0x27
  ev[1].ident = SIGWINCH; ev[1].filter = EVFILT_SIGNAL; ev[1].flags = 0x1
  assert(C.kevent(kq, ev, 2, nil, 0, nil) == 0, 'cannot watch ' .. dir)
  return {fd = fd, kq = kq}
end

-- wait for input, a state change or a resize; returns typed bytes (nil at
-- end of input) and whether state changed
function M.wait(watch, ms)
  local fds = ffi.new('struct pollfd[2]')
  fds[0].fd = 0; fds[0].events = 1
  fds[1].fd = watch.kq; fds[1].events = 1
  C.poll(fds, 2, ms)
  local changed, input = false, ''
  if fds[1].revents ~= 0 then
    local evs, zero = ffi.new('struct kevent[8]'), ffi.new('struct timespec[1]')
    for i = 0, C.kevent(watch.kq, nil, 0, evs, 8, zero) - 1 do
      if evs[i].filter ~= EVFILT_SIGNAL then changed = true end
    end
  end
  if fds[0].revents ~= 0 then
    local buf = ffi.new('char[4096]')
    local n = tonumber(C.read(0, buf, 4096))
    if n > 0 then input = ffi.string(buf, n) elseif n == 0 then input = nil end
  end
  return input, changed
end

function M.size()
  local ws = ffi.new('struct winsize[1]')
  C.ioctl(1, 0x40087468, ws)
  return math.max(1, tonumber(ws[0].ws_col)), math.max(1, tonumber(ws[0].ws_row))
end

local saved
function M.raw()
  C.setlocale(0, '')
  if ffi.string(C.setlocale(2, nil)) == 'C' then C.setlocale(2, 'en_US.UTF-8') end
  saved = ffi.new('struct termios[1]')
  if C.tcgetattr(0, saved) ~= 0 then saved = nil; return false end
  local raw = ffi.new('struct termios[1]')
  ffi.copy(raw, saved, ffi.sizeof('struct termios'))
  C.cfmakeraw(raw)
  C.tcsetattr(0, 0, raw)
  return true
end

function M.restore() if saved then C.tcsetattr(0, 0, saved) end end

-- utf-8 decoding and display width
local function rune(s, i)
  local a = s:byte(i)
  if not a then return nil, i end
  if a < 128 then return a, i + 1 end
  local n = a >= 240 and 4 or a >= 224 and 3 or a >= 192 and 2 or 1
  if n == 1 then return 65533, i + 1 end
  local v = a % (2 ^ (7 - n))
  for j = 1, n - 1 do
    local b = s:byte(i + j)
    if not b or b < 128 or b >= 192 then return 65533, i + 1 end
    v = v * 64 + b - 128
  end
  return v, i + n
end
M.rune = rune

function M.cells(code)
  if code < 32 then return 0 end
  local w = C.wcwidth(code)
  if w < 0 then return 1 end
  return w
end

function M.width(s)
  local w, i = 0, 1
  while i <= #s do
    local code, nxt = rune(s, i)
    w = w + M.cells(code)
    i = nxt
  end
  return w
end

-- clip to width cells, adding an ellipsis when something was cut
function M.clip(s, width, ellipsis)
  if width <= 0 then return '' end
  if M.width(s) <= width then return s end
  local limit = ellipsis == false and width or width - 1
  local parts, used, i = {}, 0, 1
  while i <= #s do
    local code, nxt = rune(s, i)
    local n = M.cells(code)
    if used + n > limit then break end
    parts[#parts + 1] = s:sub(i, nxt - 1)
    used = used + n
    i = nxt
  end
  if ellipsis ~= false then parts[#parts + 1] = '…' end
  return table.concat(parts)
end

return M
