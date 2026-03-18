{ config, lib, pkgs, codex-cli, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = "${codex-cli}/bin/codex";
  llmjail.dangerousFlag = "--full-auto";

  environment.systemPackages = [
    codex-cli
  ];
}
