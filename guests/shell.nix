{ pkgs, ... }:

{
  imports = [ ./common.nix ];

  llmjail.toolBinary = pkgs.writeShellScript "shell-launcher" ''
    # Create an empty $HOME/.zshrc in the jail, so that zsh doesn't complain about it
    ensure_zshrc() {
      [ -e "$HOME/.zshrc" ] || : > "$HOME/.zshrc"
    }

    # Honor host's $SHELL (resolved through symlinks by the runner so the
    # value points at /nix/store, which the guest reaches via 9p). Fall back
    # to whatever shell is reachable via PATH (covers /host-user-sw and
    # /host-sw on NixOS hosts), then to the guest's bash on non-NixOS hosts.
    if [ -n "''${SHELL:-}" ] && [ -x "$SHELL" ]; then
      case "''${SHELL##*/}" in zsh) ensure_zshrc ;; esac
      exec "$SHELL" -l
    fi
    for cand in zsh bash; do
      if command -v "$cand" >/dev/null 2>&1; then
        [ "$cand" = zsh ] && ensure_zshrc
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
