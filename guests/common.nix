{ config, lib, pkgs, hostBackend, nixpkgs-rolling, ... }:

let
  useVz = hostBackend == "vz";
  shareFileSystem = if useVz then "virtiofs" else "9p";
  shareOptions =
    if useVz
    then [ "ro" ]
    else [ "trans=virtio" "version=9p2000.L" "cache=loose" "msize=1048576" "ro" ];
in
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
    boot.kernelParams = [
      (if useVz then "console=hvc0"
       else if pkgs.stdenv.hostPlatform.isAarch64 then "console=ttyAMA0"
       else "console=ttyS1")
    ];
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "virtio_rng"
    ] ++ lib.optionals useVz [ "virtiofs" ]
      ++ lib.optionals (!useVz) [ "9p" "9pnet_virtio" ];
    # Force-load overlay in initrd: availableKernelModules only allows
    # autoload, but the systemd-initrd path doesn't always trigger it for
    # `mount -t overlay`, so make it explicit.
    boot.initrd.kernelModules = [ "overlay" ];
    boot.kernelModules = [ "nf_tables" "virtio_console" ];

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

        ${lib.optionalString useVz ''
          # The host selected only regular, zero-byte, mode-0600 Nix lock
          # sidecars. Create OverlayFS whiteouts directly in the private upper
          # layer because VirtioFS denies guest metadata access to the lower
          # files themselves.
          if [ -s /sysroot/llmjail-env/store-lock-sidecars ]; then
            while IFS= read -r -d "" lock; do
              case "$lock" in
                */*|""|.|..)
                  echo "Invalid host-store lock basename: $lock" >&2
                  exit 1
                  ;;
                *.lock)
                  ${pkgs.coreutils}/bin/mknod \
                    "/sysroot/.nix-backing/store-upper/$lock" c 0 0
                  ;;
                *)
                  echo "Invalid host-store lock basename: $lock" >&2
                  exit 1
                  ;;
              esac
            done < /sysroot/llmjail-env/store-lock-sidecars
          fi
        ''}

        mkdir -p /sysroot/nix/store
        mount -t overlay overlay /sysroot/nix/store \
          -o "lowerdir=/sysroot/.nix-lower/store,upperdir=/sysroot/.nix-backing/store-upper,workdir=/sysroot/.nix-backing/store-work"

        ${lib.optionalString (!useVz) ''
          # QEMU's 9p mapping lets the guest inspect the host lock metadata,
          # so select and whiteout the exact sidecar shape through the overlay.
          find /sysroot/.nix-lower/store \
            -maxdepth 1 -type f -name '*.lock' -size 0 -perm 0600 -print |
            while IFS= read -r lock; do
              rm -f "/sysroot/nix/store/''${lock##*/}"
            done
        ''}

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
    # msize=1M: the 8KB default round-trips every read/readdir/stat beyond it,
    # crippling metadata-heavy tool I/O on large workspaces.
    fileSystems."/.nix-lower/store" = {
      device = "nix-store";
      fsType = shareFileSystem;
      options = shareOptions;
      neededForBoot = true;
    };

    # /nix/store overlay and /nix/var bind-mount are done by the
    # llmjail-store-overlay initrd service (above) which orders itself
    # after the 9p lower layer is mounted.
    # /llmjail-env: small config files plus the host nix db snapshot.
    # cache=loose (same as the store lower mount below): the share is
    # read-only and its files are immutable during the run, and loose
    # enables client readahead. cache=none serializes every 9p read
    # request-by-request, which made installing the multi-MB db snapshot
    # take seconds.
    fileSystems."/llmjail-env" = {
      device = "envfs";
      fsType = shareFileSystem;
      options = shareOptions;
      neededForBoot = true;
    };

    networking.useDHCP = false;
    networking.nameservers = lib.optionals (!useVz) [ "10.0.2.3" ];
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

    systemd.services.llmjail-vz-resolver = lib.mkIf useVz {
      description = "Install the VZ NAT resolver from DHCP";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "llmjail-net-filter.service" "llmjail-tool.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        DNS_SERVER=""
        if [ -s /llmjail-env/host-dns ]; then
          IFS= read -r DNS_SERVER < /llmjail-env/host-dns
        else
          for lease in /run/systemd/netif/leases/*; do
            [ -f "$lease" ] || continue
            DNS_SERVER=$(${pkgs.gnused}/bin/sed -n 's/^DNS=//p' "$lease" \
              | ${pkgs.gawk}/bin/awk '{ print $1; exit }')
            [ -n "$DNS_SERVER" ] && break
          done
        fi
        if [ -z "$DNS_SERVER" ]; then
          echo "Could not determine the VZ NAT DNS server." >&2
          exit 1
        fi
        echo "nameserver $DNS_SERVER" > /etc/resolv.conf
      '';
    };

    users.users.user = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/user";
      shell = pkgs.bash;
      extraGroups = [ "tty" "dialout" "systemd-journal" ];
    };

    services.udev.extraRules = ''
      KERNEL=="vport*", SUBSYSTEM=="virtio-ports", ATTR{name}=="llmjail.supervisor", OWNER:="root", GROUP:="dialout", MODE:="0660"
      ${lib.optionalString useVz ''KERNEL=="hvc1", OWNER:="root", GROUP:="dialout", MODE:="0660"''}
    '';

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
        # Darwin login UIDs commonly start at 501. Avoid only the system UID
        # range below 500, and retain the collision check before changing it.
        if [[ -n "$USER_UID" && "$USER_UID" -ge 500 ]] && ! ${pkgs.getent}/bin/getent passwd "$USER_UID"; then
          ${pkgs.shadow}/bin/usermod -u "$USER_UID" user
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

    # Parses kernel cmdline for llmjail.mounts=tag0:/path:rw,tag1:/path:ro,...
    # and mounts each entry through the selected host sharing backend.
    systemd.services.llmjail-mounts = {
      description = "Mount llmjail host shares from kernel cmdline";
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

          ${if useVz then ''
            OPTS=""
            if [ "$mode" = "ro" ] || [ "$mode" = "ro-nocache" ]; then
              OPTS="ro"
            fi
            if [ -n "$OPTS" ]; then
              ${pkgs.util-linux}/bin/mount -t virtiofs "$tag" "$mpath" -o "$OPTS"
            else
              ${pkgs.util-linux}/bin/mount -t virtiofs "$tag" "$mpath"
            fi
          '' else ''
            OPTS="trans=virtio,version=9p2000.L,cache=mmap,msize=1048576"
            if [ "$mode" = "ro" ]; then
              OPTS="$OPTS,ro"
            elif [ "$mode" = "ro-nocache" ]; then
              OPTS="trans=virtio,version=9p2000.L,cache=none,msize=1048576,ro"
            fi
            ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$mpath" -o "$OPTS"
          ''}

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
      after = [ "llmjail-mounts.service" "network-online.target" ]
        ++ lib.optionals useVz [ "llmjail-vz-resolver.service" ];
      wants = [ "network-online.target" ];
      before = [ "llmjail-tool.service" ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
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
          ${pkgs.systemd}/bin/systemd-notify --ready
          exit 0
        fi

        ALLOWED_DOMAINS=/llmjail-env/allowed-domains
        if [ -f /run/llmjail-allowed-domains ]; then
          ALLOWED_DOMAINS=/run/llmjail-allowed-domains
        fi

        # Make restarts replace both dnsmasq and the firewall state before the
        # tool starts.
        if [ -s /run/dnsmasq-llmjail.pid ]; then
          DNSMASQ_PID=$(cat /run/dnsmasq-llmjail.pid)
          kill "$DNSMASQ_PID" 2>/dev/null || true
          while kill -0 "$DNSMASQ_PID" 2>/dev/null; do
            sleep 0.05
          done
        fi
        ${pkgs.nftables}/bin/nft delete table inet llmjail_filter 2>/dev/null || true

        UPSTREAM_DNS=""
        if [ -s /llmjail-env/host-dns ]; then
          IFS= read -r UPSTREAM_DNS < /llmjail-env/host-dns
        else
          for lease in /run/systemd/netif/leases/*; do
            [ -f "$lease" ] || continue
            UPSTREAM_DNS=$(${pkgs.gnused}/bin/sed -n 's/^DNS=//p' "$lease" \
              | ${pkgs.gawk}/bin/awk '{ print $1; exit }')
            [ -n "$UPSTREAM_DNS" ] && break
          done
        fi
        if [ -z "$UPSTREAM_DNS" ]; then
          echo "Could not determine the VM NAT DNS server." >&2
          exit 1
        fi

        # Must run before dnsmasq so allowed_ips set exists when
        # dnsmasq populates it on first DNS resolution.
        ${pkgs.nftables}/bin/nft -f - <<NFTEOF
        table inet llmjail_filter {
          # Populated by dnsmasq --nftset on each successful DNS resolution.
          # HTTP/HTTPS is only allowed to IPs that appear here, blocking
          # direct hardcoded-IP connections that bypass DNS filtering.
          # Plain set without interval flags so dnsmasq can add individual
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

            ip daddr $UPSTREAM_DNS udp dport 53 meta skuid root accept
            ip daddr $UPSTREAM_DNS tcp dport 53 meta skuid root accept

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

          # Forward allowed domains to the VM NAT DNS server; populate nftables set
          # on each successful resolution so the IP becomes reachable.
          if [ -f "$ALLOWED_DOMAINS" ]; then
            while IFS= read -r domain || [ -n "$domain" ]; do
              [ -z "$domain" ] && continue
              echo "server=/$domain/$UPSTREAM_DNS"
              echo "nftset=/$domain/4#inet#llmjail_filter#allowed_ips"
            done < "$ALLOWED_DOMAINS"
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
          --keep-in-foreground \
          --log-queries=extra \
          --log-facility=- &
        DNSMASQ_PID=$!

        for _ in $(${pkgs.coreutils}/bin/seq 1 100); do
          [ -s /run/dnsmasq-llmjail.pid ] && break
          kill -0 "$DNSMASQ_PID" 2>/dev/null || wait "$DNSMASQ_PID"
          sleep 0.01
        done
        if [ ! -s /run/dnsmasq-llmjail.pid ]; then
          echo "dnsmasq did not become ready." >&2
          kill "$DNSMASQ_PID" 2>/dev/null || true
          wait "$DNSMASQ_PID" 2>/dev/null || true
          exit 1
        fi

        echo "nameserver 127.0.0.1" > /etc/resolv.conf

        echo "Network filtering enabled with $(${pkgs.coreutils}/bin/wc -l < "$ALLOWED_DOMAINS") allowed domain(s)."
        ${pkgs.systemd}/bin/systemd-notify --ready
        wait "$DNSMASQ_PID"
      '';
    };

    # Applies host-published terminal sizes to /dev/hvc0 via TIOCSWINSZ. tty
    # core handles the ioctl (driver-independent), so it delivers SIGWINCH to
    # hvc0's foreground pgrp just as it did for ttyS0.
    systemd.services.llmjail-winsize = {
      description = "Apply terminal size updates from host";
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
        PREV=""
        {
          ${if useVz then ''
          WINSIZE_DEVICE=""
          for arg in $(cat /proc/cmdline); do
            case "$arg" in
              llmjail.winsize_device=*) WINSIZE_DEVICE="''${arg#llmjail.winsize_device=}" ;;
            esac
          done
          if [ -z "$WINSIZE_DEVICE" ]; then
            echo "No VZ winsize device was configured." >&2
            exit 1
          fi
          while [ ! -e "$WINSIZE_DEVICE" ]; do
            sleep 0.1
          done
          ${pkgs.coreutils}/bin/cat "$WINSIZE_DEVICE"
        '' else ''
          while [ ! -e /dev/virtio-ports/llmjail.winsize ]; do
            sleep 0.1
          done
          ${pkgs.coreutils}/bin/cat /dev/virtio-ports/llmjail.winsize
          ''}
        } | while IFS=' ' read -r COLS ROWS; do
          [ -n "$COLS" ] && [ -n "$ROWS" ] || continue
          [ "$COLS $ROWS" = "$PREV" ] && continue
          PREV="$COLS $ROWS"
          ${pkgs.coreutils}/bin/stty cols "$COLS" rows "$ROWS" < /dev/hvc0 2>/dev/null || true
        done
      '';
    };

    # Initialize the guest nix db before the nix-daemon starts. Reuse an
    # existing database when a persistent store disk is attached so paths
    # realized by an earlier launch remain registered. Load the current
    # toplevel closure into that database in case the runner was upgraded.
    #
    # A new backing store is seeded from a snapshot of the host's
    # /nix/var/nix/db/db.sqlite (llmjail.nix_db_snapshot, taken by the
    # runner via `sqlite3 VACUUM INTO` and shipped through the envfs share).
    # Installing the file takes milliseconds, versus minutes for --load-db
    # of a big store. It falls back to the toplevel closure registration
    # dump (llmjail.nix_db_dump) when no snapshot is available. Mostly
    # copied from nixpkgs/nixos/modules/virtualisation/qemu-vm.nix.
    systemd.services.register-nix-paths = {
      unitConfig.DefaultDependencies = false;
      wantedBy = [ "sysinit.target" ];

      before = [
        "sysinit.target"
        "shutdown.target"
        "nix-daemon.socket"
        "nix-daemon.service"
      ];
      after = [
        "local-fs.target"
      ];
      conflicts = [
        "shutdown.target"
      ];
      restartIfChanged = false;
      script = ''
        NIX_DB_SNAPSHOT=""
        NIX_DB_DUMP=""
        for arg in $(cat /proc/cmdline); do
          case "$arg" in
            llmjail.nix_db_snapshot=*) NIX_DB_SNAPSHOT="''${arg#llmjail.nix_db_snapshot=}" ;;
            llmjail.nix_db_dump=*) NIX_DB_DUMP="''${arg#llmjail.nix_db_dump=}" ;;
          esac
        done

        NIX_DB=/nix/var/nix/db/db.sqlite
        ${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/db

        if [[ -s "$NIX_DB" ]]; then
          echo "Reusing persistent guest nix db"
          if [[ -n "$NIX_DB_DUMP" ]]; then
            echo "Registering current closure nix db dump ($NIX_DB_DUMP)"
            ${lib.getExe' config.nix.package "nix-store"} --load-db < "$NIX_DB_DUMP"
          fi
        elif [[ -n "$NIX_DB_SNAPSHOT" ]] && [[ -s "$NIX_DB_SNAPSHOT" ]]; then
          echo "Installing host nix db snapshot ($NIX_DB_SNAPSHOT)"
          ${pkgs.coreutils}/bin/rm -f /nix/var/nix/db/db.sqlite-wal /nix/var/nix/db/db.sqlite-shm
          ${pkgs.coreutils}/bin/install -m 0644 "$NIX_DB_SNAPSHOT" "$NIX_DB"
        elif [[ -n "$NIX_DB_DUMP" ]]; then
          echo "Loading closure nix db dump ($NIX_DB_DUMP)"
          ${lib.getExe' config.nix.package "nix-store"} --load-db < "$NIX_DB_DUMP"
        else
          echo "<4> No Nix db snapshot or dump specified, not initializing Nix db"
          exit 1
        fi

      '';
    };


    systemd.services.llmjail-tool =
      let
        launcher = pkgs.writeShellScript "launch-tool" ''
          # Source NixOS's global environment before modifying env vars. Must be sourced before
          # `set -u` since some variables such as `XDG_STATE_HOME` may not be set.
          source /etc/set-environment

          set -euo pipefail
          # Add host packages to PATH if available (NixOS host)
          if [ -d /host-user-sw/bin ]; then
            export PATH="$PATH:/host-user-sw/bin"
          fi
          if [ -d /host-sw/bin ]; then
            export PATH="$PATH:/host-sw/bin"
          fi

          # cd into the workspace before sourcing dev-env: devenv's shellHook
          # can do its own relative-path checks (e.g. per-language module
          # checks like `./foo/package.json`) that assume cwd is the project
          # root, not wherever WorkingDirectory left us (which is a static
          # "/workspace" that doesn't exist under --same-path).
          cd "''${WORKSPACE_DIR:-/workspace}"

          if [ -f /llmjail-env/dev-env ]; then
            # dev-env is `nix print-dev-env` or `devenv direnv-export`
            # output - a bash script setting PATH, etc. Neither is written
            # to tolerate nounset/errexit, so relax strict mode just for
            # the source.
            set +euo pipefail
            # shellcheck disable=SC1091
            source /llmjail-env/dev-env
            set -euo pipefail
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
          # after this are handled by the llmjail-winsize side-channel.
          if [ -n "''${COLUMNS:-}" ] && [ -n "''${LINES:-}" ]; then
            ${pkgs.coreutils}/bin/stty cols "$COLUMNS" rows "$LINES" 2>/dev/null || true
          fi

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
          WorkingDirectory = "-/workspace";
          EnvironmentFile = "/llmjail-env/env";
          StandardInput = "tty";
          StandardOutput = "tty";
          StandardError = "tty";
          TTYPath = "/dev/hvc0";
          TTYReset = true;
          TTYVHangup = false;
          ExecStart = "${launcher}";
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff --force --force";
        };
      };

    systemd.services."serial-getty@ttyS0".enable = false;
    systemd.services."serial-getty@ttyS1".enable = false;
    systemd.services."serial-getty@ttyAMA0".enable = false;
    systemd.services."serial-getty@hvc0".enable = false;
    systemd.services."getty@tty1".enable = false;
    systemd.services."getty@hvc0".enable = false;

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.settings.sandbox = false;

    # Pin nixpkgs within the VM.
    nix.registry.nixpkgs.to = {
      type = "path";
      path = nixpkgs-rolling;
    };
    nix.nixPath = [ "nixpkgs=${nixpkgs-rolling}" ];

    system.stateVersion = "24.11";
  };
}
