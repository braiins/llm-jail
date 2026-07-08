{ pkgs, claude-code, ... }:

{
  imports = [ ./common.nix ];

  # Pre-trust /workspace so claude doesn't ask "Is this a project you trust?"
  # on first run. The path is constant inside the VM, and the .claude.json
  # lives in the jail-private config mount ($CLAUDE_CONFIG_DIR), so the
  # patch persists there - the host tool's own config is never touched.
  llmjail.toolBinary = pkgs.writeShellScript "claude-launcher" ''
    CLAUDE_JSON="$CLAUDE_CONFIG_DIR/.claude.json"
    if [ ! -f "$CLAUDE_JSON" ]; then
      echo '{}' > "$CLAUDE_JSON"
    fi
    ${pkgs.jq}/bin/jq '.projects["/workspace"] = ((.projects["/workspace"] // {}) + {hasTrustDialogAccepted: true})' \
      "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
    exec ${claude-code}/bin/claude "$@"
  '';
  llmjail.dangerousFlag = "--dangerously-skip-permissions";

  environment.systemPackages = [
    claude-code
  ];
}
