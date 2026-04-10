{ claude-code, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = "${claude-code}/bin/claude";
  llmjail.dangerousFlag = "--dangerously-skip-permissions";

  environment.systemPackages = [
    claude-code
  ];
}
