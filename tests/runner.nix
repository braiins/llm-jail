# The shell tool execs the host's $SHELL (forwarded by the runner), so
# pointing $SHELL at a probe script makes the guest run the probe instead of
# an interactive shell. The probe writes what it sees into /workspace and
# exits, which powers the VM off; the check then asserts on those files.
{ pkgs, shell }:

let
  probe = pkgs.writeShellScript "llmjail-probe" ''
    findmnt() { ${pkgs.util-linux}/bin/findmnt -n -o FSTYPE,SOURCE,OPTIONS "$1"; }
    findmnt / > root
    findmnt /nix/store > store
    findmnt /workspace > share
  '';

  # expect is a list of "file:regex" pairs matched against the probe output.
  mkRunnerTest =
    {
      name,
      runner,
      runnerArgs ? [ ],
      expect,
    }:
    pkgs.runCommand "llmjail-runner-${name}"
      {
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        export HOME=$TMPDIR/home SHELL=${probe}
        mkdir -p "$HOME" "$TMPDIR/workspace"
        # The builder's uid (nixbld*, 30001+) is already taken by the guest's
        # own nixbld users, so llmjail-set-user-uid keeps `user` at 1000 and
        # the probe could not write to a 0755 workspace owned by the builder.
        chmod 0777 "$TMPDIR/workspace"
        cd "$TMPDIR/workspace"

        fail() {
          echo "FAIL: $1 (after $((SECONDS - start))s)"
          echo "--- console ---"
          cat "$TMPDIR/console.log"
          exit 1
        }

        start=$SECONDS
        timeout 90 ${runner}/bin/llm-jail-shell ${pkgs.lib.escapeShellArgs runnerArgs} \
          </dev/null >"$TMPDIR/console.log" 2>&1 \
          || fail "runner exited with $?"
        echo "runner took $((SECONDS - start))s"

        for pair in ${pkgs.lib.escapeShellArgs expect}; do
          file=''${pair%%:*} regex=''${pair#*:}
          [ -f "$file" ] || fail "probe wrote no $file"
          grep -Eq "$regex" "$file" || fail "$file is '$(cat "$file")', expected /$regex/"
          echo "ok: $file matches /$regex/"
        done

        touch $out
      '';

  # The overlay is mounted in the initrd, so its options keep the /sysroot
  # prefix.
  storeOverlay = "store:^overlay overlay .*upperdir=/sysroot/\\.nix-upper/store";
in
{
  runner-tmpfs = mkRunnerTest {
    name = "tmpfs";
    runner = shell;
    expect = [
      "root:^tmpfs rootfs rw"
      storeOverlay
      "share:^9p "
    ];
  };

  runner-disk = mkRunnerTest {
    name = "disk";
    runner = shell;
    runnerArgs = [
      "--disk"
      "1"
    ];
    expect = [
      "root:^ext4 /dev/vda rw"
      storeOverlay
      "share:^9p "
    ];
  };

  runner-virtiofs = mkRunnerTest {
    name = "virtiofs";
    runner = shell.virtiofs;
    runnerArgs = [
      "--disk"
      "1"
    ];
    expect = [
      "root:^ext4 /dev/vda rw"
      storeOverlay
      "share:^virtiofs "
    ];
  };
}
