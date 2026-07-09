{ ... }:

{
  # Force-load overlay in initrd: availableKernelModules only allows
  # autoload, but the systemd-initrd path doesn't always trigger it for
  # `mount -t overlay`, so make it explicit.
  boot.initrd.kernelModules = [ "overlay" ];
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

  # Host nix store read-only (lower layer for the /nix/store overlay above).
  # Mounted outside /nix so it isn't hidden when the overlay covers /nix/store.
  # msize=1M: the 8KB default round-trips every read/readdir/stat beyond it,
  # crippling metadata-heavy tool I/O on large workspaces.
  fileSystems."/.nix-lower/store" = {
    device = "nix-store";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" "cache=loose" "msize=1048576" "ro" ];
    neededForBoot = true;
  };

  # /nix/store overlay and /nix/var bind-mount are done by the
  # llmjail-store-overlay initrd service (above) which orders itself
  # after the 9p lower layer is mounted.
  fileSystems."/llmjail-env" = {
    device = "envfs";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" "cache=none" "msize=1048576" "ro" ];
    neededForBoot = true;
  };
}
