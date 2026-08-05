{ pkgs, autolith, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = pkgs.writeShellScript "autolith-launcher" ''
    export XDG_CONFIG_HOME="$AUTOLITH_HOME/config"
    export XDG_DATA_HOME="$AUTOLITH_HOME/data"
    export XDG_STATE_HOME="$AUTOLITH_HOME/state"
    export XDG_CACHE_HOME="$AUTOLITH_HOME/cache"
    export CODEX_HOME="$AUTOLITH_HOME/codex"
    export GROK_HOME="$AUTOLITH_HOME/grok"
    exec ${autolith}/bin/autolith "$@"
  '';

  llmjail.dangerousFlag = "--permissions full";

  environment.systemPackages = [ autolith ];
}
