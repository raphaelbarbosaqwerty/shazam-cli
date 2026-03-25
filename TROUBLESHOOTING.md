# Troubleshooting

Common issues and solutions for installing and running Shazam.

## Installation Issues

### `env: escript: No such file or directory`

The `shazam-cli` binary is an Elixir escript that needs the Erlang runtime. Elixir is installed but its bin directory is not in your PATH.

**Fix:**
```bash
echo 'export PATH="$(brew --prefix)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### `mix escript.build` stops at `nimble_options`

The `setup.sh` previously piped build output through `head -5` which killed the process via SIGPIPE. This was fixed in v1.1.6+. Re-run the installer:

```bash
curl -fsSL "https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh?$(date +%s)" | bash
```

### `shazam-tui exited immediately` or `exit code 13`

The TUI binary search found the `shazam-tui/` **directory** instead of the binary file. Fixed in v1.2.1+. Update:

```bash
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

### `permission denied: /Users/OTHER_USER/.shazam/logs`

The escript was compiled with another user's home directory hardcoded. Fixed in v0.2.5+ (runtime path resolution). Re-install:

```bash
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

### `shazam update` says "not installed via setup.sh"

The update command looked for `~/.shazam-cli` (old layout) but the installer uses `~/.shazam-install/`. Fixed in v1.1.9+. Re-install first, then `shazam update` will work.

### Rust build warnings during install

These are harmless. If you see `dead_code` or `unused import` warnings, they don't affect functionality.

### Git checkout fails silently during update

The setup.sh now runs `git reset --hard` and `git clean -fd` before checking out tags to avoid dirty state issues.

## Daemon Issues

### `Daemon failed to start within 15 seconds`

The daemon starts `elixir -S mix run --no-halt` in the shazam-core directory. Common causes:

1. **Dependencies not compiled**: Run manually to see the error:
   ```bash
   cd ~/.shazam-install/shazam-core
   SHAZAM_DAEMON=true SHAZAM_PORT=4040 elixir -S mix run --no-halt
   ```

2. **Port 4040 already in use**: Check what's using the port:
   ```bash
   lsof -i :4040
   ```

3. **Elixir not in PATH**: See the `escript` fix above.

Check logs:
```bash
cat ~/.shazam/logs/daemon.stdout.log
cat ~/.shazam/logs/daemon.stderr.log
```

### Daemon runs but TUI shows "Shazam session ended"

The TUI connects via WebSocket to the daemon. If it exits immediately, check `/tmp/shazam-tui.log`:
```bash
cat /tmp/shazam-tui.log
```

## Tray Issues

### "Shazam Tray is damaged and can't be opened"

macOS Gatekeeper blocks unsigned apps. Fix:

```bash
xattr -cr /Applications/Shazam\ Tray.app
```

Or: Right-click → Open → Open (bypasses Gatekeeper once).

### Tray "Start Backend" fails silently

The tray runs `shazam-cli daemon start` which needs Elixir in PATH. When launched from the .app bundle, PATH is minimal. Fixed in v0.1.1+ (injects common PATH locations). If still failing, check:

```bash
cat ~/.shazam/logs/tray.stderr.log
```

### Tray doesn't appear in menu bar

Make sure the app has the `LSUIElement` flag set (hides from Dock, shows only in menu bar). If it appears in the Dock instead, update to v0.1.1+.

## Dashboard Issues

### "The string did not match the expected pattern"

The Tauri app tries to fetch from `http://127.0.0.1:4040` but WebKit blocks mixed-content requests from `tauri://localhost`. Fixed in v0.2.1+ with Tauri HTTP and WebSocket plugins.

### Dashboard shows "Reconnecting"

The WebSocket connection to the daemon failed. Check:
1. Is the daemon running? `shazam daemon status`
2. Is port 4040 accessible? `curl http://127.0.0.1:4040/api/health`

### Projects page shows JSON instead of project name

The YAML parser stored the entire `company` object as the name instead of extracting `company.name`. Fixed in v0.3.2+.

### Tasks show all projects mixed together

Tasks need to be filtered by company. Fixed in v0.3.0+ (passes `?company=` query parameter).

## General

### How to check versions

```bash
shazam --version          # CLI version
shazam daemon status      # Daemon version + health
curl http://127.0.0.1:4040/api/health  # Backend version
```

### How to completely reset

```bash
shazam daemon stop
rm -rf ~/.shazam/
rm -rf ~/.shazam-install/
# Then re-install:
curl -fsSL https://raw.githubusercontent.com/raphaelbarbosaqwerty/shazam-cli/main/setup.sh | bash
```

### How to report issues

Include these in your bug report:
```bash
shazam --version
elixir --version
rustc --version
uname -m  # arch
cat /tmp/shazam-tui.log 2>/dev/null
cat ~/.shazam/logs/daemon.stderr.log 2>/dev/null
```

File issues at: https://github.com/ShazamAI/shazam-cli/issues
