{ config, lib, pkgs, nixpkgs, ... }:

{
  imports = [
    ./services/store-overlay.nix
    ./services/mounts.nix
    ./services/net-filter.nix
    ./services/winsize.nix
    ./services/tool.nix
  ];

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
  boot.kernelModules = [ "nf_tables" "virtio_console" ];

  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "size=2G" ];
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

  documentation.enable = false;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.sandbox = false;

  # Pin nixpkgs within the VM
  nix.registry.nixpkgs.flake = nixpkgs;
  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];

  system.stateVersion = "24.11";
}
