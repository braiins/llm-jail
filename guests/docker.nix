# Rootless Docker, added by the `docker` build-time argument
# (`nix run .#claude.docker`).
#
# Rootless rather than the stock rootful daemon: access to a rootful
# daemon's socket is root-equivalent in the guest, which would let the agent
# flush the network filter's nftables rules or unmount the --mask overlays.
# Rootless dockerd runs as `user` inside a user namespace, and container
# egress leaves through slirp4netns as ordinary sockets owned by `user`, so it
# goes through the same output-chain filter, and resolves through the same
# dnsmasq allowlist (slirp4netns forwards DNS to the nameserver in
# /etc/resolv.conf), as the tool itself.
#
# The daemon is NixOS's rootless user unit, run by `user`'s systemd user
# manager, which lingering starts at boot.
{ pkgs, ... }:
{
  llmjail.extraAllowedDomains = [
    # Docker Hub: registry-1.docker.io and auth.docker.io (subdomains are
    # matched automatically), plus the blob hosts pulls are redirected to
    # (https://docs.docker.com/desktop/setup/allow-list/)
    "docker.io"
    "production.cloudfront.docker.com"
    "production.cloudflare.docker.com"
    "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com"
  ];

  virtualisation.docker.rootless = {
    enable = true;
  };
  # The module adds docker itself, which includes the compose and buildx CLI
  # plugins; this adds the standalone `docker-compose` command.
  environment.systemPackages = [ pkgs.docker-compose ];

  # The module's setSocketVariable derives the socket from XDG_RUNTIME_DIR,
  # which the tool service doesn't have. set-environment is sourced by the
  # launcher and login shells, so $UID expands to the remapped uid there.
  environment.variables.DOCKER_HOST = "unix:///run/user/$UID/docker.sock";

  users.users.user = {
    # newuidmap/newgidmap map these into the daemon's user namespace
    autoSubUidGidRange = true;
    linger = true;
  };

  # linger-users starts user@<uid>, and with it the daemon. It resolves `user`
  # to a uid when it does, so it must run after the remap to the host uid; and
  # after the net filter has pointed /etc/resolv.conf at dnsmasq, which
  # slirp4netns forwards container DNS to. The data root is created here
  # because it needs root and the remapped uid.
  systemd.services.linger-users = {
    after = [ "llmjail-set-user-uid.service" "llmjail-net-filter.service" ];
  };

  # user@<uid> reports ready at the user manager's basic.target, before the
  # daemon (in default.target) is up. Hold the tool back until the socket
  # exists so `docker` works from its first command; a daemon that never
  # comes up delays the tool by at most the timeout.
  systemd.services.llmjail-docker-ready = {
    description = "Wait for the rootless Docker socket";
    wantedBy = [ "multi-user.target" ];
    after = [ "linger-users.service" ];
    before = [ "llmjail-tool.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30s";
    };
    script = ''
      sock="/run/user/$(id -u user)/docker.sock"
      until [ -S "$sock" ]; do sleep 0.1; done
    '';
  };
}
