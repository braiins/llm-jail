{ config, lib, pkgs, nixpkgs, ... }:

{
  # ── Tool options (set by each guest module) ─────────────────────────────
  options.llmjail = {
    toolBinary = lib.mkOption {
      type = lib.types.str;
      description = "Path to the tool binary to exec in the guest";
    };
    dangerousFlag = lib.mkOption {
      type = lib.types.str;
      description = "CLI flag to pass when --dangerous is enabled";
    };
  };

  config = {
    # ── Boot ──────────────────────────────────────────────────────────────
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS1" ];
    boot.initrd.availableKernelModules = [
      "9p"
      "9pnet_virtio"
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtio_rng"
      "overlay"
    ];
    boot.kernelModules = [ "nf_tables" ];

    boot.initrd.supportedFilesystems = [ "ext4" ];

    # Mount nix store overlay and nix/var in postMountCommands so we control
    # ordering: the backing device (ext4 or tmpfs) MUST be mounted before the
    # overlay, and postMountCommands runs after all neededForBoot fileSystems
    # (including /.nix-lower/store) but before switch_root.
    # The 9p mount is used directly as the overlay lower layer — overlayfs
    # does not reliably cross submount boundaries, so the lower must be the
    # mounted filesystem itself, not a parent directory containing it.
    # /nix/var is bind-mounted from the backing so build artifacts
    # (/nix/var/nix/builds/) land on the backing volume, not the root tmpfs.
    boot.initrd.postMountCommands = ''
      STORE_DISK=0
      for arg in $(cat /proc/cmdline); do
        case "$arg" in
          llmjail.store_disk=1) STORE_DISK=1 ;;
        esac
      done

      mkdir -p $targetRoot/.nix-backing
      if [ "$STORE_DISK" = "1" ]; then
        mount /dev/vda $targetRoot/.nix-backing
      else
        mount -t tmpfs tmpfs $targetRoot/.nix-backing
      fi
      mkdir -p $targetRoot/.nix-backing/store-upper $targetRoot/.nix-backing/store-work $targetRoot/.nix-backing/var

      mkdir -p $targetRoot/nix/store
      mount -t overlay overlay $targetRoot/nix/store \
        -o "lowerdir=$targetRoot/.nix-lower/store,upperdir=$targetRoot/.nix-backing/store-upper,workdir=$targetRoot/.nix-backing/store-work"

      mkdir -p $targetRoot/nix/var
      mount --bind $targetRoot/.nix-backing/var $targetRoot/nix/var
    '';

    # ── Filesystems ───────────────────────────────────────────────────────
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=2G" ];
    };

    # Host nix store read-only (lower layer for the /nix/store overlay above).
    # Mounted outside /nix so it isn't hidden when the overlay covers /nix/store.
    fileSystems."/.nix-lower/store" = {
      device = "nix-store";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "cache=loose" "ro" ];
      neededForBoot = true;
    };

    # /nix/store overlay and /nix/var bind-mount are done in postMountCommands
    # (above) to ensure the backing device is ready first.

    fileSystems."/llmjail-env" = {
      device = "envfs";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "cache=none" "ro" ];
      neededForBoot = true;
    };

    # ── Networking ────────────────────────────────────────────────────────
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = true;
    networking.nameservers = [ "10.0.2.3" ];
    networking.firewall.enable = false;

    # ── User ──────────────────────────────────────────────────────────────
    users.users.user = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/user";
      shell = pkgs.bash;
      extraGroups = [ "tty" "dialout" "systemd-journal" ];
    };

    # ── llmjail-mounts service ───────────────────────────────────────────
    # Parses kernel cmdline for llmjail.mounts=tag0:/path:rw,tag1:/path:ro,...
    # and mounts each entry via 9p.
    systemd.services.llmjail-mounts = {
      description = "Mount llmjail 9p shares from kernel cmdline";
      wantedBy = [ "multi-user.target" ];
      before = [ "llmjail-tool.service" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        MOUNTS=""
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.mounts=*) MOUNTS="''${arg#llmjail.mounts=}" ;;
          esac
        done

        if [ -z "$MOUNTS" ]; then
          echo "No llmjail mounts specified."
          exit 0
        fi

        IFS=',' read -ra ENTRIES <<< "$MOUNTS"
        for entry in "''${ENTRIES[@]}"; do
          IFS=':' read -r tag mpath mode <<< "$entry"

          if [ "$mode" = "overlay" ]; then
            # Overlay entry: tag is the lower path (already mounted), mpath is the target
            echo "Creating overlay $tag -> $mpath"
            ${pkgs.coreutils}/bin/mkdir -p "$mpath" "''${mpath}-upper/upper" "''${mpath}-upper/work"
            ${pkgs.util-linux}/bin/mount -t overlay overlay "$mpath" \
              -o "lowerdir=$tag,upperdir=''${mpath}-upper/upper,workdir=''${mpath}-upper/work"
          else
            echo "Mounting $tag -> $mpath ($mode)"
            ${pkgs.coreutils}/bin/mkdir -p "$mpath"

            OPTS="trans=virtio,version=9p2000.L,cache=mmap"
            if [ "$mode" = "ro" ]; then
              OPTS="$OPTS,ro"
            elif [ "$mode" = "ro-nocache" ]; then
              OPTS="trans=virtio,version=9p2000.L,cache=none,ro"
            fi
            ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$mpath" -o "$OPTS"
          fi

          # Fix ownership for paths under /home/user
          case "$mpath" in
            /home/user|/home/user/*)
              ${pkgs.coreutils}/bin/chown user:users "$mpath" 2>/dev/null || true
              ;;
          esac
        done

        # Copy dotfiles provided via envfs (can't mount individual files via 9p)
        # Any file starting with '.' placed in envfs by mkRunner is copied to $HOME
        for src in /llmjail-env/.*; do
          [ -f "$src" ] || continue
          name="''${src##*/}"
          ${pkgs.coreutils}/bin/cp "$src" "/home/user/$name"
          ${pkgs.coreutils}/bin/chown user:users "/home/user/$name"
        done

        # Live-mount credentials from the ro lower layer (cache=none) so
        # host-side token refreshes are visible instantly in the guest.
        # Bind-mount bypasses the overlay — reads go straight to the 9p mount.
        for cdir in /home/user/*-ro; do
          [ -d "$cdir" ] || continue
          target="/home/user/$(${pkgs.coreutils}/bin/basename "$cdir" -ro)"
          CRED="$cdir/.credentials.json"
          DEST="$target/.credentials.json"
          if [ -f "$CRED" ]; then
            ${pkgs.coreutils}/bin/touch "$DEST"
            ${pkgs.util-linux}/bin/mount --bind "$CRED" "$DEST"
            echo "Bind-mounted credentials: $CRED -> $DEST"
          fi
        done

      '';
    };

    # ── Common packages available in every guest ─────────────────────────
    environment.systemPackages = with pkgs; [
      git
      nodejs
      openssh
      coreutils
      bash
      curl
      findutils
      gnugrep
      gnused
      gawk
      diffutils
      dnsmasq
      nftables
    ];

    # ── llmjail-net-filter service ─────────────────────────────────────
    # Configures DNS whitelist (dnsmasq) and port-level firewall (nftables)
    # when llmjail.net_filter=1 is set on the kernel cmdline.
    systemd.services.llmjail-net-filter = {
      description = "llmjail network filter (DNS whitelist + nftables)";
      wantedBy = [ "multi-user.target" ];
      after = [ "llmjail-mounts.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "llmjail-tool.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        # Check kernel cmdline for net_filter flag
        NET_FILTER=0
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.net_filter=1) NET_FILTER=1 ;;
          esac
        done

        if [ "$NET_FILTER" != "1" ]; then
          echo "Network filtering disabled."
          exit 0
        fi

        # ── Generate dnsmasq config ─────────────────────────────────
        DNSMASQ_CONF="/etc/dnsmasq-llmjail.conf"
        {
          echo "no-resolv"
          echo "no-hosts"
          echo "listen-address=127.0.0.1"
          echo "bind-interfaces"

          # Forward allowed domains to QEMU's DNS
          if [ -f /llmjail-env/allowed-domains ]; then
            while IFS= read -r domain || [ -n "$domain" ]; do
              [ -z "$domain" ] && continue
              echo "server=/$domain/10.0.2.3"
            done < /llmjail-env/allowed-domains
          fi

          # No default upstream — unmatched queries get REFUSED
        } > "$DNSMASQ_CONF"

        # ── Start dnsmasq ───────────────────────────────────────────
        ${pkgs.dnsmasq}/bin/dnsmasq \
          --conf-file="$DNSMASQ_CONF" \
          --pid-file=/run/dnsmasq-llmjail.pid

        # ── Point resolv.conf at local dnsmasq ──────────────────────
        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        # ── Apply nftables firewall rules ───────────────────────────
        ${pkgs.nftables}/bin/nft -f - <<'NFTEOF'
        table inet llmjail_filter {
          chain output {
            type filter hook output priority 0; policy drop;

            # Allow loopback
            oifname "lo" accept

            # Allow established/related
            ct state established,related accept

            # Allow DHCP
            udp dport { 67, 68 } accept

            # Allow DNS from dnsmasq to QEMU DNS
            ip daddr 10.0.2.3 udp dport 53 accept
            ip daddr 10.0.2.3 tcp dport 53 accept

            # Allow outbound HTTP/HTTPS
            tcp dport { 80, 443 } accept

            # Drop everything else
            log prefix "llmjail-drop: " drop
          }
        }
        NFTEOF

        echo "Network filtering enabled with $(${pkgs.coreutils}/bin/wc -l < /llmjail-env/allowed-domains) allowed domain(s)."
      '';
    };

    # ── llmjail-winsize service ──────────────────────────────────────────
    # Reads "cols rows" lines from a dedicated virtio-serial port
    # (`llmjail.winsize`) published by the host runner and applies them to
    # /dev/ttyS0 via stty. TIOCSWINSZ delivers SIGWINCH to ttyS0's foreground
    # process group, so the TUI resizes live without any QEMU patches.
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
          ${pkgs.coreutils}/bin/stty cols "$COLS" rows "$ROWS" < /dev/ttyS0 2>/dev/null || true
        done < /dev/virtio-ports/llmjail.winsize
      '';
    };

    # ── llmjail-tool service ────────────────────────────────────────────
    systemd.services.llmjail-tool =
      let
        launcher = pkgs.writeShellScript "launch-tool" ''
          set -euo pipefail

          # Add host packages to PATH if available (NixOS host)
          if [ -d /host-user-sw/bin ]; then
            export PATH="/host-user-sw/bin:$PATH"
          fi
          if [ -d /host-sw/bin ]; then
            export PATH="/host-sw/bin:$PATH"
          fi

          # Source nix develop environment if available
          if [ -f /llmjail-env/dev-env ]; then
            # dev-env is output of `nix print-dev-env` — a bash script setting PATH, etc.
            # shellcheck disable=SC1091
            source /llmjail-env/dev-env
          fi

          ARGS=()
          if [ "''${LLMJAIL_DANGEROUS:-0}" = "1" ]; then
            ARGS+=(${config.llmjail.dangerousFlag})
          fi

          # Read null-separated tool args preserving argument boundaries
          if [ -s /llmjail-env/tool-args ]; then
            while IFS= read -r -d "" arg; do
              ARGS+=("$arg")
            done < /llmjail-env/tool-args
          fi

          # Apply the initial terminal size synchronously BEFORE exec so the
          # TUI sees a non-zero TIOCGWINSZ on first read. Dynamic resizes
          # after this point are handled by the llmjail-winsize side-channel
          # service. (stdin is /dev/ttyS0 via systemd TTYPath.)
          if [ -n "''${COLUMNS:-}" ] && [ -n "''${LINES:-}" ]; then
            ${pkgs.coreutils}/bin/stty cols "$COLUMNS" rows "$LINES" 2>/dev/null || true
          fi

          cd /workspace
          exec ${config.llmjail.toolBinary} "''${ARGS[@]}"
        '';
      in
      {
        description = "llmjail tool runner";
        wantedBy = [ "multi-user.target" ];
        after = [ "llmjail-mounts.service" "llmjail-net-filter.service" "network-online.target" ];
        wants = [ "llmjail-mounts.service" "llmjail-net-filter.service" "network-online.target" ];
        path = [ "/run/current-system/sw" ];
        serviceConfig = {
          User = "user";
          WorkingDirectory = "/workspace";
          EnvironmentFile = "/llmjail-env/env";
          StandardInput = "tty";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/ttyS0";
          TTYReset = true;
          TTYVHangup = false;
          ExecStart = "${launcher}";
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff --force --force";
        };
      };

    # ── Disable unnecessary services ─────────────────────────────────────
    # No getty on serial — tool service owns the TTY
    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@ttyS1".enable = false;
    systemd.services."getty@tty1".enable = false;

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.settings.sandbox = false;

    # Pin nixpkgs so `nix shell nixpkgs#...` and `nix-shell -p ...` resolve
    # to the same nixpkgs used to build this system.  The store path is part
    # of the system closure (GC root) — it cannot be collected while the VM
    # runner script exists, preventing stale 9p cache hits on GC'd paths.
    nix.registry.nixpkgs.flake = nixpkgs;
    nix.nixPath = [ "nixpkgs=${pkgs.path}" ];
    systemd.services.systemd-networkd-wait-online.enable = false;

    system.stateVersion = "24.11";
  };
}
