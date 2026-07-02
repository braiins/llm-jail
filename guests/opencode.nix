{ pkgs, opencode, ... }:

{
  imports = [ ./common.nix ];

  # XDG_DATA_HOME points into the jail-private state mount (configEnvVar in
  # tools.nix); redirect the XDG-derived config and cache dirs into the same
  # mount so themes/settings and installed provider packages persist across
  # runs. Self-update can't replace a nix-store binary and its release check
  # isn't whitelisted, so disable it.
  #
  # --dangerous is handled here instead of via dangerousFlag: the generic
  # injection prepends the flag, but yargs only dispatches subcommands when
  # they come first - `opencode --auto run ...` parses `run` as the root
  # command's project positional. Appending works for both the TUI and
  # subcommands.
  llmjail.toolBinary = pkgs.writeShellScript "opencode-launcher" ''
    export OPENCODE_DISABLE_AUTOUPDATE=1
    export OPENCODE_CONFIG_DIR="$XDG_DATA_HOME/config"
    export XDG_CACHE_HOME="$XDG_DATA_HOME/cache"
    if [ "''${LLMJAIL_DANGEROUS:-0}" = "1" ]; then
      set -- "$@" --auto
    fi
    exec ${pkgs.lib.getExe opencode} "$@"
  '';
  llmjail.dangerousFlag = "";

  environment.systemPackages = [
    opencode
  ];
}
