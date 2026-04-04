{
  pkgs,
  name,
  guest,
  toolDefaults,
}:

let
  toplevel = guest.config.system.build.toplevel;
  qemuPkg = pkgs.qemu_kvm;
  arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64";
in
pkgs.writeShellApplication {
  name = "llm-jail-${name}";
  runtimeInputs = [
    qemuPkg
    pkgs.coreutils
    pkgs.util-linux
    pkgs.nix
    pkgs.e2fsprogs
  ];
  text = ''
    set -euo pipefail

    # ── Defaults ──────────────────────────────────────────────────────
    MEM="${toString toolDefaults.mem}"
    VCPU="${toString toolDefaults.vcpu}"
    DANGEROUS=0
    DEV_ENV=0
    STORE_DISK=0
    CONFIG_DIR="''${LLMJAIL_CONFIG_DIR:-$HOME/${toolDefaults.configDirName}}"
    NET_FILTER=1
    EXTRA_DOMAINS=()
    EXTRA_MOUNTS=()
    TOOL_ARGS=()

    # ── Usage ─────────────────────────────────────────────────────────
    usage() {
      cat <<'USAGE'
    Usage: llm-jail-${name} [options] [-- tool-args...]

    Options:
      --dangerous           Enable the tool's dangerous / unattended mode
      --config-dir PATH     Tool config directory (default: ~/${toolDefaults.configDirName})
      --mount PATH          Extra read-write mount at same path in guest (repeatable)
      --ro-mount PATH       Extra read-only mount at same path in guest (repeatable)
      --dev-env             Capture nix develop environment from workspace flake
      --store-disk SIZE     Create a disk-backed nix store overlay (SIZE in GB)
      --allow-domain DOMAIN Add domain to network whitelist (repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
      --mem SIZE            Memory in MB (default: ${toString toolDefaults.mem})
      --vcpu COUNT          vCPUs (default: ${toString toolDefaults.vcpu})
      -h, --help            Show this help

    Press Ctrl-a x to force-quit QEMU.
    USAGE
      exit 0
    }

    # ── Parse CLI ─────────────────────────────────────────────────────
    while [ $# -gt 0 ]; do
      case "$1" in
        --dangerous)   DANGEROUS=1; shift ;;
        --dev-env)     DEV_ENV=1; shift ;;
        --config-dir)  CONFIG_DIR="$2"; shift 2 ;;
        --mount)       EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
        --ro-mount)    EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
        --allow-domain)  EXTRA_DOMAINS+=("$2"); shift 2 ;;
        --no-net-filter) NET_FILTER=0; shift ;;
        --store-disk)  STORE_DISK="$2"; shift 2 ;;
        --mem)         MEM="$2"; shift 2 ;;
        --vcpu)        VCPU="$2"; shift 2 ;;
        -h|--help)     usage ;;
        --)            shift; TOOL_ARGS=("$@"); break ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
      esac
    done

    # ── Temp dir for env file ─────────────────────────────────────────
    RUNDIR="$(mktemp -d)"
    trap 'rm -rf "$RUNDIR"' EXIT

    # ── Write env file ────────────────────────────────────────────────
    ENV_FILE="$RUNDIR/env"
    {
      # Forward API keys and relevant env vars
      for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_MAX_OUTPUT_TOKENS OPENAI_API_KEY OPENAI_BASE_URL; do
        if [ -n "''${!var:-}" ]; then
          echo "$var=\"''${!var}\""
        fi
      done

      # Forward AWS variables
      env | grep '^AWS_' || true

      # Forward terminal type so TUI apps render correctly
      # Terminal dimensions are propagated dynamically via virtio-console resize.
      for var in TERM COLORTERM; do
        if [ -n "''${!var:-}" ]; then
          echo "$var=\"''${!var}\""
        fi
      done
      if [ -z "''${TERM:-}" ]; then
        echo "TERM=\"xterm-256color\""
      fi

      echo "HOME=/home/user"
      echo "LLMJAIL_DANGEROUS=$DANGEROUS"
    } > "$ENV_FILE"

    # Write tool args as null-separated file to preserve argument boundaries
    if [ ''${#TOOL_ARGS[@]} -gt 0 ]; then
      printf '%s\0' "''${TOOL_ARGS[@]}" > "$RUNDIR/tool-args"
    else
      : > "$RUNDIR/tool-args"
    fi

    # ── Build allowed-domains file ─────────────────────────────────────
    if [ "$NET_FILTER" = "1" ]; then
      {
        # Tool-specific default domains
        ${builtins.concatStringsSep "\n    " (
          map (d: "echo \"${d}\"") toolDefaults.allowedDomains
        )}

        # Auto-extract domains from base URL env vars
        for var in ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
          val="''${!var:-}"
          if [ -n "$val" ]; then
            domain="''${val#*://}"
            domain="''${domain%%/*}"
            domain="''${domain%%:*}"
            if [ -n "$domain" ]; then
              echo "$domain"
            fi
          fi
        done

        # User-specified extra domains
        for d in "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          echo "$d"
        done
      } | sort -u > "$RUNDIR/allowed-domains"
    else
      : > "$RUNDIR/allowed-domains"
    fi

    # ── Capture nix develop environment if requested ───────────────────
    if [ "$DEV_ENV" = "1" ]; then
      echo "Evaluating nix dev shell..." >&2
      if nix print-dev-env --no-warn-dirty "$(pwd)" > "$RUNDIR/dev-env" 2>/dev/null; then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: nix print-dev-env failed, continuing without dev shell" >&2
        rm -f "$RUNDIR/dev-env"
      fi
    fi

    # ── Build mount specs ─────────────────────────────────────────────
    MOUNT_IDX=0
    MOUNT_CMDLINE=""
    VIRTFS_ARGS=()

    add_mount() {
      local hostpath="$1" guestpath="$2" mode="$3"
      local tag="mount''${MOUNT_IDX}"
      MOUNT_IDX=$((MOUNT_IDX + 1))

      local virtfs="local,path=$hostpath,security_model=none,mount_tag=$tag"
      if [ "$mode" = "ro" ] || [ "$mode" = "ro-nocache" ]; then
        virtfs="$virtfs,readonly=on"
      fi
      VIRTFS_ARGS+=("-virtfs" "$virtfs")

      if [ -n "$MOUNT_CMDLINE" ]; then
        MOUNT_CMDLINE="$MOUNT_CMDLINE,$tag:$guestpath:$mode"
      else
        MOUNT_CMDLINE="$tag:$guestpath:$mode"
      fi
    }

    # Default mounts
    add_mount "$(pwd)" "/workspace" "rw"

    # Mount config dir read-only with no cache (overlay lower layer)
    # cache=none ensures host-side credential refreshes are visible instantly
    add_mount "$CONFIG_DIR" "/home/user/${toolDefaults.configDirName}-ro" "ro-nocache"

    # Overlay directive: guest creates overlayfs with tmpfs upper
    # Format: lower:target:overlay (no 9p device needed)
    if [ -n "$MOUNT_CMDLINE" ]; then
      MOUNT_CMDLINE="$MOUNT_CMDLINE,/home/user/${toolDefaults.configDirName}-ro:/home/user/${toolDefaults.configDirName}:overlay"
    else
      MOUNT_CMDLINE="/home/user/${toolDefaults.configDirName}-ro:/home/user/${toolDefaults.configDirName}:overlay"
    fi

    # Mount persist subdirs read-write on top of the overlay
    ${builtins.concatStringsSep "\n" (
      map (subdir: ''
        mkdir -p "$CONFIG_DIR/${subdir}"
        add_mount "$CONFIG_DIR/${subdir}" "/home/user/${toolDefaults.configDirName}/${subdir}" "rw"
      '') toolDefaults.persistDirs
    )}

    # Copy individual config files into envfs share (9p can't mount single files)
    CONFIG_JSON="''${CONFIG_DIR%/${toolDefaults.configDirName}}/${toolDefaults.configDirName}.json"
    for src in "$CONFIG_JSON" "$HOME/.gitconfig"; do
      if [ -f "$src" ]; then
        cp "$src" "$RUNDIR/$(basename "$src")"
      fi
    done
    # SSH directory is NOT mounted by default — use --ro-mount ~/.ssh if needed

    # Mount host packages if available (NixOS host)
    if [ -d /run/current-system/sw ]; then
      add_mount "/run/current-system/sw" "/host-sw" "ro"
    fi
    if [ -d "/etc/profiles/per-user/$(whoami)" ]; then
      add_mount "/etc/profiles/per-user/$(whoami)" "/host-user-sw" "ro"
    fi

    # User extra mounts
    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      if [ -z "$spec" ]; then continue; fi
      hostpath="''${spec%:*}"
      mode="''${spec##*:}"
      if [ ! -d "$hostpath" ]; then
        echo "ERROR: mount path does not exist or is not a directory: $hostpath" >&2
        exit 1
      fi
      add_mount "$hostpath" "$hostpath" "$mode"
    done

    # ── Kernel command line ───────────────────────────────────────────
    KERNEL_PARAMS="$(cat ${toplevel}/kernel-params) init=${toplevel}/init console=ttyS0 llmjail.mounts=$MOUNT_CMDLINE"

    if [ "$STORE_DISK" -gt 0 ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.store_disk=1"
    fi

    if [ "$NET_FILTER" = "1" ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.net_filter=1"
    fi

    # ── Store disk image ────────────────────────────────────────────
    DISK_ARGS=()
    if [ "$STORE_DISK" -gt 0 ]; then
      truncate -s "''${STORE_DISK}G" "$RUNDIR/store.img"
      mkfs.ext4 -q "$RUNDIR/store.img"
      DISK_ARGS+=("-drive" "file=$RUNDIR/store.img,format=raw,if=virtio,discard=on")
    fi

    # ── KVM detection ─────────────────────────────────────────────────
    KVM_ARGS=()
    if [ -w /dev/kvm ]; then
      KVM_ARGS+=("-enable-kvm" "-cpu" "host")
    else
      echo "WARNING: /dev/kvm not available, falling back to emulation (slow)" >&2
      KVM_ARGS+=("-cpu" "max")
    fi

    # ── Launch QEMU ───────────────────────────────────────────────────
    qemu-system-${arch} \
      "''${KVM_ARGS[@]}" \
      -m "$MEM" \
      -smp "$VCPU" \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$KERNEL_PARAMS" \
      -nographic \
      -chardev stdio,id=char0,mux=on,signal=off \
      -device virtio-serial-pci \
      -device virtconsole,chardev=char0 \
      -mon chardev=char0 \
      -serial file:"$RUNDIR/kernel.log" \
      -no-reboot \
      -device virtio-rng-pci \
      -nic user,model=virtio-net-pci \
      -virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store,readonly=on \
      -virtfs "local,path=$RUNDIR,security_model=none,mount_tag=envfs,readonly=on" \
      "''${VIRTFS_ARGS[@]}" \
      "''${DISK_ARGS[@]}"
  '';
}
