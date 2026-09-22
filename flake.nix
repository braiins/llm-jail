{
  description = "llm-jail - microVM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Nixpkgs that is pinned in NIX_PATH and flake registry in the VM, should be up to date
    nixpkgs-rolling.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
    autolith.url = "github:luciusmagn/autolith";
    nix-omp.url = "github:jamtur01/nix-omp";
  };

  outputs = { self, nixpkgs, nixpkgs-rolling, claude-code-nix, codex-cli-nix, llm-agents, autolith, nix-omp, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
      guestSystemFor = hostSystem:
        if hostSystem == "aarch64-darwin" then "aarch64-linux" else hostSystem;
      autolithPackageFor = system:
        nixpkgs.lib.attrByPath [ "packages" system "default" ] null autolith;
      toolsForSystem = hostSystem:
        let
          guestSystem = guestSystemFor hostSystem;
        in
          nixpkgs.lib.filterAttrs
            (name: def:
              builtins.elem guestSystem (def.systems or supportedSystems)
              && (name != "autolith" || autolithPackageFor guestSystem != null)
              && (hostSystem != "aarch64-darwin" || builtins.elem name [ "claude" "autolith" "shell" ]))
            tools;

      mkTool = hostSystem: toolName: toolDef:
        let
          guestSystem = guestSystemFor hostSystem;
          pkgs = nixpkgs.legacyPackages.${hostSystem};
          # Default tool packages - overridable via `.override { claude-code = ...; }`
          # on the resulting runner derivation. Consumers can swap any of these
          # without forking the flake.
          defaultArgs = {
            claude-code = claude-code-nix.packages.${guestSystem}.default;
            codex-cli = codex-cli-nix.packages.${guestSystem}.default;
            copilot-cli = llm-agents.packages.${guestSystem}.copilot-cli;
            opencode = llm-agents.packages.${guestSystem}.opencode;
            autolith = autolithPackageFor guestSystem;
            pi-coding-agent = llm-agents.packages.${guestSystem}.pi;
            omp = nix-omp.packages.${guestSystem}.default;
          };
        in
        pkgs.lib.makeOverridable (
          {
            claude-code,
            codex-cli,
            copilot-cli,
            opencode,
            autolith,
            pi-coding-agent,
            omp,
          }:
          let
            guest = nixpkgs.lib.nixosSystem {
              system = guestSystem;
              specialArgs = {
                hostBackend = if pkgs.stdenv.hostPlatform.isDarwin then "vz" else "qemu";
                inherit
                  nixpkgs
                  nixpkgs-rolling
                  claude-code
                  codex-cli
                  copilot-cli
                  opencode
                  autolith
                  pi-coding-agent
                  omp
                  ;
              };
              modules = [
                toolDef.guestModule
                { nixpkgs.config.allowUnfree = true; }
              ];
            };
          in import ./lib/mkRunner.nix {
            inherit pkgs guest guestSystem;
            name = toolName;
            toolDefaults = toolDef.defaults;
          }
        ) defaultArgs;

    in {
      packages = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: def: mkTool system name def) (toolsForSystem system)
      );

      apps = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: _: {
          type = "app";
          program = "${self.packages.${system}.${name}}/bin/llm-jail-${name}";
        }) (toolsForSystem system)
      );

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          darwinDnsSelectorCheck = pkgs.runCommand "llmjail-darwin-dns-selector" { } ''
            selected=$(${pkgs.gawk}/bin/awk \
              -f ${./lib/select-darwin-dns.awk} \
              ${./tests/fixtures/scutil-dns-tailscale.txt})
            test "$selected" = "192.0.2.53"

            selected=$(${pkgs.gawk}/bin/awk \
              -f ${./lib/select-darwin-dns.awk} \
              ${./tests/fixtures/scutil-dns-no-ordinary-ipv4.txt})
            test -z "$selected"

            touch "$out"
          '';
        in {
          darwin-dns-selector = darwinDnsSelectorCheck;
        } // (
          if pkgs.stdenv.hostPlatform.isDarwin then
            {
              claude-runner = self.packages.${system}.claude;
              shell-runner = self.packages.${system}.shell;
            }
            // nixpkgs.lib.optionalAttrs (autolithPackageFor (guestSystemFor system) != null) {
              autolith-runner = self.packages.${system}.autolith;
            }
          else
            import ./tests {
              inherit nixpkgs nixpkgs-rolling pkgs;
              claude-code = claude-code-nix.packages.${system}.default;
              codex-cli = codex-cli-nix.packages.${system}.default;
              copilot-cli = llm-agents.packages.${system}.copilot-cli;
              opencode = llm-agents.packages.${system}.opencode;
              autolith = autolithPackageFor system;
              pi-coding-agent = llm-agents.packages.${system}.pi;
              omp = nix-omp.packages.${system}.default;
            }
        )
      );
    };
}
