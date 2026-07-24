{ pkgs, nixpkgs, claude-code, codex-cli, copilot-cli, opencode, autolith ? null }:

let
  mkSmokeTest = { name, guestModule, toolBinary }:
    pkgs.testers.nixosTest {
      name = "llmjail-${name}-smoke";

      nodes.machine = { lib, ... }: {
        imports = [ guestModule ];
        _module.args = { inherit nixpkgs claude-code codex-cli copilot-cli opencode autolith; };

        # Override 9p filesystem entries from common.nix - the test framework
        # provides its own root and /nix/store via virtualisation options.
        fileSystems."/.nix-lower/store" = lib.mkForce {
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
          "f /llmjail-env/allowed-domains 0644 root root -"
        ];

        # Tool service will fail without credentials - prevent it from
        # blocking boot or powering off the VM.
        systemd.services.llmjail-tool = {
          wantedBy = lib.mkForce [ ];
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
            machine.succeed("systemctl cat llmjail-net-filter.service")
            machine.succeed("systemctl cat llmjail-tool.service")
            machine.succeed("systemctl cat llmjail-winsize.service")

        with subtest("winsize service is running"):
            machine.succeed("systemctl is-active llmjail-winsize.service")

        with subtest("mounts service handles no-mounts case"):
            machine.succeed("systemctl is-active llmjail-mounts.service")

        with subtest("tool service has correct configuration"):
            output = machine.succeed(
                "systemctl show llmjail-tool.service -p User,WorkingDirectory"
            )
            assert "User=user" in output, f"Expected User=user in: {output}"
            assert "WorkingDirectory=!/workspace" in output, f"Expected WorkingDirectory=!/workspace in: {output}"

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

        with subtest("nixpkgs is pinned in registry and NIX_PATH"):
            machine.succeed("cat /etc/nix/registry.json | grep nixpkgs")
            machine.succeed("nix-instantiate --eval -E '<nixpkgs>'")

        with subtest("user can read kernel journal"):
            machine.succeed("su - user -c 'journalctl -k --no-pager -n 1'")
      '';
    };

  netFilterTest = pkgs.testers.nixosTest {
    name = "llmjail-net-filter-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/claude.nix ];
      _module.args = { inherit nixpkgs claude-code codex-cli; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
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

      # Enable net filtering via kernel cmdline
      boot.kernelParams = lib.mkAfter [ "llmjail.net_filter=1" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f+ /llmjail-env/allowed-domains 0644 root root - api.anthropic.com"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("llmjail-net-filter.service")

      with subtest("dnsmasq is running"):
          machine.succeed("pgrep dnsmasq")

      with subtest("resolv.conf points to localhost"):
          output = machine.succeed("cat /etc/resolv.conf")
          assert "127.0.0.1" in output, f"Expected 127.0.0.1 in resolv.conf: {output}"

      with subtest("nftables rules are loaded"):
          output = machine.succeed("nft list ruleset")
          assert "llmjail_filter" in output, f"Expected llmjail_filter in nft rules: {output}"

      with subtest("dnsmasq config has allowed domain"):
          output = machine.succeed("cat /etc/dnsmasq-llmjail.conf")
          assert "api.anthropic.com" in output, f"Expected api.anthropic.com in dnsmasq config: {output}"

      with subtest("blocked domain fails to resolve"):
          machine.fail("getent hosts evil.example.com")
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

  copilot-smoke = mkSmokeTest {
    name = "copilot";
    guestModule = ../guests/copilot.nix;
    toolBinary = pkgs.lib.getExe copilot-cli;
  };

  opencode-smoke = mkSmokeTest {
    name = "opencode";
    guestModule = ../guests/opencode.nix;
    toolBinary = pkgs.lib.getExe opencode;
  };

  net-filter-smoke = netFilterTest;

  shell-smoke = mkSmokeTest {
    name = "shell";
    guestModule = ../guests/shell.nix;
    toolBinary = pkgs.lib.getExe pkgs.bashInteractive;
  };

  dev-env-smoke =
    let
      # pkgs.writeText supports multi-line content; use C in tmpfiles.rules to
      # copy these store paths into /llmjail-env, bypassing the neededForBoot
      # ordering issue that a oneshot service would have.
      envFile = pkgs.writeText "dev-env-smoke-env" ''
        HOME=/home/user
        SHELL=${pkgs.bashInteractive}/bin/bash
      '';
      devEnvContent = pkgs.writeText "dev-env-smoke-dev-env" ''
        export LLMJAIL_TEST_VAR=hello
      '';
      mockTool = pkgs.writeShellScript "dev-env-checker" ''
        echo "LLMJAIL_TEST_VAR=''${LLMJAIL_TEST_VAR:-<unset>}"
      '';
    in
    pkgs.testers.nixosTest {
      name = "llmjail-dev-env-smoke";

      nodes.machine = { lib, ... }: {
        imports = [ ../guests/shell.nix ];
        _module.args = { inherit nixpkgs; };

        llmjail.toolBinary = lib.mkForce mockTool;

        fileSystems."/.nix-lower/store" = lib.mkForce {
          device = "tmpfs"; fsType = "tmpfs"; options = [ "size=1M" ];
        };
        fileSystems."/llmjail-env" = lib.mkForce {
          device = "tmpfs"; fsType = "tmpfs"; options = [ "size=10M" ];
        };
        boot.initrd.postMountCommands = lib.mkForce "";

        # systemd-tmpfiles-setup runs in sysinit.target, before all application
        # services.  The d entry creates /llmjail-env unconditionally (regardless
        # of whether the tmpfs mount succeeded), and C copies multi-line content
        # from Nix store paths without needing a separate oneshot service.
        systemd.tmpfiles.rules = [
          "d /llmjail-env 0755 root root -"
          "C /llmjail-env/env 0644 root root - ${envFile}"
          "C /llmjail-env/dev-env 0644 root root - ${devEnvContent}"
          "f /llmjail-env/tool-args 0644 root root -"
          "f /llmjail-env/allowed-domains 0644 root root -"
          "d /workspace 0755 user users -"
        ];

        # Redirect I/O to journal, disable poweroff, and clear TTY settings.
        # TTYPath=/dev/hvc0 and TTYReset=true survive the lib.mkForce on
        # StandardInput because they are separate serviceConfig keys. If not
        # cleared, systemd resets /dev/hvc0 on service exit, disrupting the
        # test driver's backdoor shell which runs on the same device.
        systemd.services.llmjail-tool = {
          serviceConfig = {
            StandardInput = lib.mkForce "null";
            StandardOutput = lib.mkForce "journal";
            StandardError = lib.mkForce "journal";
            ExecStopPost = lib.mkForce "";
            TTYPath = lib.mkForce "";
            TTYReset = lib.mkForce false;
          };
        };

        virtualisation.memorySize = 1024;
      };

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("dev-env variable reaches the tool binary"):
            machine.wait_until_succeeds(
                "journalctl -u llmjail-tool | grep 'LLMJAIL_TEST_VAR=hello'",
                timeout=30
            )
      '';
    };
  completion-smoke =
    let
      envFile = pkgs.writeText "completion-smoke-env" ''
        HOME=/home/user
        SHELL=${pkgs.bashInteractive}/bin/bash
      '';
      devEnvScript = pkgs.writeText "completion-dev-env" ''
        # Enable programmable completion (off by default in non-interactive bash)
        shopt -s progcomp

        # Pattern 1: wordlist completion (exercises: complete -W)
        complete -W "start stop restart status" _llmjail_test_svc

        # Pattern 2: function-based completion (exercises: complete -F, compgen -W)
        _llmjail_test_fn() {
          local cur="''${COMP_WORDS[COMP_CWORD]:-}"
          COMPREPLY=( $(compgen -W "build test deploy --help" -- "$cur") )
        }
        complete -F _llmjail_test_fn _llmjail_test_app

        # Pattern 3: modify options for a registered completion (exercises: compopt)
        compopt -o nospace _llmjail_test_svc

        # Verify compgen produces expected output, not just that it doesn't crash
        RESULT=$(compgen -W "build test deploy --help" -- "dep")
        [ "$RESULT" = "deploy" ]

        export COMPLETION_BUILTINS_OK=1
      '';
      mockTool = pkgs.writeShellScript "completion-checker" ''
        echo "COMPLETION_BUILTINS_OK=''${COMPLETION_BUILTINS_OK:-<unset>}"
      '';
    in
    pkgs.testers.nixosTest {
      name = "llmjail-completion-smoke";

      nodes.machine = { lib, ... }: {
        imports = [ ../guests/shell.nix ];
        _module.args = { inherit nixpkgs; };

        llmjail.toolBinary = lib.mkForce mockTool;

        fileSystems."/.nix-lower/store" = lib.mkForce {
          device = "tmpfs"; fsType = "tmpfs"; options = [ "size=1M" ];
        };
        fileSystems."/llmjail-env" = lib.mkForce {
          device = "tmpfs"; fsType = "tmpfs"; options = [ "size=10M" ];
        };
        boot.initrd.postMountCommands = lib.mkForce "";

        systemd.tmpfiles.rules = [
          "d /llmjail-env 0755 root root -"
          "C /llmjail-env/env 0644 root root - ${envFile}"
          "C /llmjail-env/dev-env 0644 root root - ${devEnvScript}"
          "f /llmjail-env/tool-args 0644 root root -"
          "f /llmjail-env/allowed-domains 0644 root root -"
          "d /workspace 0755 user users -"
        ];

        systemd.services.llmjail-tool = {
          serviceConfig = {
            StandardInput = lib.mkForce "null";
            StandardOutput = lib.mkForce "journal";
            StandardError = lib.mkForce "journal";
            ExecStopPost = lib.mkForce "";
            TTYPath = lib.mkForce "";
            TTYReset = lib.mkForce false;
          };
        };

        virtualisation.memorySize = 1024;
      };

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("completion builtins are available in the dev-env sourcing context"):
            machine.wait_until_succeeds(
                "journalctl -u llmjail-tool | grep 'COMPLETION_BUILTINS_OK=1'",
                timeout=30
            )
      '';
    };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
  autolith-smoke = mkSmokeTest {
    name = "autolith";
    guestModule = ../guests/autolith.nix;
    toolBinary = pkgs.lib.getExe autolith;
  };
}
