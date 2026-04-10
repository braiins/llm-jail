{
  lib,
  copilot-cli,
  ...
}:
let
in
{
  imports = [
    ./common.nix
  ];

  llmjail.toolBinary = lib.getExe copilot-cli;
  llmjail.dangerousFlag = "--yolo";
  environment.systemPackages = [
    copilot-cli
  ];
}
