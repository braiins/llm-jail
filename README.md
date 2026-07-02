# llm-jail

Hardware-level sandbox for running coding agents inside QEMU microVMs. No containers, no disk images - each session boots a minimal NixOS guest on tmpfs with the host Nix store shared read-only.

Supported tools:

| Tool | Runner command | Dangerous flag |
|------|---------------|----------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `llm-jail-claude` | `--dangerously-skip-permissions` |
| [Codex CLI](https://github.com/openai/codex) | `llm-jail-codex` | `--dangerously-bypass-approvals-and-sandbox` |
| [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) | `llm-jail-copilot` | `--yolo` |
| [opencode](https://opencode.ai) | `llm-jail-opencode` | `--auto` |
| Interactive shell (debugging) | `llm-jail-shell` | - |

## Requirements

- Linux (x86_64 or aarch64)
- [Nix](https://nixos.org/) with flakes enabled
- KVM access recommended (falls back to emulation without it)

No host-side tool credentials are needed: you log in once inside the jail on first run, and the tool's state persists in a jail-private directory under `~/.config/llm-jail/` (see [First run & authentication](#first-run--authentication)).

## Quick start

```bash
# Run Claude
nix run github:braiins/llm-jail#claude

# Run Claude in dangerous mode
nix run github:braiins/llm-jail#claude -- --dangerous

# Run Codex
nix run github:braiins/llm-jail#codex

# Run GitHub Copilot CLI
nix run github:braiins/llm-jail#copilot

# Run opencode
nix run github:braiins/llm-jail#opencode

# Drop into a shell inside the sandbox (for debugging the jail itself)
nix run github:braiins/llm-jail#shell
```

Pass tool arguments after `--`:

```bash
nix run github:braiins/llm-jail#claude -- -- -p "Refactor the auth module" --max-turns 5
```

## First run & authentication

Each tool keeps its state in a jail-private directory on the host - `~/.config/llm-jail/<tool>/<profile>` (profile `default` unless `--profile` is given) - mounted read-write into the guest and selected via the tool's native relocation variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, or `XDG_DATA_HOME` for opencode). Your real `~/.claude`, `~/.codex`, `~/.copilot`, and `~/.local/share/opencode` are never mounted or read.

On first run the directory is empty, so the tool walks you through its normal login flow in the terminal (the OAuth paste-a-URL flow works as-is). Credentials, settings, and session history then persist across runs. Copilot on headless Linux will ask to store its token in plaintext inside the config dir - that's expected, there is no keychain in the guest. opencode doesn't prompt by itself - log in once with `nix run .#opencode -- -- auth login`.

Work for multiple clients by giving each its own profile, each with its own one-time login:

```bash
nix run .#claude -- --profile client1
nix run .#claude -- --profile client2
```

> **Renamed (migration note):** `--config-dir` is now `--state-dir` (the jail-private state **root** directory, mounted **read-write**; `<tool>/<profile>` is appended beneath it). The old `--config-dir` flag is rejected; the `LLMJAIL_CONFIG_DIR` env var still works but is deprecated (use `LLMJAIL_STATE_DIR`). Do not point it at a directory your host tool also uses - a compromised agent could write hooks or settings there that your host tool would later execute. If you want to reuse an existing host login rather than logging in fresh, you can copy it in at your own risk: `cp -a ~/.claude/. ~/.config/llm-jail/claude/default/` (note that host and jail will then refresh the same OAuth token independently).

## Usage

```
llm-jail-{claude,codex,copilot,opencode,shell} [options] [-- tool-args...]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--dangerous` | Enable the tool's dangerous / unattended mode | off |
| `--profile NAME` | State profile, a subdir of `--state-dir/<tool>` | `default` |
| `--state-dir PATH` | Jail state root dir, mounted read-write | `~/.config/llm-jail` |
| `--immutable` | Mount workspace as read-only | off |
| `--tmpdir PATH` | Directory to use for runtime data | `${TMPDIR:-/tmp}` |
| `--mount PATH` | Extra read-write mount (repeatable) | - |
| `--ro-mount PATH` | Extra read-only mount (repeatable) | - |
| `--dev-env` | Capture `nix develop` environment from workspace | off |
| `--store-disk SIZE` | Create a disk-backed /nix overlay (SIZE in GB) | off |
| `--allow-domain DOMAIN` | Add domain to network whitelist (repeatable) | tool defaults |
| `--no-net-filter` | Disable network filtering (unrestricted access) | filtering on |
| `--mem SIZE` | VM memory in MB | 4096 |
| `--vcpu COUNT` | Number of vCPUs | 2 |
| `-h`, `--help` | Show help | - |

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

Drop into your own shell inside the sandbox to inspect mounts or reproduce tool behavior manually:

```bash
nix run .#shell                              # offline debugging shell
nix run .#shell -- --allow-domain github.com # opt in to specific domains
nix run .#shell -- --no-net-filter           # full network for debugging
```

The shell tool honors `$SHELL` (resolved through symlinks so the `/nix/store` path is used) and falls back to zsh or bash if the host shell isn't reachable inside the guest (e.g. on non-NixOS hosts). Shell rc files are not copied in; bring anything you need with `--ro-mount`.

## What's isolated

**Filesystem.** The guest boots on a tmpfs root. Only explicitly mounted directories are visible:

- The current working directory -> `/workspace` (read-write)
- The jail-private tool state dir `~/.config/llm-jail/<tool>/<profile>` -> `/home/user/.claude`, `.codex`, `.copilot`, `.shell`, or `.opencode` (read-write; the tool is pointed at it via `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/`COPILOT_HOME`/`XDG_DATA_HOME`/`ZDOTDIR`)
- `~/.gitconfig` is copied in (9p cannot mount single files)
- Host system and user packages -> `/host-sw`, `/host-user-sw` (read-only, NixOS hosts only)
- Any directories added via `--mount` / `--ro-mount`

All other host paths are invisible to the guest. Changes outside mounted directories are lost when the VM shuts down.

On NixOS hosts, system packages (`/run/current-system/sw`) and user packages (`/etc/profiles/per-user/$USER`) are automatically mounted and added to PATH, so tools like `jj`, `ripgrep`, etc. are available without hardcoding them in the guest.

**Processes.** The agent runs inside a full QEMU virtual machine - separate kernel, separate PID namespace. There is no shared process space with the host.

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
| Claude | `api.anthropic.com`, `claude.ai`, `platform.claude.com`, `statsig.anthropic.com`, `sentry.io` |
| Codex | `api.openai.com`, `auth.openai.com`, `chatgpt.com`, `sentry.io` |
| Copilot | `github.com`, `api.github.com`, `api.individual.githubcopilot.com`, `copilot-proxy.githubusercontent.com`, `githubcopilot.com`, `collector.github.com`, … |
| opencode | `models.dev`, `registry.npmjs.org`, plus the major hosted providers and their login flows: `api.anthropic.com`, `claude.ai`, `console.anthropic.com`, `api.openai.com`, `auth.openai.com`, `generativelanguage.googleapis.com`, `api.githubcopilot.com`, `openrouter.ai`, … (account-specific endpoints like Bedrock/Azure/Vertex need `--allow-domain`) |

> [!NOTE]
> Outbound HTTP/HTTPS is restricted to IPs that the guest's dnsmasq resolved through a whitelisted domain - every successful lookup populates an nftables set (`allowed_ips`), and the firewall only accepts packets whose destination is in that set. Connections to hardcoded IPs that bypass DNS hit the default drop. IPv6 outbound traffic is dropped outright (no IPv6 rules). This is robust against accidental or prompt-injected exfiltration as long as the whitelisted domains themselves aren't bidirectional data channels - see the dangerous-mode warning below.

## Dangerous mode

> [!CAUTION]
> **Dangerous mode skips the tool's built-in permission prompts** (`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox` for Codex, `--yolo` for Copilot, `--auto` for opencode). The agent can execute arbitrary commands, write to any mounted directory, and make network requests without asking.
>
> Network filtering remains active in dangerous mode - the agent can only reach whitelisted domains. To grant unrestricted network access, use `--no-net-filter` (this is independent of `--dangerous`).
>
> **Mitigations if you use dangerous mode:**
> - Scope API keys to the minimum permissions needed
> - Avoid mounting directories containing secrets
> - Be cautious with `--allow-domain` - domains like `github.com` or `npmjs.org` are bidirectional and could be used for data exfiltration
> - Review agent output before trusting it
>
> Without `--dangerous`, the tool's own permission system is active and will prompt before taking sensitive actions. This is the recommended mode for most use cases.

## How it works

```
+-- Host ----------------------------------------+
|  nix run .#claude                              |
|    v                                           |
|  writeShellApplication (mkRunner.nix)          |
|    - parses CLI args                           |
|    - writes env vars + tool args to tmpdir     |
|    - sets up 9p virtfs mounts                  |
|    - optionally creates store disk image       |
|    - launches qemu-system-*                    |
+------------------+-----------------------------+
                   | QEMU (direct kernel boot)
+-- Guest (NixOS) -+-----------------------------+
|  /nix/store <- overlay (9p lower + disk/tmpfs) |
|  /nix/var   <- bind from disk/tmpfs backing    |
|  /workspace <- 9p read-write                   |
|                                                |
|  systemd                                       |
|    -> llmjail-mounts: mount 9p shares          |
|    -> llmjail-net-filter: dnsmasq + nftables   |
|    -> llmjail-tool: exec the tool binary       |
|                                                |
|  ExecStopPost: poweroff when tool exits        |
+------------------------------------------------+
```

No persistent disk images are involved. The guest kernel and initrd are built by NixOS and passed to QEMU via `-kernel` / `-initrd`. The host Nix store is shared read-only over 9p and used directly as the lower layer of a `/nix/store` overlay. `/nix/var` is bind-mounted from the same backing volume so build artifacts (`/nix/var/nix/builds/`) land on disk rather than the root tmpfs. When `--store-disk` is used, a sparse ext4 image backs both; otherwise a tmpfs is used. The image is cleaned up automatically when the VM exits.

## Overriding tool packages

Each runner is built with `lib.makeOverridable`, so the underlying tool package (`claude-code`, `codex-cli`, `copilot-cli`, `opencode`) can be swapped without forking the flake:

```nix
# flake.nix (consumer)
let
  llm-jail = inputs.llm-jail.packages.${system};
in
  llm-jail.claude.override {
    claude-code = my-pinned-claude-code;
  }
```

Useful for pinning a specific tool version, applying local patches, or testing an unreleased build.

## Adding a new tool

1. Add a guest module under `guests/` (import `common.nix`, set `llmjail.toolBinary` and `llmjail.dangerousFlag`).
2. Add an entry to `tools.nix` pointing at the new module.
3. `nix run .#your-tool` - the flake generates a runner automatically.

## License

This project is licensed under the [MIT License](LICENSE).
