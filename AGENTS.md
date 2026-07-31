# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
nix build .#claude              # Build the runner script
nix run .#claude -- --help      # Show CLI usage
nix flake check                 # Validate flake structure
```

End-to-end test (needs a terminal and a prior in-jail login - run `nix run .#claude` once and complete the login flow, which persists credentials in `~/.config/llm-jail/claude/default`):
```bash
nix run .#claude -- --dangerous -- -p "Write hello to /workspace/hello.txt" --max-turns 3
```

After changes to guest NixOS config, rebuilds are fast (only systemd units regenerate). Changes to `flake.nix` inputs or `writeShellApplication` trigger full rebuilds.

## Architecture

This is a Nix flake that runs coding agents inside QEMU microVMs with hardware-level isolation. No disk images - the guest boots on tmpfs with the host's `/nix/store` shared read-only via 9p. An overlayfs covers `/nix/store` and `/nix/var` is bind-mounted from the same backing volume so build artifacts land on disk (not root tmpfs) when `--store-disk` is used.

**Data flow:** `flake.nix` iterates `tools.nix`, builds a NixOS guest system per tool, wraps each with `lib/mkRunner.nix` into a QEMU launcher script.

**Host side (`lib/mkRunner.nix`):** A `writeShellApplication` that parses CLI args at runtime, writes env vars and tool args to a temp dir, sets up 9p virtfs mounts, optionally creates a store disk image, and launches QEMU with direct kernel boot. QEMU's stdout (the guest console stream) is not wired to the terminal directly but piped through `pv -q -B 64M`, which drains it eagerly into a 64MB buffer and writes to the tty as it becomes writable - QEMU's virtconsole silently drops guest output when the host fd can't absorb a burst (see Key Constraints), which corrupted TUI frames on busy terminals. On NixOS hosts, `/run/current-system/sw` and `/etc/profiles/per-user/$USER` are auto-mounted so host packages are available in the guest.

**Guest side (`guests/common.nix` + `guests/claude.nix`):** Minimal NixOS. Three systemd services: `llmjail-mounts` parses kernel cmdline (`llmjail.mounts=tag:path:mode,...`) to mount user directories via 9p; `llmjail-winsize` reads `cols rows` lines from a dedicated virtio-serial port (`/dev/virtio-ports/llmjail.winsize`) and applies them via `stty` on `/dev/hvc0` so the TUI receives SIGWINCH on host terminal resize; then `llmjail-tool` runs the actual tool on `/dev/hvc0` (virtio-console, for throughput — the 16550A serial `ttyS0` was too slow for TUI redraws). `ExecStopPost` powers off the VM when the tool exits. The host runner forwards SIGWINCH into the winsize port via a FIFO→unix-socket→`virtserialport` bridge (`socat`), so no QEMU patches are required.

**Adding a new tool:** Add an entry to `tools.nix` pointing to a new guest module under `guests/`. The guest module imports `common.nix` and overrides `systemd.services.llmjail-tool.serviceConfig.ExecStart`.

## Key Constraints

- **QEMU's virtconsole silently drops guest output on EAGAIN.** `hw/char/virtio-console.c` throttles and retries for `virtserialport`, but for `virtconsole` it discards the unwritten remainder of a burst when the host-side chardev (stdio) can't absorb it immediately - an upstream-known limitation (throttling consoles could spin the guest's hvc printk path), still unfixed as of QEMU 11.0.1. TUI redraws burst whole frames (100KB+); a momentarily-full host pty (64KB) then loses part of the frame, showing up as stale text and unpainted backgrounds. Never wire the console chardev to a backpressuring fd without a pump in between: pipe QEMU's stdout through `pv -q -B 64M`, which reads it eagerly (buffer capped at 64MB, then output freezes rather than corrupts) and writes to the terminal as it becomes writable. `pv` is used rather than `mbuffer` because mbuffer holds partial blocks until full or EOF, which would delay interactive echo.

- **9p can't mount single files.** `.gitconfig` is copied into the envfs temp dir on the host and copied out to `$HOME` by the guest mounts service.
- **Tool args use null-separated files** (`tool-args`) to preserve argument boundaries through the host→guest boundary. Don't use env vars for args with spaces.
- **`/run` is remounted by systemd in stage 2**, so guest 9p mounts must not go under `/run`. The envfs mount is at `/llmjail-env`.
- **`writeShellApplication` runs shellcheck.** Avoid `compgen` and other builtins that shellcheck flags. Use `env | grep` patterns instead.
- **`/nix/store` uses an overlay; `/nix/var` is bind-mounted from the same backing.** By default both use a tmpfs at `/.nix-backing`. Use `--store-disk SIZE` to use a disk-backed ext4 image instead, giving space for large builds and intermediate artifacts in `/nix/var/nix/builds/`. Dev shell environments can alternatively be captured on the host and sourced in the guest: `nix print-dev-env` (opt-in with `--nix-env`) for plain nix flakes/shells, or `devenv direnv-export` (opt-in with `--devenv`, requires `--same-path`) for devenv.sh projects — both write to the same `dev-env` file the guest sources. `devenv direnv-export` (undocumented but stable - it's what devenv's own maintained direnvrc uses internally to import a devenv shell into direnv's already-running shell) was chosen over `devenv shell` specifically because its output has no trailing `exec` to worry about, unlike `devenv shell`'s generated rcfile which always ends by replacing the sourcing shell. devenv still bakes the workspace's absolute host path into `DEVENV_ROOT`/`DEVENV_DOTFILE`/`DEVENV_STATE`, which `--same-path` keeps valid in the guest.
- **The 9p store mount and overlay backing live outside `/nix`.** The host store is mounted read-only at `/.nix-lower/store` (used as the overlay lower layer directly - overlayfs does not reliably cross submount boundaries, so the lower must be the mounted filesystem itself). The overlay backing (ext4 or tmpfs) is at `/.nix-backing`. Keep this in mind when debugging mount issues inside the guest.
- **Tool state is jail-private.** Each tool's state lives in a host dir `~/.config/llm-jail/<tool>/<profile>` (never the host tool's own config), mounted read-write at `/home/user/<configDirName>`. The tool is relocated into it via its native env var (`configEnvVar` in `tools.nix`, e.g. `CLAUDE_CONFIG_DIR` or `AUTOLITH_HOME`), which `mkRunner.nix` writes into the env file consumed by `llmjail-tool.service`. A tool whose state spans several dirs (opencode's XDG layout, or Autolith's XDG-derived state/data/cache dirs) points the remaining dirs into the same mount via exports in its launcher wrapper (see `guests/opencode.nix`). A tool that keeps no state (the debug shell) simply omits `configDirName`/`configEnvVar` and gets no config mount or `--config-dir`/`--profile` flags. Never mount a directory the host tool also uses read-write - a jailed agent could plant hooks/settings the host tool would execute.
