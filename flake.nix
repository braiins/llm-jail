{
  description = "llm-jail - QEMU MicroVM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
    autolith.url = "github:luciusmagn/autolith";
  };

  outputs = { self, nixpkgs, claude-code-nix, codex-cli-nix, llm-agents, autolith, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
      toolsForSystem = system:
        nixpkgs.lib.filterAttrs
          (_: def: builtins.elem system (def.systems or supportedSystems))
          tools;

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
          };
        in pkgs.lib.makeOverridable ({ claude-code, codex-cli, copilot-cli, opencode, autolith }:
          let
            guest = nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = { inherit nixpkgs claude-code codex-cli copilot-cli opencode autolith; };
              modules = [
                toolDef.guestModule
                { nixpkgs.config.allowUnfree = true; }
              ];
            };
          in import ./lib/mkRunner.nix {
            inherit pkgs guest;
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
        import ./tests {
          inherit nixpkgs;
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          claude-code = claude-code-nix.packages.${system}.default;
          codex-cli = codex-cli-nix.packages.${system}.default;
          copilot-cli = llm-agents.packages.${system}.copilot-cli;
          opencode = llm-agents.packages.${system}.opencode;
          autolith = autolith.packages.${system}.default;
        }
      );
    };
}
