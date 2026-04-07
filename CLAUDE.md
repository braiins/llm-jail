# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
nix build .#claude              # Build the runner script
nix run .#claude -- --help      # Show CLI usage
nix flake check                 # Validate flake structure
```

End-to-end test (needs a terminal and valid Claude credentials in `~/.claude`):
```bash
nix run .#claude -- --dangerous -- -p "Write hello to /workspace/hello.txt" --max-turns 3
```

After changes to guest NixOS config, rebuilds are fast (only systemd units regenerate). Changes to `flake.nix` inputs or `writeShellApplication` trigger full rebuilds.

## Architecture

This is a Nix flake that runs coding agents inside QEMU microVMs with hardware-level isolation. No disk images — the guest boots on tmpfs with the host's `/nix/store` shared read-only via 9p. An overlayfs covers `/nix/store` and `/nix/var` is bind-mounted from the same backing volume so build artifacts land on disk (not root tmpfs) when `--store-disk` is used.

**Data flow:** `flake.nix` iterates `tools.nix`, builds a NixOS guest system per tool, wraps each with `lib/mkRunner.nix` into a QEMU launcher script.

**Host side (`lib/mkRunner.nix`):** A `writeShellApplication` that parses CLI args at runtime, writes env vars and tool args to a temp dir, sets up 9p virtfs mounts, optionally creates a store disk image, and launches QEMU with direct kernel boot. On NixOS hosts, `/run/current-system/sw` and `/etc/profiles/per-user/$USER` are auto-mounted so host packages are available in the guest.

**Guest side (`guests/common.nix` + `guests/claude.nix`):** Minimal NixOS. Three systemd services: `llmjail-mounts` parses kernel cmdline (`llmjail.mounts=tag:path:mode,...`) to mount user directories via 9p; `llmjail-winsize` reads `cols rows` lines from a dedicated virtio-serial port (`/dev/virtio-ports/llmjail.winsize`) and applies them via `stty` on `/dev/ttyS0` so the TUI receives SIGWINCH on host terminal resize; then `llmjail-tool` runs the actual tool on `/dev/ttyS0`. `ExecStopPost` powers off the VM when the tool exits. The host runner forwards SIGWINCH into the winsize port via a FIFO→unix-socket→`virtserialport` bridge (`socat`), so no QEMU patches are required.

**Adding a new tool:** Add an entry to `tools.nix` pointing to a new guest module under `guests/`. The guest module imports `common.nix` and overrides `systemd.services.llmjail-tool.serviceConfig.ExecStart`.

## Key Constraints

- **9p can't mount single files.** Config files like `.claude.json` and `.gitconfig` are copied into the envfs temp dir on the host and copied out by the guest mounts service. The dotfile list must stay in sync between `mkRunner.nix` (host copy-in) and `common.nix` (guest copy-out).
- **Tool args use null-separated files** (`tool-args`) to preserve argument boundaries through the host→guest boundary. Don't use env vars for args with spaces.
- **`/run` is remounted by systemd in stage 2**, so guest 9p mounts must not go under `/run`. The envfs mount is at `/llmjail-env`.
- **`writeShellApplication` runs shellcheck.** Avoid `compgen` and other builtins that shellcheck flags. Use `env | grep` patterns instead.
- **`/nix/store` uses an overlay; `/nix/var` is bind-mounted from the same backing.** By default both use a tmpfs at `/.nix-backing`. Use `--store-disk SIZE` to use a disk-backed ext4 image instead, giving space for large builds and intermediate artifacts in `/nix/var/nix/builds/`. Dev shell environments can alternatively be captured on the host via `nix print-dev-env` (opt-in with `--dev-env`) and sourced in the guest.
- **The 9p store mount and overlay backing live outside `/nix`.** The host store is mounted read-only at `/.nix-lower/store` (used as the overlay lower layer directly — overlayfs does not reliably cross submount boundaries, so the lower must be the mounted filesystem itself). The overlay backing (ext4 or tmpfs) is at `/.nix-backing`. Keep this in mind when debugging mount issues inside the guest.
- **Config dirs use a read-only overlay pattern.** `~/.claude` (and `~/.codex`) is mounted read-only as the lower layer of an overlayfs with a tmpfs upper, so writes to credentials/settings are ephemeral. Only subdirs listed in `persistDirs` in `tools.nix` get writable 9p mounts on top of the overlay. To persist a new subdir, add it to `persistDirs` — `mkRunner.nix` creates the host dir and adds the rw mount, and `common.nix` processes entries in order (ro 9p → overlay → rw 9p mounts).

## Version Control

This repo uses **jj (Jujutsu)**, not git directly. Use `jj st`, `jj diff`, `jj commit`, etc.
