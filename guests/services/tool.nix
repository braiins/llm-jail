{ config, lib, pkgs, ... }:

{
  options.llmjail = {
    toolBinary = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.package;
      description = "Path to the tool binary to exec in the guest (string or derivation)";
    };
    dangerousFlag = lib.mkOption {
      type = lib.types.str;
      description = "CLI flag to pass when --dangerous is enabled";
    };
  };

  config = {
    systemd.services.llmjail-tool =
      let
        launcher = pkgs.writeShellScript "launch-tool" ''
          set -euo pipefail

          # Add host packages to PATH if available (NixOS host)
          if [ -d /host-user-sw/bin ]; then
            export PATH="/host-user-sw/bin:$PATH"
          fi
          if [ -d /host-sw/bin ]; then
            export PATH="/host-sw/bin:$PATH"
          fi

          # nixpkgs zsh bakes a global zshenv into its own store path, so a
          # forwarded host $SHELL sources it even though the guest has no
          # /etc/zshenv. Unless this guard is set, that zshenv sources the
          # guest's /etc/set-environment in every `zsh -c`, which REPLACES
          # PATH with the guest session default - silently dropping the
          # /host-sw, /host-user-sw, and dev-env entries above. The bash
          # login path (/etc/profile) honors the same guard.
          export __NIXOS_SET_ENVIRONMENT_DONE=1

          if [ -f /llmjail-env/dev-env ]; then
            # dev-env is output of `nix print-dev-env` - a bash script setting PATH, etc.
            # shellcheck disable=SC1091
            source /llmjail-env/dev-env
          fi

          ARGS=()
          if [ "''${LLMJAIL_DANGEROUS:-0}" = "1" ]; then
            ARGS+=(${config.llmjail.dangerousFlag})
          fi

          # Read null-separated tool args preserving argument boundaries
          if [ -s /llmjail-env/tool-args ]; then
            while IFS= read -r -d "" arg; do
              ARGS+=("$arg")
            done < /llmjail-env/tool-args
          fi

          # Apply the initial terminal size synchronously BEFORE exec so the
          # TUI sees a non-zero TIOCGWINSZ on first read. Dynamic resizes
          # after this are handled by the llmjail-winsize side-channel.
          if [ -n "''${COLUMNS:-}" ] && [ -n "''${LINES:-}" ]; then
            ${pkgs.coreutils}/bin/stty cols "$COLUMNS" rows "$LINES" 2>/dev/null || true
          fi

          cd /workspace
          exec ${config.llmjail.toolBinary} "''${ARGS[@]}"
        '';
      in
      {
        description = "llmjail tool runner";
        wantedBy = [ "multi-user.target" ];
        after = [ "llmjail-mounts.service" "llmjail-net-filter.service" "network-online.target" ];
        wants = [ "llmjail-mounts.service" "llmjail-net-filter.service" "network-online.target" ];
        path = [ "/run/current-system/sw" ];
        serviceConfig = {
          User = "user";
          WorkingDirectory = "/workspace";
          EnvironmentFile = "/llmjail-env/env";
          StandardInput = "tty";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/hvc0";
          TTYReset = true;
          TTYVHangup = false;
          ExecStart = "${launcher}";
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff --force --force";
        };
      };

    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@ttyS1".enable = false;
    systemd.services."serial-getty@hvc0".enable = false;
    systemd.services."getty@tty1".enable = false;
    systemd.services."getty@hvc0".enable = false;
  };
}
