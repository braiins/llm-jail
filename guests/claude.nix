{ pkgs, claude-code, ... }:

{
  imports = [ ./common.nix ];

  # Pre-trust /workspace so claude doesn't ask "Is this a project you trust?"
  # on every run. The path is constant inside the VM, and the .claude.json
  # we patch here is the tmpfs copy — host file is untouched.
  llmjail.toolBinary = pkgs.writeShellScript "claude-launcher" ''
    CLAUDE_JSON="$HOME/.claude.json"
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
