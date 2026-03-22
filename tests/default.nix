{ pkgs, claude-code, codex-cli }:

let
  mkSmokeTest = { name, guestModule, toolBinary }:
    pkgs.testers.nixosTest {
      name = "llmjail-${name}-smoke";

      nodes.machine = { config, lib, pkgs, ... }: {
        imports = [ guestModule ];
        _module.args = { inherit claude-code codex-cli; };

        # Override 9p filesystem entries from common.nix — the test framework
        # provides its own root and /nix/store via virtualisation options.
        fileSystems."/nix/.ro-store" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=1M" ];
        };
        fileSystems."/llmjail-env" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=10M" ];
        };
        boot.initrd.postMountCommands = lib.mkForce "";

        # Provide mock envfs contents for the mounts service
        systemd.tmpfiles.rules = [
          "d /workspace 0755 user users -"
          "f /llmjail-env/env 0644 root root - HOME=/home/user"
          "f /llmjail-env/tool-args 0644 root root -"
        ];

        # Tool service will fail without credentials — prevent it from
        # blocking boot or powering off the VM.
        systemd.services.llmjail-tool = {
          wantedBy = lib.mkForce [];
          serviceConfig.ExecStopPost = lib.mkForce "";
        };

        virtualisation.memorySize = 1024;
      };

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("tool binary exists"):
            machine.succeed("test -x ${toolBinary}")

        with subtest("systemd services are defined"):
            machine.succeed("systemctl cat llmjail-mounts.service")
            machine.succeed("systemctl cat llmjail-tool.service")

        with subtest("mounts service handles no-mounts case"):
            machine.succeed("systemctl is-active llmjail-mounts.service")

        with subtest("tool service has correct configuration"):
            output = machine.succeed(
                "systemctl show llmjail-tool.service -p User,WorkingDirectory"
            )
            assert "User=user" in output, f"Expected User=user in: {output}"
            assert "WorkingDirectory=/workspace" in output, f"Expected WorkingDirectory=/workspace in: {output}"

        with subtest("common packages are available"):
            machine.succeed("which git")
            machine.succeed("which node")
            machine.succeed("which curl")
            machine.succeed("which ssh")

        with subtest("user account is configured"):
            machine.succeed("id user")
            machine.succeed("test -d /home/user")
            machine.succeed("getent passwd user | grep -q /home/user")

        with subtest("nix has flakes enabled"):
            machine.succeed("nix --version")
            machine.succeed("nix eval --expr 'true'")
      '';
    };

in
{
  claude-smoke = mkSmokeTest {
    name = "claude";
    guestModule = ../guests/claude.nix;
    toolBinary = "${claude-code}/bin/claude";
  };

  codex-smoke = mkSmokeTest {
    name = "codex";
    guestModule = ../guests/codex.nix;
    toolBinary = "${codex-cli}/bin/codex";
  };
}
