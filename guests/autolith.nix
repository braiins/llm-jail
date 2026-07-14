{ autolith, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = "${autolith}/bin/autolith";
  # Autolith has no permission-prompt mode, so --dangerous is a no-op.
  llmjail.dangerousFlag = "";

  environment.systemPackages = [ autolith ];
}
