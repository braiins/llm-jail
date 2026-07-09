{ pkgs, ... }:

{
  # Applies host-published terminal sizes to /dev/hvc0 via TIOCSWINSZ. tty
  # core handles the ioctl (driver-independent), so it delivers SIGWINCH to
  # hvc0's foreground pgrp just as it did for ttyS0.
  systemd.services.llmjail-winsize = {
    description = "Apply terminal size updates from host via virtio-serial";
    wantedBy = [ "multi-user.target" ];
    before = [ "llmjail-tool.service" ];
    after = [ "llmjail-mounts.service" ];
    serviceConfig = {
      Type = "simple";
      # `always`, not `on-failure`: if the host bridge disconnects the
      # read loop exits 0, and we still want the service back so the
      # next reconnect delivers resizes.
      Restart = "always";
      RestartSec = "1s";
    };
    script = ''
      set -eu
      while [ ! -e /dev/virtio-ports/llmjail.winsize ]; do
        sleep 0.1
      done
      PREV=""
      while IFS=' ' read -r COLS ROWS; do
        [ -n "$COLS" ] && [ -n "$ROWS" ] || continue
        [ "$COLS $ROWS" = "$PREV" ] && continue
        PREV="$COLS $ROWS"
        ${pkgs.coreutils}/bin/stty cols "$COLS" rows "$ROWS" < /dev/hvc0 2>/dev/null || true
      done < /dev/virtio-ports/llmjail.winsize
    '';
  };
}
