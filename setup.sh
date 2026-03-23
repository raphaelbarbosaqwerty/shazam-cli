#!/usr/bin/env bash
set -euo pipefail

CORE_REPO="https://github.com/ShazamAI/shazam-core.git"
CLI_REPO="https://github.com/raphaelbarbosaqwerty/shazam-cli.git"
INSTALL_DIR="${HOME}/bin"
SHAZAM_HOME="${HOME}/.shazam-install"
CORE_DIR="${SHAZAM_HOME}/shazam-core"
CLI_DIR="${SHAZAM_HOME}/shazam-cli"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

echo ""
echo -e "${YELLOW}⚡ Shazam — AI Agent Orchestrator${NC}"
echo -e "${DIM}   https://shazam.dev${NC}"
echo ""

# ── Ensure cargo is in PATH ───────────────────────────────

if [ -f "$HOME/.cargo/env" ]; then
  source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$HOME/bin:$HOME/.local/bin:$PATH"

# ── Clone or update CORE ─────────────────────────────────

clone_or_update() {
  local repo="$1"
  local dir="$2"
  local name="$3"

  if [ -d "$dir" ]; then
    echo -e "${DIM}Updating ${name}...${NC}"
    cd "$dir"
    git fetch origin --tags --force --quiet
    LATEST_TAG=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "")
    if [ -n "$LATEST_TAG" ]; then
      git checkout "$LATEST_TAG" --quiet 2>/dev/null
      echo -e "  ${name}: ${GREEN}${LATEST_TAG}${NC}"
    else
      git reset --hard origin/main --quiet
      echo -e "  ${name}: ${GREEN}latest${NC}"
    fi
  else
    echo -e "${DIM}Cloning ${name}...${NC}"
    git clone --quiet "$repo" "$dir"
    cd "$dir"
    LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    if [ -n "$LATEST_TAG" ]; then
      git checkout "$LATEST_TAG" --quiet 2>/dev/null
      echo -e "  ${name}: ${GREEN}${LATEST_TAG}${NC}"
    fi
  fi
}

mkdir -p "$SHAZAM_HOME"
clone_or_update "$CORE_REPO" "$CORE_DIR" "shazam-core"
clone_or_update "$CLI_REPO" "$CLI_DIR" "shazam-cli"

echo ""

# ── Detect build strategy ─────────────────────────────────

USE_NIX=false

if command -v nix &> /dev/null; then
  USE_NIX=true
  echo -e "${GREEN}✓${NC} Nix detected — using Nix for all dependencies"
else
  echo -e "${DIM}Nix not found — checking manual dependencies...${NC}"
  echo ""

  check_cmd() {
    if ! command -v "$1" &> /dev/null; then
      echo -e "${RED}✗ $1 not found.${NC} $2"
      return 1
    else
      echo -e "${GREEN}✓${NC} $1 found"
      return 0
    fi
  }

  MISSING=0
  check_cmd "elixir" "Install: https://elixir-lang.org/install.html (>= 1.18 required)" || MISSING=1
  if command -v elixir &> /dev/null; then
    ELIXIR_VER=$(elixir --version 2>/dev/null | grep "Elixir" | sed 's/.*Elixir //' | cut -d. -f1-2)
    if [ "$(printf '%s\n' "1.18" "$ELIXIR_VER" | sort -V | head -1)" != "1.18" ]; then
      echo -e "${RED}✗ Elixir $ELIXIR_VER is too old. Version >= 1.18 required.${NC}"
      MISSING=1
    fi
  fi
  check_cmd "cargo" "Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" || MISSING=1
  check_cmd "claude" "Install: https://docs.anthropic.com/en/docs/claude-code" || MISSING=1

  if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo -e "${YELLOW}Tip:${NC} Install Nix to skip manual dependency setup:"
    echo -e "  ${DIM}curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh${NC}"
    echo ""
    echo -e "${RED}Please install missing dependencies and run again.${NC}"
    exit 1
  fi
fi

echo ""

# ── Build ──────────────────────────────────────────────────

cd "$CLI_DIR"

if [ "$USE_NIX" = true ]; then
  echo -e "  Building with Nix..."
  nix develop --extra-experimental-features "nix-command flakes" --command bash -c "./build.sh"
else
  echo "  [1/4] Installing Elixir dependencies..."
  mix local.hex --force --if-missing > /dev/null 2>&1
  mix local.rebar --force --if-missing > /dev/null 2>&1
  mix deps.get --quiet 2>&1

  echo "  [2/4] Building Rust TUI..."
  cd shazam-tui
  if ! cargo build --release 2>&1; then
    echo -e "        ${RED}✗ Rust TUI build failed${NC}"
    exit 1
  fi
  cd ..
  echo -e "        ${GREEN}✓${NC} shazam-tui built"

  echo "  [3/4] Building Elixir escript..."
  mix escript.build 2>&1 | head -5
  echo -e "        ${GREEN}✓${NC} shazam-cli built"

  echo "  [4/4] Installing..."
  mkdir -p "$INSTALL_DIR"

  cp shazam-cli "$INSTALL_DIR/shazam-cli"
  chmod +x "$INSTALL_DIR/shazam-cli"

  cp "shazam-tui/target/release/shazam-tui" "$INSTALL_DIR/shazam-tui"
  chmod +x "$INSTALL_DIR/shazam-tui"

  ln -sf "$INSTALL_DIR/shazam-cli" "$INSTALL_DIR/shazam"
  ln -sf "$INSTALL_DIR/shazam-cli" "$INSTALL_DIR/shz"
fi

# ── PATH check ─────────────────────────────────────────────

echo ""
if echo "$PATH" | tr ':' '\n' | grep -q "^${INSTALL_DIR}$"; then
  echo -e "${GREEN}✓${NC} ${INSTALL_DIR} is in your PATH"
else
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ${YELLOW}IMPORTANT: ${NC}${RED}Add ~/bin to your PATH to use shazam!            ║${NC}"
  echo -e "${RED}║                                                              ║${NC}"
  echo -e "${RED}║  ${NC}Run this command now:${RED}                                        ║${NC}"
  echo -e "${RED}║                                                              ║${NC}"
  echo -e "${RED}║  ${GREEN}echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc${NC}${RED}             ║${NC}"
  echo -e "${RED}║  ${GREEN}source ~/.zshrc${NC}${RED}                                                ║${NC}"
  echo -e "${RED}║                                                              ║${NC}"
  echo -e "${RED}║  ${DIM}(use ~/.bashrc if you use bash instead of zsh)${NC}${RED}              ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

echo -e "${GREEN}⚡ Shazam installed successfully!${NC}"
echo ""
echo "  Installed:"
echo -e "    ${GREEN}~/.shazam-core${NC}  — backend engine"
echo -e "    ${GREEN}~/.shazam-cli${NC}   — CLI + TUI"
echo ""
echo "  Binaries:"
echo -e "    ${GREEN}shazam-cli${NC}  — main binary"
echo -e "    ${GREEN}shazam${NC}      — alias"
echo -e "    ${GREEN}shz${NC}         — short alias"
echo ""
echo "  Get started:"
echo -e "    ${YELLOW}shazam init${NC}      Create a shazam.yaml config"
echo -e "    ${YELLOW}shazam${NC}           Open the interactive TUI"
echo ""
