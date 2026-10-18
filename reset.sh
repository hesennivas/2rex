#!/bin/sh
# remove every trace of the 2rex agent panel, including leftovers from older setups
#   ./reset.sh          panel config, files, state and processes
#   ./reset.sh --all    also the importer's receipts
set -eu

here=$(cd "$(dirname "$0")" && pwd)

if [ -n "${REX_CONFIG:-}" ]; then
  config=$REX_CONFIG
else
  config=${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua
fi
dest=$(dirname "$config")/agents
states=${XDG_STATE_HOME:-$HOME/.local/state}

case "${1:-}" in
  '' | --all) ;;
  *) echo 'usage: ./reset.sh [--all]' >&2; exit 2 ;;
esac

# the normal way first: close panels, drop the init.lua line, delete files
sh "$here/install.sh" uninstall

# anything still running from the panel folder, such as a collector that missed the quit
pkill -f "$dest/collector.lua" 2>/dev/null || true
pkill -f "$dest/view.lua" 2>/dev/null || true

# init.lua lines older setups wrote without the marker, and their temp files
if [ -f "$config" ]; then
  grep -vF -- "$dest/init.lua" "$config" > "$config.tmp" || true
  mv "$config.tmp" "$config"
fi
rm -f "$config.agents-tmp" "$config.tmp"
rm -rf "$dest" "$dest.new" "$states/rex/agents"
rmdir "$states/rex" 2>/dev/null || true

if [ "${1:-}" = --all ]; then
  rm -rf "$states/2rex" "$states/herdr-to-rex"
  echo 'importer receipts removed'
fi
echo '2rex reset done'
