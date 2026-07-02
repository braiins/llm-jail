{ config, lib, pkgs, nixpkgs, ... }:

{
  options.llmjail = {
    toolBinary = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.package;
      description = "Path to the tool binary to exec in the guest (string or derivation)";
    };
    dangerousFlag = lib.mkOption {
      type = lib.types.str;
      description = "CLI flag to pass when --dangerous is enabled";
    };
  };

  config = {
    boot.loader.grub.enable = false;
    # Switch to systemd-initrd (default in 26.11). Required because we use
    # boot.initrd.systemd.services below to set up the /nix/store overlay.
    boot.initrd.systemd.enable = true;
    boot.kernelParams = [ "console=ttyS1" ];
    boot.initrd.availableKernelModules = [
      "9p"
      "9pnet_virtio"
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtio_rng"
    ];
    # Force-load overlay in initrd: availableKernelModules only allows
    # autoload, but the systemd-initrd path doesn't always trigger it for
    # `mount -t overlay`, so make it explicit.
    boot.initrd.kernelModules = [ "overlay" ];
    boot.kernelModules = [ "nf_tables" ];

    boot.initrd.supportedFilesystems = [ "ext4" ];

    # Set up the /nix/store overlay and /nix/var bind in initrd. Runs after
    # the 9p store mount (RequiresMountsFor) and ordered before
    # initrd-fs.target so stage 2 sees the overlay. The backing device
    # (ext4 disk or tmpfs) is chosen at runtime from llmjail.store_disk=1
    # on the kernel cmdline. The 9p mount is used directly as the overlay
    # lower layer - overlayfs does not reliably cross submount boundaries,
    # so the lower must be the mounted filesystem itself. /nix/var is
    # bind-mounted from the backing so build artifacts land there instead
    # of the root tmpfs.
    boot.initrd.systemd.services.llmjail-store-overlay = {
      description = "Set up /nix/store overlay and /nix/var bind";
      # Pulled in by initrd-fs.target AND by initrd-find-nixos-closure.service
      # (the latter races us in 26.05+ and inspects /sysroot/nix/store before
      # the overlay exists - so we must complete before it starts).
      wantedBy = [ "initrd-fs.target" "initrd-find-nixos-closure.service" ];
      before = [ "initrd-fs.target" "initrd-find-nixos-closure.service" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = "/sysroot/.nix-lower/store";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Mirror stdout/stderr to the kernel.log file (ttyS1) so failures
        # are visible before we have journalctl. Drop after stabilizing.
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        set -eu

        STORE_DISK=0
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.store_disk=1) STORE_DISK=1 ;;
          esac
        done

        mkdir -p /sysroot/.nix-backing
        if [ "$STORE_DISK" = "1" ]; then
          mount /dev/vda /sysroot/.nix-backing
        else
          mount -t tmpfs tmpfs /sysroot/.nix-backing
        fi
        mkdir -p \
          /sysroot/.nix-backing/store-upper \
          /sysroot/.nix-backing/store-work \
          /sysroot/.nix-backing/var

        mkdir -p /sysroot/nix/store
        mount -t overlay overlay /sysroot/nix/store \
          -o "lowerdir=/sysroot/.nix-lower/store,upperdir=/sysroot/.nix-backing/store-upper,workdir=/sysroot/.nix-backing/store-work"

        mkdir -p /sysroot/nix/var
        mount --bind /sysroot/.nix-backing/var /sysroot/nix/var
      '';
    };

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

    # /nix/store overlay and /nix/var bind-mount are done by the
    # llmjail-store-overlay initrd service (above) which orders itself
    # after the 9p lower layer is mounted.
    fileSystems."/llmjail-env" = {
      device = "envfs";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "cache=none" "ro" ];
      neededForBoot = true;
    };

    networking.useDHCP = false;
    networking.nameservers = [ "10.0.2.3" ];
    networking.firewall.enable = false;

    # nixos-26.05 + systemd-networkd auto-enables resolved, which inserts
    # "resolve" before "dns" in nsswitch and steals all hostname lookups
    # to its own stub on 127.0.0.53/54. That bypasses our dnsmasq on
    # 127.0.0.1, so nftset additions never happen. Force it off so glibc
    # falls back to the "dns" NSS module and reads /etc/resolv.conf.
    services.resolved.enable = false;

    # Gives interface name "eth0"
    networking.usePredictableInterfaceNames = false;
    systemd.network = {
      enable = true;
      networks."eth0" = {
        matchConfig.Name = "eth0";
        networkConfig.DHCP = "yes";
      };
      wait-online.enable = true;
    };

    users.users.user = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/user";
      shell = pkgs.bash;
      extraGroups = [ "tty" "dialout" "systemd-journal" ];
    };

    users.mutableUsers = true;
    systemd.services.llmjail-set-user-uid = {
      wantedBy = [ "llmjail-mounts.service" ];
      before = [ "llmjail-mounts.service" ];
      script = ''
        USER_UID=""
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.user_uid=*) USER_UID="''${arg#llmjail.user_uid=}" ;;
          esac
        done
        if [[ -n "$USER_UID" && "$USER_UID" -ge 1000 ]] && ! ${pkgs.getent}/bin/getent passwd "$USER_UID"; then
          ${pkgs.shadow}/bin/usermod -u "$USER_UID" user
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

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

          echo "Mounting $tag -> $mpath ($mode)"
          ${pkgs.coreutils}/bin/mkdir -p "$mpath"

          OPTS="trans=virtio,version=9p2000.L,cache=mmap"
          if [ "$mode" = "ro" ]; then
            OPTS="$OPTS,ro"
          elif [ "$mode" = "ro-nocache" ]; then
            OPTS="trans=virtio,version=9p2000.L,cache=none,ro"
          fi
          ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$mpath" -o "$OPTS"

          # Fix ownership for paths under /home/user
          case "$mpath" in
            /home/user|/home/user/*)
              ${pkgs.coreutils}/bin/chown user:users "$mpath" 2>/dev/null || true
              ;;
          esac
        done

        # Copy dotfiles provided via envfs (can't mount individual files via
        # 9p). Currently just .gitconfig, placed there by mkRunner.
        for src in /llmjail-env/.*; do
          [ -f "$src" ] || continue
          name="''${src##*/}"
          ${pkgs.coreutils}/bin/cp "$src" "/home/user/$name"
          ${pkgs.coreutils}/bin/chown user:users "/home/user/$name"
        done

        # Apply --mask patterns to user-data roots.
        # Bind-mounts an empty dir/file over each matched path so the
        # tool sees no contents (the name stays visible, only contents
        # are hidden). Static: applied once at boot. New files matching
        # the pattern after boot are NOT masked.
        if [ -s /llmjail-env/mask-patterns ] && [ -s /llmjail-env/mask-roots ]; then
          ${pkgs.coreutils}/bin/mkdir -p /run/llmjail-mask/empty-dir
          : > /run/llmjail-mask/empty-file
          ${pkgs.coreutils}/bin/chmod 0555 /run/llmjail-mask/empty-dir
          ${pkgs.coreutils}/bin/chmod 0444 /run/llmjail-mask/empty-file

          while IFS= read -r root || [ -n "$root" ]; do
            [ -z "$root" ] && continue
            [ -d "$root" ] || continue

            EXPR=()
            while IFS= read -r p || [ -n "$p" ]; do
              [ -z "$p" ] && continue
              if [ ''${#EXPR[@]} -gt 0 ]; then EXPR+=("-o"); fi
              case "$p" in
                */*) EXPR+=("-path" "$root/$p") ;;
                *)   EXPR+=("-name" "$p") ;;
              esac
            done < /llmjail-env/mask-patterns

            [ ''${#EXPR[@]} -eq 0 ] && continue

            # -xdev keeps the walk inside the root's filesystem (the
            # 9p mount), so we never wander into nested mounts.
            # -prune skips descent into matched dirs (cheap on big trees).
            ${pkgs.findutils}/bin/find "$root" -xdev \( "''${EXPR[@]}" \) -prune -print0 |
              while IFS= read -r -d "" target; do
                [ "$target" = "$root" ] && continue
                # Skip symlinks: mount --bind resolves the link, and we don't
                # want to mask the target instead of the link itself.
                # Notify the user and skip.
                if [ -L "$target" ]; then
                  echo "mask: skipping symlink (not masked): $target"
                  continue
                fi
                if [ -d "$target" ]; then
                  ${pkgs.util-linux}/bin/mount --bind /run/llmjail-mask/empty-dir "$target"
                elif [ -e "$target" ]; then
                  ${pkgs.util-linux}/bin/mount --bind /run/llmjail-mask/empty-file "$target"
                else
                  continue
                fi
                ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$target"
                echo "masked: $target"
              done
          done < /llmjail-env/mask-roots
        fi
      '';
    };

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

        # Must run before dnsmasq so allowed_ips set exists when
        # dnsmasq populates it on first DNS resolution.
        ${pkgs.nftables}/bin/nft -f - <<'NFTEOF'
        table inet llmjail_filter {
          # Populated by dnsmasq --nftset on each successful DNS resolution.
          # HTTP/HTTPS is only allowed to IPs that appear here, blocking
          # direct hardcoded-IP connections that bypass DNS filtering.
          # Plain set (no `flags interval`) so dnsmasq can add individual
          # /32 entries - interval sets reject single addresses in some
          # nft/dnsmasq combos.
          set allowed_ips {
            type ipv4_addr
          }

          chain output {
            type filter hook output priority 0; policy drop;

            oifname "lo" accept

            ct state established,related accept

            udp dport { 67, 68 } accept

            ip daddr 10.0.2.3 udp dport 53 accept
            ip daddr 10.0.2.3 tcp dport 53 accept

            ip daddr @allowed_ips tcp dport { 80, 443 } accept

            log prefix "llmjail-drop: " drop
          }
        }
        NFTEOF

        DNSMASQ_CONF="/etc/dnsmasq-llmjail.conf"
        {
          echo "no-resolv"
          echo "no-hosts"
          echo "listen-address=127.0.0.1"
          echo "bind-interfaces"

          # Forward allowed domains to QEMU's DNS; populate nftables set
          # on each successful resolution so the IP becomes reachable.
          if [ -f /llmjail-env/allowed-domains ]; then
            while IFS= read -r domain || [ -n "$domain" ]; do
              [ -z "$domain" ] && continue
              echo "server=/$domain/10.0.2.3"
              echo "nftset=/$domain/4#inet#llmjail_filter#allowed_ips"
            done < /llmjail-env/allowed-domains
          fi

          # No default upstream - unmatched queries get REFUSED
        } > "$DNSMASQ_CONF"

        # --user=root keeps CAP_NET_ADMIN for the lifetime of the daemon;
        # dnsmasq otherwise drops to "nobody" and nftset updates fail
        # silently. We're inside a jail VM, root for dnsmasq is fine.
        # --log-queries surfaces the nftset add events in journalctl so
        # future filter regressions are debuggable from the guest.
        ${pkgs.dnsmasq}/bin/dnsmasq \
          --conf-file="$DNSMASQ_CONF" \
          --pid-file=/run/dnsmasq-llmjail.pid \
          --user=root \
          --log-queries=extra \
          --log-facility=-

        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        echo "Network filtering enabled with $(${pkgs.coreutils}/bin/wc -l < /llmjail-env/allowed-domains) allowed domain(s)."
      '';
    };

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

          # nixpkgs zsh bakes a global zshenv into its own store path, so a
          # forwarded host $SHELL sources it even though the guest has no
          # /etc/zshenv. Unless this guard is set, that zshenv sources the
          # guest's /etc/set-environment in every `zsh -c`, which REPLACES
          # PATH with the guest session default - silently dropping the
          # /host-sw, /host-user-sw, and dev-env entries above. The bash
          # login path (/etc/profile) honors the same guard.
          export __NIXOS_SET_ENVIRONMENT_DONE=1

          if [ -f /llmjail-env/dev-env ]; then
            # dev-env is output of `nix print-dev-env` - a bash script setting PATH, etc.
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

    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@ttyS1".enable = false;
    systemd.services."getty@tty1".enable = false;

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.settings.sandbox = false;

    # Pin nixpkgs within the VM
    nix.registry.nixpkgs.flake = nixpkgs;
    nix.nixPath = [ "nixpkgs=${pkgs.path}" ];

    system.stateVersion = "24.11";
  };
}
