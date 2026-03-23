{ config, lib, pkgs, codex-cli, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = "${codex-cli}/bin/codex";
  llmjail.dangerousFlag = "--dangerously-bypass-approvals-and-sandbox";

  environment.systemPackages = [
    codex-cli
    pkgs.bubblewrap
  ];

  # Codex looks for bwrap at /usr/bin/bwrap specifically
  systemd.tmpfiles.rules = [
    "d /usr/bin 0755 root root -"
    "L+ /usr/bin/bwrap - - - - ${pkgs.bubblewrap}/bin/bwrap"
  ];
}
