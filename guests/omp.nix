{ pkgs, omp, ... }:

{
  imports = [ ./common.nix ];

  # Pi has no --dangerous/--approve flag. Project trust is handled via
  # settings.json (defaultProjectTrust) in the jail-private config dir.
  llmjail.toolBinary = pkgs.writeShellScript "pi-launcher" ''
    # Ensure /workspace is trusted on every launch. Pi's /login flow
    # rewrites settings.json and may drop defaultProjectTrust.
    SETTINGS="$PI_CODING_AGENT_DIR/settings.json"
    if [ -f "$SETTINGS" ]; then
      ${pkgs.jq}/bin/jq '.defaultProjectTrust = "trusted"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      echo '{"defaultProjectTrust":"trusted"}' > "$SETTINGS"
    fi

    exec ${pkgs.lib.getExe omp} "$@"
  '';
  llmjail.dangerousFlag = "";

  environment.systemPackages = [
    omp
    pkgs.bun
  ];
}

