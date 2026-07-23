{ pkgs, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = pkgs.writeShellScript "shell-launcher" ''
    # Honor host's $SHELL (resolved through symlinks by the runner so the
    # value points at /nix/store, which the guest reaches via 9p). Fall back
    # to whatever shell is reachable via PATH (covers /host-user-sw and
    # /host-sw on NixOS hosts), then to the guest's bash on non-NixOS hosts.
    if [ -n "''${SHELL:-}" ] && [ -x "$SHELL" ]; then
      exec "$SHELL" -l
    fi
    for cand in zsh bash; do
      if command -v "$cand" >/dev/null 2>&1; then
        exec "$cand" -l
      fi
    done
    exec ${pkgs.bashInteractive}/bin/bash -l
  '';
  # --dangerous is meaningless for an interactive shell.
  llmjail.dangerousFlag = "";

  environment.systemPackages = with pkgs; [
    bashInteractive
    zsh
  ];
}
