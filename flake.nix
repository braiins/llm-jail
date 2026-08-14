{
  description = "llm-jail - QEMU MicroVM sandbox for coding agents";

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
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
      toolsForSystem = system:
        nixpkgs.lib.filterAttrs
          (_: def: builtins.elem system (def.systems or supportedSystems))
          tools;

      flags = {
        devenv = true;
      };
      apply = package: setFlags: package.override { flags = setFlags; };
      addFlags = import ./lib/addFlags.nix;

      mkTool = system: toolName: toolDef:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Default tool packages - overridable via `.override { claude-code = ...; }`
          # on the resulting runner derivation. Consumers can swap any of these
          # without forking the flake.
          defaultArgs = {
            claude-code = claude-code-nix.packages.${system}.default;
            codex-cli = codex-cli-nix.packages.${system}.default;
            copilot-cli = llm-agents.packages.${system}.copilot-cli;
            opencode = llm-agents.packages.${system}.opencode;
            autolith = autolith.packages.${system}.default;
            pi-coding-agent = llm-agents.packages.${system}.pi;
            omp = nix-omp.packages.${system}.default;
          };
          tool = pkgs.lib.makeOverridable (
          {
            claude-code,
            codex-cli,
            copilot-cli,
            opencode,
            autolith,
            pi-coding-agent,
            omp,
            flags ? { },
          }:
          let
            guest = nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
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
            inherit pkgs guest flags;
            name = toolName;
            toolDefaults = toolDef.defaults;
          }
        ) defaultArgs;
        in
          addFlags tool flags apply;

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
        import ./tests {
          inherit nixpkgs nixpkgs-rolling;
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          claude-code = claude-code-nix.packages.${system}.default;
          codex-cli = codex-cli-nix.packages.${system}.default;
          copilot-cli = llm-agents.packages.${system}.copilot-cli;
          opencode = llm-agents.packages.${system}.opencode;
          autolith = autolith.packages.${system}.default;
          pi-coding-agent = llm-agents.packages.${system}.pi;
          omp = nix-omp.packages.${system}.default;
        }
      );
    };
}
