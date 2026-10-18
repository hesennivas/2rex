#!/bin/sh
# install, update or remove the 2rex agent panel
#   ./install.sh [install | uninstall | status | 2rex ARGS...]
#   curl -fsSL https://raw.githubusercontent.com/hesennivas/2rex/develop/install.sh | sh
set -eu

# piped from curl there are no sibling files, so fetch the repo and run its copy
if ! [ -f "$0" ] || ! [ -d "$(dirname "$0")/agents" ]; then
  url=${TWOREX_TARBALL:-https://github.com/hesennivas/2rex/archive/refs/heads/develop.tar.gz}
  home=${XDG_DATA_HOME:-$HOME/.local/share}/2rex
  mkdir -p "$(dirname "$home")"
  rm -rf "$home.new"
  mkdir "$home.new"
  curl -fsSL "$url" | tar -xz -C "$home.new" --strip-components=1
  rm -rf "$home"
  mv "$home.new" "$home"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$home/2rex" "$HOME/.local/bin/2rex"
  exec sh "$home/install.sh" "$@"
fi

marker='-- rex agent panel'
label='rex-agents-collector'
src=$(cd "$(dirname "$0")" && pwd)/agents

if [ -n "${REX_CONFIG:-}" ]; then
  config=$REX_CONFIG
else
  config=${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua
fi
dest=$(dirname "$config")/agents
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex/agents

# rex terminals put the server's own cli on PATH; else the newest server the app installed
find_rex() {
  if [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ]; then echo "$REX_BIN_DIR/rex"; return; fi
  command -v rex && return
  versions="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions"
  newest=$(ls -1 "$versions" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n 1 || true)
  for p in "$versions/${newest:-none}/Rex Server.app/Contents/MacOS/rex" \
    '/Applications/Rex Beta.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex' \
    '/Applications/Rex.app/Contents/Helpers/Rex Server.app/Contents/MacOS/rex'; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  return 0
}
rex=$(find_rex)

# talk to a running server only; never start one
rex_cmd() { [ -n "$rex" ] && "$rex" --autostart=false --timeout=5s --color=never "$@" >/dev/null 2>&1; }

# exit 4 means no server; 1 means the config has errors, which rex prints
reload() {
  [ -n "$rex" ] || return 0
  status=0
  out=$("$rex" --autostart=false --timeout=5s --color=never config reload 2>&1) || status=$?
  case $status in
    0) ;;
    4) echo "rex is not running; $1" ;;
    *) printf '%s\n' "$out" | grep -v '^generation:' >&2 ;;
  esac
  return $status
}

# rex config check runs the file locally; without REX_SERVER the panel's
# init.lua skips starting a collector
check() { env -u REX_SERVER "$rex" --autostart=false --color=never config check "$1" 2>&1; }

# refuse a config the change would break; one that was already broken is the user's
check_draft() {
  [ -n "$rex" ] || return 0
  out=$(check "$config.tmp") && return 0
  if [ -f "$config" ] && ! check "$config" >/dev/null; then
    echo "$config already has errors; installing anyway" >&2
    return 0
  fi
  printf '%s\n' "$out" | grep -E '^(error|warning)' >&2
  rm -f "$config.tmp"
  echo "not installed; $config is unchanged" >&2
  exit 1
}

# ask a running collector to close its panels and exit
stop_collector() {
  rex_cmd do -e "for _, c in ipairs(rex.call('client.list', {}).clients or {}) do
    if (c.info or {}).label == '$label' then
      pcall(rex.call, 'client.perform', {client_id = c.client_id, action = 'quit', args = {}})
    end
  end" || true
  # it writes its off marker on the way out, so wait for it to finish
  i=0
  while running && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

running() {
  pid=$(cat "$state/collector.pid" 2>/dev/null || true)
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -qF "$dest/collector.lua"
}

# config without the panel's line
without_line() { [ -f "$config" ] && grep -vF -- "$marker" "$config" || true; }

install() {
  command -v luajit >/dev/null 2>&1 || [ -x /opt/homebrew/bin/luajit ] || [ -x /usr/local/bin/luajit ] ||
    { echo 'luajit not found; install it with: brew install luajit' >&2; exit 1; }
  [ -d "$src" ] || { echo "missing $src" >&2; exit 1; }
  [ -n "$rex" ] || echo 'rex not found; install rex, then run this again' >&2

  stop_collector
  if [ "$src" != "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest.new"
    cp -R "$src" "$dest.new"
    rm -rf "$dest"
    mv "$dest.new" "$dest"
  fi

  # require loads agents/init.lua from beside the config
  { without_line; printf 'require("agents") %s\n' "$marker"; } > "$config.tmp"
  check_draft
  mv "$config.tmp" "$config"
  rm -f "$state/off"
  if [ -n "$rex" ] && reload 'the panel starts with it'; then
    # the server reads REX_CONFIG from its own environment, which can differ from this shell's
    "$rex" --autostart=false --timeout=5s --color=never actions 2>/dev/null | grep -q '^show_agent_panel ' ||
      echo "the running rex server did not load $config; check REX_CONFIG where rex runs" >&2
  fi
  echo "2rex agent panel installed in $dest"
}

uninstall() {
  stop_collector
  if [ -f "$config" ]; then
    without_line > "$config.tmp"
    mv "$config.tmp" "$config"
  fi
  reload 'nothing to stop' || true
  rm -rf "$dest" "$state"
  echo '2rex agent panel removed'
}

status() {
  if grep -qF -- "$marker" "$config" 2>/dev/null; then echo "enabled in $config"; else echo "not enabled in $config"; fi
  if running; then echo "collector running (pid $pid)"; else echo 'collector not running'; fi
}

case "${1:-install}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  2rex) shift; exec "$(dirname "$src")/2rex" "$@" ;;
  *) echo 'usage: ./install.sh [install | uninstall | status | 2rex ARGS...]' >&2; exit 2 ;;
esac
