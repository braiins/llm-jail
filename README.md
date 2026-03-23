# llm-jail

Hardware-level sandbox for running coding agents inside QEMU microVMs. No containers, no disk images — each session boots a minimal NixOS guest on tmpfs with the host Nix store shared read-only.

Supported tools:

| Tool | Runner command | Dangerous flag |
|------|---------------|----------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `llm-jail-claude` | `--dangerously-skip-permissions` |
| [Codex CLI](https://github.com/openai/codex) | `llm-jail-codex` | `--dangerously-bypass-approvals-and-sandbox` |

## Requirements

- Linux (x86_64 or aarch64)
- [Nix](https://nixos.org/) with flakes enabled
- KVM access recommended (falls back to emulation without it)
- Valid credentials for your chosen tool (`~/.claude` or `~/.codex`)

## Quick start

```bash
# Run Claude
nix run github:braiins/llm-jail#claude

# Run Claude in dangerous mode
nix run github:braiins/llm-jail#claude -- --dangerous

# Run Codex
nix run github:braiins/llm-jail#codex
```

Pass tool arguments after `--`:

```bash
nix run github:braiins/llm-jail#claude -- -- -p "Refactor the auth module" --max-turns 5
```

## Usage

```
llm-jail-{claude,codex} [options] [-- tool-args...]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--dangerous` | Enable the tool's dangerous / unattended mode | off |
| `--config-dir PATH` | Tool config directory | `~/.claude` or `~/.codex` |
| `--mount PATH` | Extra read-write mount (repeatable) | — |
| `--ro-mount PATH` | Extra read-only mount (repeatable) | — |
| `--dev-env` | Capture `nix develop` environment from workspace | off |
| `--store-disk SIZE` | Create a disk-backed nix store overlay (SIZE in GB) | off |
| `--allow-domain DOMAIN` | Add domain to network whitelist (repeatable) | tool defaults |
| `--no-net-filter` | Disable network filtering (unrestricted access) | filtering on |
| `--mem SIZE` | VM memory in MB | 4096 |
| `--vcpu COUNT` | Number of vCPUs | 2 |
| `-h`, `--help` | Show help | — |

Press **Ctrl-a x** to force-quit QEMU at any time.

### Examples

Run Claude in dangerous mode for a fully autonomous task:

```bash
nix run .#claude -- --dangerous -- -p "Write hello to /workspace/hello.txt" --max-turns 3
```

Mount an extra directory and allocate more resources:

```bash
nix run .#claude -- --mount /tmp/data --mem 8192 --vcpu 4 -- -p "Process the dataset"
```

Enable git-over-SSH by mounting your SSH directory (read-only):

```bash
nix run .#claude -- --ro-mount ~/.ssh -- -p "Push the changes"
```

Use a nix dev shell inside the VM:

```bash
nix run .#claude -- --dev-env -- -p "Run the test suite"
```

Allow access to additional domains (e.g. for package installs or git cloning):

```bash
nix run .#claude -- --allow-domain github.com --allow-domain registry.npmjs.org
```

Disable network filtering entirely:

```bash
nix run .#claude -- --no-net-filter
```

Run `nix build` inside the VM with extra storage (root tmpfs is only 2G):

```bash
nix run .#claude -- --store-disk 20 -- -p "nix build and run the tests"
```

## What's isolated

**Filesystem.** The guest boots on a tmpfs root. Only explicitly mounted directories are visible:

- The current working directory → `/workspace` (read-write)
- The tool config directory → `/home/user/.claude` or `.codex` (read-only overlay with writable persist dirs)
- `~/.gitconfig` and the tool's JSON config are copied in (9p cannot mount single files)
- Host system and user packages → `/host-sw`, `/host-user-sw` (read-only, NixOS hosts only)
- Any directories added via `--mount` / `--ro-mount`

All other host paths are invisible to the guest. Changes outside mounted directories are lost when the VM shuts down.

On NixOS hosts, system packages (`/run/current-system/sw`) and user packages (`/etc/profiles/per-user/$USER`) are automatically mounted and added to PATH, so tools like `jj`, `ripgrep`, etc. are available without hardcoding them in the guest.

**Processes.** The agent runs inside a full QEMU virtual machine — separate kernel, separate PID namespace. There is no shared process space with the host.

**Environment variables.** Only these are forwarded to the guest:

- `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- `AWS_*`

All other host environment variables are stripped.

**Network.** By default, outbound network access is restricted via DNS-based domain filtering and a port-level firewall:

- DNS resolution is limited to tool-specific API domains via a local dnsmasq instance
- Only HTTP/HTTPS traffic (ports 80/443) is allowed outbound; all other protocols are blocked by nftables
- Custom API endpoints (via `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) are automatically whitelisted
- Additional domains can be added with `--allow-domain` (subdomains are included automatically)
- Use `--no-net-filter` to disable all network restrictions

Default allowed domains per tool:

| Tool | Domains |
|------|---------|
| Claude | `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io` |
| Codex | `api.openai.com`, `sentry.io` |

> [!NOTE]
> DNS-based filtering prevents the agent from resolving non-whitelisted domains, but does not prevent connections to hardcoded IP addresses on ports 80/443. This is adequate for preventing accidental or prompt-injected exfiltration by LLM agents, which use domain names rather than raw IPs.

## Dangerous mode

> [!CAUTION]
> **Dangerous mode skips the tool's built-in permission prompts** (`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox` for Codex). The agent can execute arbitrary commands, write to any mounted directory, and make network requests without asking.
>
> Network filtering remains active in dangerous mode — the agent can only reach whitelisted domains. To grant unrestricted network access, use `--no-net-filter` (this is independent of `--dangerous`).
>
> **Mitigations if you use dangerous mode:**
> - Scope API keys to the minimum permissions needed
> - Avoid mounting directories containing secrets
> - Be cautious with `--allow-domain` — domains like `github.com` or `npmjs.org` are bidirectional and could be used for data exfiltration
> - Review agent output before trusting it
>
> Without `--dangerous`, the tool's own permission system is active and will prompt before taking sensitive actions. This is the recommended mode for most use cases.

## How it works

```
┌─ Host ──────────────────────────────────────┐
│  nix run .#claude                           │
│    ↓                                        │
│  writeShellApplication (mkRunner.nix)       │
│    • parses CLI args                        │
│    • writes env vars + tool args to tmpdir  │
│    • sets up 9p virtfs mounts               │
│    • optionally creates store disk image    │
│    • launches qemu-system-*                 │
└──────────────────┬──────────────────────────┘
                   │ QEMU (direct kernel boot)
┌─ Guest (NixOS) ──┴──────────────────────────┐
│  /nix/store ← 9p read-only from host        │
│  /workspace ← 9p read-write                 │
│                                             │
│  systemd                                    │
│    → llmjail-mounts: mount 9p shares        │
│    → llmjail-net-filter: dnsmasq + nftables │
│    → llmjail-tool: exec claude/codex        │
│                                             │
│  ExecStopPost: poweroff when tool exits     │
└─────────────────────────────────────────────┘
```

No persistent disk images are involved. The guest kernel and initrd are built by NixOS and passed to QEMU via `-kernel` / `-initrd`. The host Nix store is shared read-only over 9p with an overlay for any writes. When `--store-disk` is used, a sparse ext4 image is created for the overlay's upper layer instead of tmpfs, providing more space for `nix build` operations. The image is cleaned up automatically when the VM exits.

## Adding a new tool

1. Add a guest module under `guests/` (import `common.nix`, set `llmjail.toolBinary` and `llmjail.dangerousFlag`).
2. Add an entry to `tools.nix` pointing at the new module.
3. `nix run .#your-tool` — the flake generates a runner automatically.
