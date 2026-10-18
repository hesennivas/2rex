# 2rex

Move to rex from herdr, and get an agent panel that lists your claude and codex agents in every rex window.

## Requirements

- macOS with rex, and **Remote Control** on in rex settings
- `brew install luajit`
- Python 3.11+

## Agent panel

```sh
curl -fsSL https://raw.githubusercontent.com/hesennivas/2rex/develop/install.sh | sh
```

This downloads 2rex to `~/.local/share/2rex`, links the `2rex` command into `~/.local/bin` and installs the panel. Run it again to update. From a clone:

```sh
./install.sh            # install or update
./install.sh uninstall
```

The panel opens on the left of each window. If it doesn't, run **show agent panel** from the rex command palette.

## Import from herdr

```sh
2rex herdr --dry-run   # preview
2rex herdr             # import
```

Without installing the panel, or from a clone:

```sh
curl -fsSL https://raw.githubusercontent.com/hesennivas/2rex/develop/install.sh | sh -s -- 2rex herdr --dry-run
./2rex herdr --dry-run
```

See `2rex herdr --help` for more options.
