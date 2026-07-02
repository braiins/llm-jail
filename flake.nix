{
  description = "llm-jail - QEMU MicroVM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, claude-code-nix, codex-cli-nix, llm-agents, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

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
          };
        in pkgs.lib.makeOverridable ({ claude-code, codex-cli, copilot-cli, opencode }:
          let
            guest = nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = { inherit nixpkgs claude-code codex-cli copilot-cli opencode; };
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
        nixpkgs.lib.mapAttrs (name: def: mkTool system name def) tools
      );

      apps = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: _: {
          type = "app";
          program = "${self.packages.${system}.${name}}/bin/llm-jail-${name}";
        }) tools
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
        }
      );
    };
}
