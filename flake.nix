{
  description = "Shazam — AI Agent Orchestrator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir/Erlang
        erlang = pkgs.erlang_27;
        beamPkgs = pkgs.beam.packagesWith erlang;
        elixir = beamPkgs.elixir_1_18;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Elixir + Erlang
            erlang
            elixir

            # Rust
            pkgs.rustc
            pkgs.cargo

            # Build deps
            pkgs.sqlite
            pkgs.pkg-config
            pkgs.openssl

            # Useful tools
            pkgs.git
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"
            export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$HOME/bin:$PATH"
            export LANG="en_US.UTF-8"
            export ERL_AFLAGS="-kernel shell_history enabled"

            # Auto-install hex and rebar if missing
            if [ ! -d "$MIX_HOME" ]; then
              mix local.hex --force --if-missing
              mix local.rebar --force --if-missing
            fi

            echo ""
            echo "⚡ Shazam dev environment ready"
            echo "   Elixir: $(elixir --version | head -2 | tail -1)"
            echo "   Rust:   $(rustc --version)"
            echo ""
            echo "   Run: ./build.sh"
            echo ""
          '';
        };
      }
    );
}
