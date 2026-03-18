#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/bin"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure cargo is in PATH
if [ -f "$HOME/.cargo/env" ]; then
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$HOME/bin:$HOME/.local/bin:$PATH"

echo "⚡ Building Shazam..."
echo ""

# ── Step 1: Build Rust TUI binary ─────────────────────────
echo "  [1/3] Building Rust TUI (shazam-tui)..."
if ! command -v cargo &> /dev/null; then
  echo ""
  echo "  ERROR: cargo/Rust not found. The TUI requires Rust."
  echo "  Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  echo "  Then run this script again."
  exit 1
fi

cd "${PROJECT_DIR}/shazam-tui"
if ! cargo build --release 2>&1; then
  echo ""
  echo "  ERROR: Rust TUI build failed."
  exit 1
fi
echo "        ✓ shazam-tui built"
cd "${PROJECT_DIR}"

# Verify binary exists
if [ ! -f "${PROJECT_DIR}/shazam-tui/target/release/shazam-tui" ]; then
  echo "  ERROR: shazam-tui binary not found after build."
  exit 1
fi

# ── Step 2: Build Elixir escript ───────────────────────────
echo "  [2/3] Building Elixir escript (shazam)..."
cd "${PROJECT_DIR}"
mix local.hex --force --if-missing > /dev/null 2>&1
mix local.rebar --force --if-missing > /dev/null 2>&1
mix deps.get --quiet 2>&1
mix escript.build 2>&1 | head -5
echo "        ✓ shazam escript built"

# ── Step 3: Install to ~/bin ───────────────────────────────
echo "  [3/3] Installing to ${INSTALL_DIR}/..."
mkdir -p "${INSTALL_DIR}"

cp "${PROJECT_DIR}/shazam" "${INSTALL_DIR}/shazam"
chmod +x "${INSTALL_DIR}/shazam"

cp "${PROJECT_DIR}/shazam-tui/target/release/shazam-tui" "${INSTALL_DIR}/shazam-tui"
chmod +x "${INSTALL_DIR}/shazam-tui"
echo "        ✓ shazam-tui → ${INSTALL_DIR}/shazam-tui"

# Create 'shz' alias (avoids conflict with macOS ShazamKit /usr/bin/shazam)
ln -sf "${INSTALL_DIR}/shazam" "${INSTALL_DIR}/shz"
echo "        ✓ shazam    → ${INSTALL_DIR}/shazam"
echo "        ✓ shz       → ${INSTALL_DIR}/shz (alias)"
echo ""
echo "  ⚡ Done! Run 'shazam shell' or 'shz shell' to start."
