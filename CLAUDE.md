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

This is a Nix flake that runs coding agents inside QEMU microVMs with hardware-level isolation. No disk images — the guest boots on tmpfs with `/nix/store` shared read-only from the host via 9p.

**Data flow:** `flake.nix` iterates `tools.nix`, builds a NixOS guest system per tool, wraps each with `lib/mkRunner.nix` into a QEMU launcher script.

**Host side (`lib/mkRunner.nix`):** A `writeShellApplication` that parses CLI args at runtime, writes env vars and tool args to a temp dir, sets up 9p virtfs mounts, optionally creates a store disk image, and launches QEMU with direct kernel boot. On NixOS hosts, `/run/current-system/sw` and `/etc/profiles/per-user/$USER` are auto-mounted so host packages are available in the guest.

**Guest side (`guests/common.nix` + `guests/claude.nix`):** Minimal NixOS. Two systemd services: `llmjail-mounts` parses kernel cmdline (`llmjail.mounts=tag:path:mode,...`) to mount user directories via 9p, then `llmjail-tool` runs the actual tool on `/dev/ttyS0`. `ExecStopPost` powers off the VM when the tool exits.

**Adding a new tool:** Add an entry to `tools.nix` pointing to a new guest module under `guests/`. The guest module imports `common.nix` and overrides `systemd.services.llmjail-tool.serviceConfig.ExecStart`.

## Key Constraints

- **9p can't mount single files.** Config files like `.claude.json` and `.gitconfig` are copied into the envfs temp dir on the host and copied out by the guest mounts service. The dotfile list must stay in sync between `mkRunner.nix` (host copy-in) and `common.nix` (guest copy-out).
- **Tool args use null-separated files** (`tool-args`) to preserve argument boundaries through the host→guest boundary. Don't use env vars for args with spaces.
- **`/run` is remounted by systemd in stage 2**, so guest 9p mounts must not go under `/run`. The envfs mount is at `/llmjail-env`.
- **`writeShellApplication` runs shellcheck.** Avoid `compgen` and other builtins that shellcheck flags. Use `env | grep` patterns instead.
- **The nix store overlay uses tmpfs by default (2G limit).** Use `--store-disk SIZE` to create a disk-backed overlay for `nix build` operations. Without it, builds that produce large store paths will exhaust the tmpfs. Dev shell environments can alternatively be captured on the host via `nix print-dev-env` (opt-in with `--dev-env`) and sourced in the guest.
- **Config dirs use a read-only overlay pattern.** `~/.claude` (and `~/.codex`) is mounted read-only as the lower layer of an overlayfs with a tmpfs upper, so writes to credentials/settings are ephemeral. Only subdirs listed in `persistDirs` in `tools.nix` get writable 9p mounts on top of the overlay. To persist a new subdir, add it to `persistDirs` — `mkRunner.nix` creates the host dir and adds the rw mount, and `common.nix` processes entries in order (ro 9p → overlay → rw 9p mounts).

## Version Control

This repo uses **jj (Jujutsu)**, not git directly. Use `jj st`, `jj diff`, `jj commit`, etc.
