{ pkgs
, name
, guest
, toolDefaults
,
}:

let
  toplevel = guest.config.system.build.toplevel;
  qemuPkg = pkgs.qemu_kvm;
  arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64";
  # Tools without a configDirName (e.g. the debug shell) keep no state:
  # the runner script contains no config-dir handling at all.
  hasConfigDir = toolDefaults ? configDirName;
  # Double-quoted so the two-space option indentation survives Nix's
  # indented-string stripping when interpolated into the usage heredoc.
  configUsage = pkgs.lib.optionalString hasConfigDir (
    "  --profile NAME        Tool state profile under ~/.config/llm-jail/${name}/ (default: default)\n"
    + "  --config-dir PATH     Tool state directory, mounted read-write; overrides --profile\n"
  );
in
pkgs.writeShellApplication {
  name = "llm-jail-${name}";
  runtimeInputs = [
    qemuPkg
    pkgs.coreutils
    pkgs.util-linux
    pkgs.nix
    pkgs.e2fsprogs
    pkgs.socat
  ];
  text = ''
    set -euo pipefail

    MEM="${toString toolDefaults.mem}"
    VCPU="${toString toolDefaults.vcpu}"
    DANGEROUS=0
    DEV_ENV=0
    IMMUTABLE=0
    LLMJAIL_TMPDIR=''${TMPDIR:-/tmp}
    STORE_DISK=0
    ${pkgs.lib.optionalString hasConfigDir ''
      PROFILE="''${LLMJAIL_PROFILE:-default}"
      CONFIG_DIR="''${LLMJAIL_CONFIG_DIR:-}"
    ''}
    NET_FILTER=1
    EXTRA_DOMAINS=()
    EXTRA_MOUNTS=()
    MASK_PATTERNS=()
    TOOL_ARGS=()

    usage() {
      cat <<'USAGE'
    Usage: llm-jail-${name} [options] [-- tool-args...]

    Options:
      --dangerous           Enable the tool's dangerous / unattended mode
    ${configUsage}  --immutable           Mount workspace as read-only instead of read-write
      --tmpdir PATH         Directory to use for runtime data (default: ''${TMPDIR:-/tmp})
      --mount PATH          Extra read-write mount at same path in guest (repeatable)
      --ro-mount PATH       Extra read-only mount at same path in guest (repeatable)
      --mask GLOB           Mask paths matching GLOB in workspace/mounts (repeatable).
                            GLOB with '/' uses -path "<root>/GLOB" (matches across
                            subdirs, e.g. 'a/*' also hits 'a/b/c'); else -name GLOB.
                            Matched paths appear empty and read-only; the name stays
                            visible, only the contents are hidden.
                            Applied at boot only; new matches post-boot are not masked.
      --dev-env             Capture nix develop environment from workspace flake
      --store-disk SIZE     Create a disk-backed /nix overlay (SIZE in GB)
      --allow-domain DOMAIN Add domain to network whitelist (repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
      --mem SIZE            Memory in MB (default: ${toString toolDefaults.mem})
      --vcpu COUNT          vCPUs (default: ${toString toolDefaults.vcpu})
      -h, --help            Show this help

    Press Ctrl-a x to force-quit QEMU.
    USAGE
      exit 0
    }

    CLEANUP_FUNCS=()
    cleanup() {
      local status=$?
      local i

      for (( i=''${#CLEANUP_FUNCS[@]}-1; i >= 0; i-- )); do
        "''${CLEANUP_FUNCS[i]}" || true
      done

      exit "$status"
    }
    trap cleanup EXIT

    while [ $# -gt 0 ]; do
      case "$1" in
        --dangerous)   DANGEROUS=1; shift ;;
        --dev-env)     DEV_ENV=1; shift ;;
    ${pkgs.lib.optionalString hasConfigDir ''
        --profile)     PROFILE="$2"; shift 2 ;;
        --config-dir)  CONFIG_DIR="$2"; shift 2 ;;
    ''}
        --mount)       EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
        --ro-mount)    EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
        --tmpdir)      LLMJAIL_TMPDIR="$2"; shift 2 ;;
        --immutable)    IMMUTABLE=1; shift ;;
        --allow-domain)  EXTRA_DOMAINS+=("$2"); shift 2 ;;
        --no-net-filter) NET_FILTER=0; shift ;;
        --mask)        MASK_PATTERNS+=("$2"); shift 2 ;;
        --store-disk)  STORE_DISK="$2"; shift 2 ;;
        --mem)         MEM="$2"; shift 2 ;;
        --vcpu)        VCPU="$2"; shift 2 ;;
        -h|--help)     usage ;;
        --)            shift; TOOL_ARGS=("$@"); break ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
      esac
    done

    ${pkgs.lib.optionalString hasConfigDir ''
      # Jail-private tool state, fully separate from the host tool's own
      # config dir. --config-dir / LLMJAIL_CONFIG_DIR overrides --profile.
      if [ -z "$CONFIG_DIR" ]; then
        CONFIG_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-jail/${name}/$PROFILE"
      fi
    ''}

    if [ ! -d "$LLMJAIL_TMPDIR" ]; then
      echo "ERROR: tmpdir '$LLMJAIL_TMPDIR' does not exist" >&2
      exit 1
    fi

    # Paths used in virtfs option strings (comma-separated) and kernel cmdline
    # (space-separated) cannot contain commas, spaces, or colons (mount spec delimiter).
    validate_path() {
      local path="$1" label="''${2:-path}"
      if [[ "$path" == *,* ]]; then
        echo "ERROR: $label must not contain commas: $path" >&2
        exit 1
      fi
      if [[ "$path" == *\ * ]]; then
        echo "ERROR: $label must not contain spaces: $path" >&2
        exit 1
      fi
      if [[ "$path" == *:* ]]; then
        echo "ERROR: $label must not contain colons: $path" >&2
        exit 1
      fi
    }

    validate_path "$LLMJAIL_TMPDIR" "tmpdir"
    RUNDIR=$(mktemp -d --tmpdir="$LLMJAIL_TMPDIR")

    cleanup_rundir() {
      [ -d "$RUNDIR" ] && rm -rf "$RUNDIR"
    }
    CLEANUP_FUNCS+=(cleanup_rundir)

    # TODO: QEMU has a pending patch series (v6, "console: add
    # TIOCSWINSZ support") that adds native SIGWINCH->virtconsole
    # forwarding. When those patches land upstream and reach nixpkgs,
    # this entire side-channel (FIFO, socat bridge, virtio-serial
    # chardev, and the guest llmjail-winsize service) can be replaced
    # by switching to -chardev console + hvc0 with the resize flag.
    #
    # Stock QEMU has no SIGWINCH->virtio-console forwarding, so we run a
    # dedicated virtio-serial port (llmjail.winsize) as a unix-socket
    # chardev and push "cols rows" lines through it on every SIGWINCH.
    # The guest's llmjail-winsize service reads the port and issues
    # TIOCSWINSZ on /dev/ttyS0, delivering SIGWINCH to the tool pgrp.
    #
    # QEMU runs in the foreground so stdin/stdout are cleanly wired to
    # -serial mon:stdio. bash defers trap handlers until a synchronous
    # foreground child exits, so a dedicated subshell owns the SIGWINCH
    # trap and parks in `sleep & wait` - wait's trap-interrupt semantics
    # fire the trap promptly on each resize.
    WINSIZE_SOCK="$RUNDIR/winsize.sock"
    WINSIZE_FIFO="$RUNDIR/winsize.fifo"
    mkfifo "$WINSIZE_FIFO"
    # Hold the FIFO open RDWR on fd 3 so trap writes never block on
    # "no writer" and the bridge never sees premature EOF.
    exec 3<>"$WINSIZE_FIFO"

    (
      winsize_emit() {
        # Read from /dev/tty explicitly: bash redirects an async command's
        # stdin to /dev/null when job control is disabled (POSIX).
        local size
        size=$(stty size </dev/tty 2>/dev/null) || return 0
        # stty size prints "rows cols"; the guest reader expects "cols rows".
        printf '%s %s\n' "''${size##* }" "''${size%% *}" >&3 || true
      }
      trap winsize_emit WINCH
      winsize_emit

      # 'uninvoked function', but indirect call via trap
      # shellcheck disable=SC2329
      cleanup_sleep() {
        if [ -n "''${SLEEP_PID:-}" ]; then
          kill "$SLEEP_PID" 2>/dev/null || true
          wait "$SLEEP_PID" 2>/dev/null || true
        fi
        exit
      }
      trap cleanup_sleep TERM
      while :; do
        sleep 86400 &
        SLEEP_PID=$!
        # wait(2) is interrupted by WINCH traps. Keep waiting for the same
        # sleep PID until it actually exits, otherwise we'd leak sleepers.
        while kill -0 "$SLEEP_PID" 2>/dev/null; do
          wait "$SLEEP_PID" 2>/dev/null || true
        done
      done
    ) &
    WINCH_FWD_PID=$!
    cleanup_winch() {
      kill "$WINCH_FWD_PID" 2>/dev/null
    }
    CLEANUP_FUNCS+=(cleanup_winch)

    ENV_FILE="$RUNDIR/env"
    {
      for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_MAX_OUTPUT_TOKENS OPENAI_API_KEY OPENAI_BASE_URL; do
        if [ -n "''${!var:-}" ]; then
          echo "$var=\"''${!var}\""
        fi
      done

      # Forward host shell (resolved through symlinks so the /nix/store path
      # is exposed, which the guest can reach via the 9p store mount even
      # though /run/current-system/sw is remapped to /host-sw).
      if [ -n "''${SHELL:-}" ]; then
        RESOLVED_SHELL=$(readlink -f "$SHELL" 2>/dev/null || true)
        if [ -n "$RESOLVED_SHELL" ]; then
          echo "SHELL=\"$RESOLVED_SHELL\""
        fi
      fi

      env | grep '^AWS_' || true

      # Forward terminal type and dimensions so TUI apps render correctly
      for var in TERM COLORTERM; do
        if [ -n "''${!var:-}" ]; then
          echo "$var=\"''${!var}\""
        fi
      done
      if [ -z "''${TERM:-}" ]; then
        echo "TERM=\"xterm-256color\""
      fi
      if STTY_SIZE=$(stty size 2>/dev/null); then
        echo "LINES=''${STTY_SIZE%% *}"
        echo "COLUMNS=''${STTY_SIZE##* }"
      fi

      echo "HOME=/home/user"
      echo "LLMJAIL_DANGEROUS=$DANGEROUS"
    ${pkgs.lib.optionalString hasConfigDir ''
      # Relocate the tool's state into the jail-private config mount
      echo "${toolDefaults.configEnvVar}=/home/user/${toolDefaults.configDirName}"
    ''}} > "$ENV_FILE"

    # Write tool args as null-separated file to preserve argument boundaries
    if [ ''${#TOOL_ARGS[@]} -gt 0 ]; then
      printf '%s\0' "''${TOOL_ARGS[@]}" > "$RUNDIR/tool-args"
    else
      : > "$RUNDIR/tool-args"
    fi

    if [ "$NET_FILTER" = "1" ]; then
      {
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

        for d in "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          echo "$d"
        done
      } | sort -u > "$RUNDIR/allowed-domains"
    else
      : > "$RUNDIR/allowed-domains"
    fi

    if [ "$DEV_ENV" = "1" ]; then
      echo "Evaluating nix dev shell..." >&2
      if nix print-dev-env --no-warn-dirty "$(pwd)" > "$RUNDIR/dev-env" 2>/dev/null; then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: nix print-dev-env failed, continuing without dev shell" >&2
        rm -f "$RUNDIR/dev-env"
      fi
    fi

    MOUNT_IDX=0
    MOUNT_CMDLINE=""
    VIRTFS_ARGS=()
    MASK_ROOTS=()

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

    validate_path "$(pwd)" "workspace path"
    if [[ "$IMMUTABLE" -eq 1 ]]; then
      add_mount "$(pwd)" "/workspace" "ro-nocache"
    else
      add_mount "$(pwd)" "/workspace" "rw"
      if [[ -d "$(pwd)/.git/hooks" ]]; then
        add_mount "$(pwd)/.git/hooks" "/workspace/.git/hooks" "ro-nocache"
      fi
    fi
    MASK_ROOTS+=("/workspace")

    ${pkgs.lib.optionalString hasConfigDir ''
      validate_path "$CONFIG_DIR" "config directory"
      # 9p refuses to share a non-existent path; first run starts empty and
      # the tool goes through its login/onboarding flow inside the jail.
      mkdir -p "$CONFIG_DIR"
      add_mount "$CONFIG_DIR" "/home/user/${toolDefaults.configDirName}" "rw"
    ''}

    # Copy .gitconfig into the envfs share (9p can't mount single files)
    if [ -f "$HOME/.gitconfig" ]; then
      cp "$HOME/.gitconfig" "$RUNDIR/.gitconfig"
    fi

    # Mount host packages if available (NixOS host)
    if [ -d /run/current-system/sw ]; then
      add_mount "/run/current-system/sw" "/host-sw" "ro"
    fi

    # whoami from nixpkgs coreutils won't work on non-NixOS systems that have the user come from
    # sssd and don't have nscd/nsncd enabled
    USERNAME=$(whoami 2>/dev/null) || USERNAME="$USER"
    if [ -n "$USERNAME" ] && [ -d "/etc/profiles/per-user/$USERNAME" ]; then
      add_mount "/etc/profiles/per-user/$USERNAME" "/host-user-sw" "ro"
    fi

    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      if [ -z "$spec" ]; then continue; fi
      hostpath="''${spec%:*}"
      mode="''${spec##*:}"
      if [ ! -d "$hostpath" ]; then
        echo "ERROR: mount path does not exist or is not a directory: $hostpath" >&2
        exit 1
      fi
      validate_path "$hostpath" "mount path"
      add_mount "$hostpath" "$hostpath" "$mode"
      MASK_ROOTS+=("$hostpath")
    done

    for p in "''${MASK_PATTERNS[@]+"''${MASK_PATTERNS[@]}"}"; do
      case "$p" in
        *$'\n'*) echo "ERROR: --mask must not contain newlines: $p" >&2; exit 1 ;;
      esac
    done
    if [ ''${#MASK_PATTERNS[@]} -gt 0 ]; then
      printf '%s\n' "''${MASK_PATTERNS[@]}" > "$RUNDIR/mask-patterns"
    else
      : > "$RUNDIR/mask-patterns"
    fi
    if [ ''${#MASK_ROOTS[@]} -gt 0 ]; then
      printf '%s\n' "''${MASK_ROOTS[@]}" > "$RUNDIR/mask-roots"
    else
      : > "$RUNDIR/mask-roots"
    fi

    KERNEL_PARAMS="$(cat ${toplevel}/kernel-params) init=${toplevel}/init console=ttyS1 llmjail.mounts=$MOUNT_CMDLINE"

    if [ "$STORE_DISK" -gt 0 ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.store_disk=1"
    fi

    if [ "$NET_FILTER" = "1" ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.net_filter=1"
    fi

    if USER_UID=''${EUID:-$(id -u)} && [[ -n "$USER_UID" ]]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.user_uid=$USER_UID"
    fi

    DISK_ARGS=()
    if [ "$STORE_DISK" -gt 0 ]; then
      truncate -s "''${STORE_DISK}G" "$RUNDIR/store.img"
      mkfs.ext4 -q "$RUNDIR/store.img"
      DISK_ARGS+=("-drive" "file=$RUNDIR/store.img,format=raw,if=virtio,discard=on")
    fi

    KVM_ARGS=()
    if [ -w /dev/kvm ]; then
      KVM_ARGS+=("-enable-kvm" "-cpu" "host")
    else
      echo "WARNING: /dev/kvm not available, falling back to emulation (slow)" >&2
      KVM_ARGS+=("-cpu" "max")
    fi

    # socat itself retries the UNIX-CONNECT until QEMU binds the socket,
    # so no polling loop is needed.
    socat -u "PIPE:$WINSIZE_FIFO" "UNIX-CONNECT:$WINSIZE_SOCK,retry=100,interval=0.1" 2>/dev/null &
    SOCAT_PID=$!
    cleanup_socat() {
      kill "$SOCAT_PID" 2>/dev/null
    }
    CLEANUP_FUNCS+=(cleanup_socat)

    qemu-system-${arch} \
      "''${KVM_ARGS[@]}" \
      -m "$MEM" \
      -smp "$VCPU" \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$KERNEL_PARAMS" \
      -nographic \
      -serial mon:stdio \
      -serial file:"$RUNDIR/kernel.log" \
      -device virtio-serial-pci \
      -chardev "socket,id=winsize,path=$WINSIZE_SOCK,server=on,wait=off" \
      -device virtserialport,chardev=winsize,name=llmjail.winsize \
      -no-reboot \
      -device virtio-rng-pci \
      -nic user,model=virtio-net-pci \
      -virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store,readonly=on \
      -virtfs "local,path=$RUNDIR,security_model=none,mount_tag=envfs,readonly=on" \
      "''${VIRTFS_ARGS[@]}" \
      "''${DISK_ARGS[@]}"
  '';
}
