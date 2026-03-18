{ config, lib, pkgs, ... }:

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
    boot.kernelParams = [ "console=ttyS0" ];
    boot.initrd.availableKernelModules = [
      "9p" "9pnet_virtio"
      "virtio_pci" "virtio_blk" "virtio_net" "virtio_rng"
      "overlay"
    ];

    boot.initrd.supportedFilesystems = [ "ext4" ];

    # Create nix store overlay dirs; optionally use a virtio disk for more space
    boot.initrd.postMountCommands = ''
      STORE_DISK=0
      for arg in $(cat /proc/cmdline); do
        case "$arg" in
          llmjail.store_disk=1) STORE_DISK=1 ;;
        esac
      done

      mkdir -p $targetRoot/nix/.store-disk
      if [ "$STORE_DISK" = "1" ]; then
        mount /dev/vda $targetRoot/nix/.store-disk
      else
        mount -t tmpfs tmpfs $targetRoot/nix/.store-disk
      fi
      mkdir -p $targetRoot/nix/.store-disk/upper $targetRoot/nix/.store-disk/work
    '';

    # ── Filesystems ───────────────────────────────────────────────────────
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=2G" ];
    };

    # Mount host nix store read-only as lower layer, then overlay with tmpfs upper
    # so the guest can write new store paths (needed for nix build/develop)
    fileSystems."/nix/.ro-store" = {
      device = "nix-store";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "cache=loose" "ro" ];
      neededForBoot = true;
    };

    fileSystems."/nix/store" = {
      device = "overlay";
      fsType = "overlay";
      options = [
        "lowerdir=/nix/.ro-store"
        "upperdir=/nix/.store-disk/upper"
        "workdir=/nix/.store-disk/work"
      ];
      depends = [ "/nix/.ro-store" ];
      neededForBoot = true;
    };

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

    # ── User ──────────────────────────────────────────────────────────────
    users.users.user = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/user";
      shell = pkgs.bash;
      extraGroups = [ "tty" "dialout" ];
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
    ];

    # ── llmjail-tool service ────────────────────────────────────────────
    systemd.services.llmjail-tool = let
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

        cd /workspace
        exec ${config.llmjail.toolBinary} "''${ARGS[@]}"
      '';
    in {
      description = "llmjail tool runner";
      wantedBy = [ "multi-user.target" ];
      after = [ "llmjail-mounts.service" "network-online.target" ];
      wants = [ "llmjail-mounts.service" "network-online.target" ];
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
    systemd.services."getty@tty1".enable = false;

    documentation.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    nix.settings.sandbox = false;
    systemd.services.systemd-networkd-wait-online.enable = false;

    system.stateVersion = "24.11";
  };
}
