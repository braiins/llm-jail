{ pkgs, ... }:

let
  # Sourced by the interactive login shell's rc file. dev-env is
  # `nix print-dev-env` or `devenv direnv-export` output ending in
  # `eval "${shellHook:-}"`, so sourcing it here runs the devShell's
  # shellHook in the shell the user sees: aliases, functions, and PS1
  # changes from the hook stick, and the interactive bash (with readline)
  # renders PS1's `\[`/`\]` escapes properly. The tool launcher already
  # sourced dev-env for the process environment (PATH etc.); this second
  # source is what makes the hook's shell-local effects land in the
  # interactive shell - the hook therefore runs twice with --nix-env,
  # which is the accepted tradeoff for keeping the launcher shared.
  # Options are relaxed before sourcing (dev-env is not written to
  # tolerate nounset/errexit) and left off afterwards - this shell is
  # interactive, not a script.
  rcSnippet = ''
    if [ -f /llmjail-env/dev-env ]; then
      set +euo pipefail 2>/dev/null || true
      . /llmjail-env/dev-env
    fi
  '';
in
{
  imports = [ ./common.nix ];

  llmjail.toolBinary = pkgs.writeShellScript "shell-launcher" ''
    if [ -f /llmjail-env/dev-env ]; then
      # --nix-env/--devenv: the captured dev-env is a bash script
      # (`nix print-dev-env`/`devenv direnv-export` output), so run the
      # guest's interactive bash, not the host's $SHELL. Wire dev-env
      # into the interactive shell's startup files (see rcSnippet above):
      # login bash reads /etc/profile, then the first of
      # ~/.bash_profile, ~/.bash_login, ~/.profile; the jail home starts
      # empty, so ~/.profile is the one that runs.
      printf '%s\n' '${rcSnippet}' > "''${HOME:-/home/user}/.profile"
      exec ${pkgs.bashInteractive}/bin/bash -l
    fi

    # No dev shell environment: run the host's shell (the runner resolves
    # it through symlinks so the value points at /nix/store, reachable
    # via 9p). Fall back to the guest's bash when the host has no usable
    # $SHELL.
    if [ -n "''${SHELL:-}" ] && [ -x "$SHELL" ]; then
      exec "$SHELL" -l
    fi
    exec ${pkgs.bashInteractive}/bin/bash -l
  '';
  # --dangerous is meaningless for an interactive shell.
  llmjail.dangerousFlag = "";

  environment.systemPackages = with pkgs; [
    bashInteractive
    zsh
  ];
}
