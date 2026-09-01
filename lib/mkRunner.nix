{ pkgs
, name
, guest
, guestSystem
, toolDefaults
,
}:

let
  toplevel = guest.config.system.build.toplevel;
  toplevelDbDump = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  hostIsDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  guestIsAarch64 = guestSystem == "aarch64-linux";
  arch = if guestIsAarch64 then "aarch64" else "x86_64";
  vzRunner = if hostIsDarwin then import ./vz-runner { inherit pkgs; } else null;
in
pkgs.writeShellApplication {
  name = "llm-jail-${name}";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.nix
    pkgs.devenv
    pkgs.e2fsprogs
    pkgs.socat
    pkgs.sqlite
  ] ++ pkgs.lib.optional hostIsDarwin vzRunner
    ++ pkgs.lib.optionals (!hostIsDarwin) [ pkgs.qemu_kvm pkgs.pv ];
  text = ''
    set -euo pipefail

    MEM="${toString toolDefaults.mem}"
    VCPU="${toString toolDefaults.vcpu}"
    DANGEROUS=0
    NIX_ENV=0
    DEVENV=0
    IMMUTABLE=0
    SAME_PATH=0
    LLMJAIL_TMPDIR=''${TMPDIR:-/tmp}
    STORE_DISK=0
    NET_FILTER=1
    EXTRA_DOMAINS=()
    EXTRA_MOUNTS=()
    MASK_PATTERNS=()
    SUPERVISOR_SOCKET=""
    TOOL_ARGS=()

    PROFILE="''${LLMJAIL_PROFILE:-default}"
    STATE_DIR="''${LLMJAIL_STATE_DIR:-}"
    if [ -z "$STATE_DIR" ] && [ -n "''${LLMJAIL_CONFIG_DIR:-}" ]; then
      echo "WARNING: LLMJAIL_CONFIG_DIR is deprecated; use LLMJAIL_STATE_DIR. LLMJAIL_STATE_DIR will be mounted as read-write" >&2
      STATE_DIR="$LLMJAIL_CONFIG_DIR"
    fi

    usage() {
      cat <<'USAGE'
    Usage: llm-jail-${name} [options] [-- tool-args...]

    Options:
      --dangerous           Enable the tool's dangerous / unattended mode
      --profile NAME        State profile, a subdir of --state-dir/<tool> (default: default)
      --state-dir PATH      Jail state root dir (default: ~/.config/llm-jail)
      --immutable           Mount workspace as read-only instead of read-write
      --same-path           Mount workspace at its host path instead of /workspace
                             (lets tools like 'claude --resume' match sessions
                             started outside the sandbox)
      --tmpdir PATH         Directory to use for runtime data (default: ''${TMPDIR:-/tmp})
      --mount HOSTPATH[:GUESTPATH]
                             Extra read-write mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --ro-mount HOSTPATH[:GUESTPATH]
                             Extra read-only mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --mask GLOB           Mask paths matching GLOB in workspace/mounts (repeatable).
                            GLOB with '/' uses -path "<root>/GLOB" (matches across
                            subdirs, e.g. 'a/*' also hits 'a/b/c'); else -name GLOB.
                            Matched paths appear empty and read-only; the name stays
                            visible, only the contents are hidden.
                            Applied at boot only; new matches post-boot are not masked.
      --supervisor-socket ABSOLUTE_PATH
                            Connect a private guest serial device to an
                            existing host Unix socket listener
      --nix-env             Capture nix develop environment from workspace flake
      --devenv              Capture devenv.sh shell environment from workspace
      --store-disk SIZE     Create a disk-backed /nix overlay (SIZE in GB)
      --allow-domain DOMAIN Add domain to network whitelist (repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
      --mem SIZE            Memory in MB (default: ${toString toolDefaults.mem})
      --vcpu COUNT          vCPUs (default: ${toString toolDefaults.vcpu})
      -h, --help            Show this help

    ${if hostIsDarwin then "Press Ctrl-c to stop the VM." else "Press Ctrl-a x to force-quit QEMU."}
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
        --nix-env)     NIX_ENV=1; shift ;;
        --devenv)      DEVENV=1; shift ;;
        --dev-env|--dev-env=*)
                       echo "ERROR: --dev-env has been renamed to --nix-env." >&2
                       exit 1 ;;
        --profile)     PROFILE="$2"; shift 2 ;;
        --state-dir)   STATE_DIR="$2"; shift 2 ;;
        --config-dir|--config-dir=*)
                       echo "ERROR: --config-dir has been renamed to --state-dir and will be mounted as read-write." >&2
                       exit 1 ;;
        --mount)       EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
        --ro-mount)    EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
        --tmpdir)      LLMJAIL_TMPDIR="$2"; shift 2 ;;
        --immutable)    IMMUTABLE=1; shift ;;
        --same-path)   SAME_PATH=1; shift ;;
        --allow-domain)  EXTRA_DOMAINS+=("$2"); shift 2 ;;
        --no-net-filter) NET_FILTER=0; shift ;;
        --mask)        MASK_PATTERNS+=("$2"); shift 2 ;;
        --supervisor-socket)
                       SUPERVISOR_SOCKET="$2"; shift 2 ;;
        --store-disk)  STORE_DISK="$2"; shift 2 ;;
        --mem)         MEM="$2"; shift 2 ;;
        --vcpu)        VCPU="$2"; shift 2 ;;
        -h|--help)     usage ;;
        --)            shift; TOOL_ARGS=("$@"); break ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
      esac
    done

    # Jail-private tool state, fully separate from the host tool's own
    # config dir. --state-dir / LLMJAIL_STATE_DIR overrides the default
    # jail state root (~/.config/llm-jail); <tool>/<profile> is appended.
    if [ -z "$STATE_DIR" ]; then
      STATE_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-jail"
    fi
    STATE_ROOT="$STATE_DIR"
    STATE_DIR="$STATE_ROOT/${name}/$PROFILE"

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
    if [ -n "$SUPERVISOR_SOCKET" ]; then
      if [[ "$SUPERVISOR_SOCKET" != /* ]]; then
        echo "ERROR: supervisor socket path must be absolute: $SUPERVISOR_SOCKET" >&2
        exit 1
      fi
      if [[ "$SUPERVISOR_SOCKET" == *,* ]]; then
        echo "ERROR: supervisor socket path must not contain commas: $SUPERVISOR_SOCKET" >&2
        exit 1
      fi
      if [ ! -S "$SUPERVISOR_SOCKET" ]; then
        echo "ERROR: supervisor socket is not an existing Unix socket: $SUPERVISOR_SOCKET" >&2
        exit 1
      fi
    fi
    RUNDIR=$(mktemp -d --tmpdir="$LLMJAIL_TMPDIR")

    cleanup_rundir() {
      [ -d "$RUNDIR" ] && rm -rf "$RUNDIR"
    }
    CLEANUP_FUNCS+=(cleanup_rundir)

    SUPERVISOR_VM_ARGS=()
    if [ -n "$SUPERVISOR_SOCKET" ]; then
      ${if hostIsDarwin then ''
        SUPERVISOR_VM_ARGS=(--supervisor-socket "$SUPERVISOR_SOCKET")
      '' else ''
        SUPERVISOR_VM_ARGS=(
          -chardev "socket,id=supervisor,path=$SUPERVISOR_SOCKET,server=off"
          -device "virtserialport,chardev=supervisor,name=llmjail.supervisor"
        )
      ''}
    fi

    # TODO: QEMU has a pending patch series (v6, "console: add
    # TIOCSWINSZ support") that adds native SIGWINCH->virtconsole
    # forwarding. When those patches land upstream and reach nixpkgs,
    # this entire side-channel (FIFO, socat bridge, virtio-serial
    # chardev, and the guest llmjail-winsize service) can be dropped in
    # favor of the resize flag on the virtconsole chardev itself.
    #
    # Until then we push "cols rows" lines through a dedicated
    # virtio-serial port on every SIGWINCH; the guest applies them via
    # TIOCSWINSZ on /dev/hvc0.
    #
    # bash defers trap handlers until a synchronous foreground child
    # exits, so a dedicated subshell owns the SIGWINCH trap and parks in
    # `sleep & wait` - wait's trap-interrupt semantics fire the trap
    # promptly on each resize.
    ${pkgs.lib.optionalString (!hostIsDarwin) ''
      WINSIZE_SOCK="$RUNDIR/winsize.sock"
    ''}
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

    WORKSPACE_DIR="/workspace"
    if [[ "$SAME_PATH" -eq 1 ]]; then
      WORKSPACE_DIR="$(pwd)"
    fi
    ENV_FILE="$RUNDIR/env"
    {
      for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_MAX_OUTPUT_TOKENS OPENAI_API_KEY OPENAI_BASE_URL; do
        if [ -n "''${!var:-}" ]; then
          echo "$var=\"''${!var}\""
        fi
      done

      ${pkgs.lib.optionalString (!hostIsDarwin) ''
        # Forward a Linux host shell resolved into /nix/store. Darwin shell
        # binaries cannot execute in the Linux guest, which already includes
        # explicit bash and zsh packages.
        if [ -n "''${SHELL:-}" ]; then
          RESOLVED_SHELL=$(readlink -f "$SHELL" 2>/dev/null || true)
          if [ -n "$RESOLVED_SHELL" ]; then
            echo "SHELL=\"$RESOLVED_SHELL\""
          fi
        fi
      ''}

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
      if [ -n "$SUPERVISOR_SOCKET" ]; then
        echo "LLMJAIL_SUPERVISOR_DEVICE=${if hostIsDarwin then "/dev/hvc1" else "/dev/virtio-ports/llmjail.supervisor"}"
      fi
      # Relocate the tool's state into the jail-private state mount
      echo "${toolDefaults.configEnvVar}=/home/user/${toolDefaults.configDirName}"
      echo "WORKSPACE_DIR=\"$WORKSPACE_DIR\""
    } > "$ENV_FILE"

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
      } | sort -u > "$RUNDIR/runtime-allowed-domains"

      {
        cat "$RUNDIR/runtime-allowed-domains"
        ${builtins.concatStringsSep "\n    " (
          map (d: "echo \"${d}\"") (toolDefaults.buildAllowedDomains or [ ])
        )}
      } | sort -u > "$RUNDIR/allowed-domains"
    else
      : > "$RUNDIR/allowed-domains"
      : > "$RUNDIR/runtime-allowed-domains"
    fi

    ${pkgs.lib.optionalString hostIsDarwin ''
      HOST_DNS=$(/usr/sbin/scutil --dns \
        | ${pkgs.gawk}/bin/awk -f ${./select-darwin-dns.awk})
      if [ -n "$HOST_DNS" ]; then
        printf '%s\n' "$HOST_DNS" > "$RUNDIR/host-dns"
      fi
    ''}

    if [ "$NIX_ENV" = "1" ] && [ "$DEVENV" = "1" ]; then
      echo "ERROR: --nix-env and --devenv are mutually exclusive" >&2
      exit 1
    fi

    if [ "$DEVENV" = "1" ] && [ "$SAME_PATH" != "1" ]; then
      echo "ERROR: --devenv requires --same-path (devenv bakes the workspace's" >&2
      echo "absolute host path into DEVENV_ROOT/DEVENV_DOTFILE/DEVENV_STATE," >&2
      echo "which would otherwise point nowhere once the workspace is mounted" >&2
      echo "at /workspace in the guest)" >&2
      exit 1
    fi

    if [ "$NIX_ENV" = "1" ]; then
      echo "Evaluating nix dev shell..." >&2
      if nix print-dev-env --no-warn-dirty "$(pwd)" > "$RUNDIR/dev-env" 2>/dev/null; then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: nix print-dev-env failed, continuing without dev shell" >&2
        rm -f "$RUNDIR/dev-env"
      fi
    elif [ "$DEVENV" = "1" ]; then
      echo "Evaluating devenv shell..." >&2
      # `devenv direnv-export` (not `devenv shell`) is the right primitive
      # here: it's the same command devenv's own maintained direnvrc uses
      # to import a devenv shell's environment into an already-running
      # shell (see _nix_import_env in
      # https://github.com/cachix/devenv/blob/main/devenv/direnvrc), so
      # unlike `devenv shell` its output ends cleanly after the shellHook
      # eval with no trailing `exec` to strip - direnv couldn't tolerate
      # having its own process replaced either. It's undocumented/hidden
      # from --help but present and stable enough for devenv to depend on
      # it themselves. _DEVENV_CALLER=direnv matches how direnvrc invokes
      # it; harmless (at most affects logging) if unnecessary.
      #
      # devenv (independent of subcommand - this is its own Rust-side
      # bootstrap, not something baked into the output text) needs
      # XDG_RUNTIME_DIR to be a valid, writable directory or it fails
      # outright ("Failed to create /run/user/<uid>/devenv-<hash>:
      # Permission denied") before producing any output at all - relevant
      # on hosts without a real login session providing /run/user/<uid>.
      # (Unlike `devenv shell`'s rcfile, `direnv-export`'s output only
      # *exports* DEVENV_RUNTIME as a value - it has no accompanying
      # `mkdir -p`/`ln -snf` for it, so there's nothing left to fail when
      # the guest sources this later; this override is purely to let the
      # capture step below succeed on the host.)
      #
      # A dedicated scratch dir is used rather than $RUNDIR: the
      # workspace's own devenv.nix shellHook runs on the host as part of
      # `direnv-export` (same trust model as `nix develop`/
      # `nix print-dev-env` on an untrusted flake), and $RUNDIR holds
      # allowed-domains/mask-patterns/tool-args/env - files the guest
      # treats as the trust boundary for its network allowlist and
      # secrets, staged there before this step runs. A shellHook that
      # discovers $XDG_RUNTIME_DIR could otherwise read or tamper with
      # those files pre-boot.
      DEVENV_RUNTIME_SCRATCH=$(mktemp -d --tmpdir="$LLMJAIL_TMPDIR")
      cleanup_devenv_runtime_scratch() {
        rm -rf "$DEVENV_RUNTIME_SCRATCH"
      }
      CLEANUP_FUNCS+=(cleanup_devenv_runtime_scratch)
      if DEVENV_ERR=$(XDG_RUNTIME_DIR="$DEVENV_RUNTIME_SCRATCH" _DEVENV_CALLER=direnv devenv --no-tui -q direnv-export < /dev/null 2>&1 >"$RUNDIR/dev-env"); then
        echo "Dev shell environment captured." >&2
      else
        echo "WARNING: devenv shell failed, continuing without dev shell" >&2
        echo "$DEVENV_ERR" >&2
        rm -f "$RUNDIR/dev-env"
      fi
    fi

    MOUNT_IDX=0
    MOUNT_CMDLINE=""
    SHARE_ARGS=()
    MASK_ROOTS=()

    add_mount() {
      local hostpath="$1" guestpath="$2" mode="$3"
      local tag="mount''${MOUNT_IDX}"
      MOUNT_IDX=$((MOUNT_IDX + 1))

      ${if hostIsDarwin then ''
        local share_mode="rw"
        if [ "$mode" = "ro" ] || [ "$mode" = "ro-nocache" ]; then
          share_mode="ro"
        fi
        SHARE_ARGS+=("--share" "$tag:$hostpath:$share_mode")
      '' else ''
        local virtfs="local,path=$hostpath,security_model=none,mount_tag=$tag"
        if [ "$mode" = "ro" ] || [ "$mode" = "ro-nocache" ]; then
          virtfs="$virtfs,readonly=on"
        fi
        SHARE_ARGS+=("-virtfs" "$virtfs")
      ''}

      if [ -n "$MOUNT_CMDLINE" ]; then
        MOUNT_CMDLINE="$MOUNT_CMDLINE,$tag:$guestpath:$mode"
      else
        MOUNT_CMDLINE="$tag:$guestpath:$mode"
      fi
    }

    validate_path "$(pwd)" "workspace path"
    if [[ "$IMMUTABLE" -eq 1 ]]; then
      add_mount "$(pwd)" "$WORKSPACE_DIR" "ro-nocache"
    else
      add_mount "$(pwd)" "$WORKSPACE_DIR" "rw"
      if [[ -d "$(pwd)/.git/hooks" ]]; then
        add_mount "$(pwd)/.git/hooks" "$WORKSPACE_DIR/.git/hooks" "ro-nocache"
      fi
    fi
    MASK_ROOTS+=("$WORKSPACE_DIR")

    validate_path "$STATE_DIR" "state directory"
    # Host directory shares require an existing path; first run starts empty and
    # the tool goes through its login/onboarding flow inside the jail.
    mkdir -p "$STATE_DIR"
    add_mount "$STATE_DIR" "/home/user/${toolDefaults.configDirName}" "rw"

    # Copy .gitconfig into the environment share because shares are directories.
    if [ -f "$HOME/.gitconfig" ]; then
      cp "$HOME/.gitconfig" "$RUNDIR/.gitconfig"
    fi

    # Snapshot the host nix db into the envfs share so the guest can register the whole host store
    # without replaying rows through `nix-store --load-db` (minutes for big stores). Uses `VACUUM
    # INTO` instead of `.backup`: the backup API opens the WAL source read-only and must take the
    # WAL write lock as a proxy for the read-marks it cannot place in the daemon-owned, non-writable
    # -wal/-shm files; the fcntl write lock then fails with EBADF on the read-only fd and sqlite
    # retries forever (reported as a hang requiring ctrl+c). `VACUUM INTO` reads the source with a
    # plain read transaction, works against the live root-owned nix db, and the output is compact
    # (free pages are dropped). Bounded by `timeout` as a backstop; on failure falls back to the
    # toplevel closure dump.
    NIX_DB_SNAPSHOT=""
    if [ -f /nix/var/nix/db/db.sqlite ]; then
      rm -f "$RUNDIR/nix-db.sqlite"   # VACUUM INTO refuses an existing output file
      if timeout 60 sqlite3 /nix/var/nix/db/db.sqlite "VACUUM INTO '$RUNDIR/nix-db.sqlite';" 2>/dev/null; then
        NIX_DB_SNAPSHOT="/llmjail-env/nix-db.sqlite"
      else
        rm -f "$RUNDIR/nix-db.sqlite" # VACUUM INTO may leave a partial file on failure
        echo "WARNING: could not snapshot host nix db, falling back to closure dump" >&2
      fi
    fi

    ${pkgs.lib.optionalString (!hostIsDarwin) ''
      # Mount host packages if available (NixOS host).
      if [ -d /run/current-system/sw ]; then
        add_mount "/run/current-system/sw" "/host-sw" "ro"
      fi

      # whoami from nixpkgs coreutils won't work on non-NixOS systems that
      # have the user come from sssd and don't have nscd/nsncd enabled.
      USERNAME=$(whoami 2>/dev/null) || USERNAME="$USER"
      if [ -n "$USERNAME" ] && [ -d "/etc/profiles/per-user/$USERNAME" ]; then
        add_mount "/etc/profiles/per-user/$USERNAME" "/host-user-sw" "ro"
      fi
    ''}

    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      if [ -z "$spec" ]; then continue; fi
      mode="''${spec##*:}"
      paths="''${spec%:*}"
      if [[ "$paths" == *:* ]]; then
        hostpath="''${paths%%:*}"
        guestpath="''${paths#*:}"
      else
        hostpath="$paths"
        guestpath="$paths"
      fi
      if [ ! -d "$hostpath" ]; then
        echo "ERROR: mount path does not exist or is not a directory: $hostpath" >&2
        exit 1
      fi
      validate_path "$hostpath" "mount path"
      validate_path "$guestpath" "mount path"
      add_mount "$hostpath" "$guestpath" "$mode"
      MASK_ROOTS+=("$guestpath")
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

    KERNEL_PARAMS="$(cat ${toplevel}/kernel-params) init=${toplevel}/init llmjail.mounts=$MOUNT_CMDLINE"

    if [ "$STORE_DISK" -gt 0 ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.store_disk=1"
    fi

    if [ "$NET_FILTER" = "1" ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.net_filter=1"
    fi

    if USER_UID=''${EUID:-$(id -u)} && [[ -n "$USER_UID" ]]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.user_uid=$USER_UID"
    fi

    if [ -n "$NIX_DB_SNAPSHOT" ]; then
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.nix_db_snapshot=$NIX_DB_SNAPSHOT"
    fi

    KERNEL_PARAMS="$KERNEL_PARAMS llmjail.nix_db_dump=${toplevelDbDump}/registration"
    ${pkgs.lib.optionalString hostIsDarwin ''
      WINSIZE_DEVICE=/dev/hvc1
      if [ -n "$SUPERVISOR_SOCKET" ]; then
        WINSIZE_DEVICE=/dev/hvc2
      fi
      KERNEL_PARAMS="$KERNEL_PARAMS llmjail.winsize_device=$WINSIZE_DEVICE"
    ''}

    DISK_ARGS=()
    if [ "$STORE_DISK" -gt 0 ]; then
      STORE_IMAGE="$RUNDIR/store.img"
      truncate -s "''${STORE_DISK}G" "$STORE_IMAGE"
      mkfs.ext4 -q "$STORE_IMAGE"
      ${if hostIsDarwin then ''
        DISK_ARGS+=(--disk "$STORE_IMAGE")
      '' else ''
        DISK_ARGS+=("-drive" "file=$STORE_IMAGE,format=raw,if=virtio,discard=on")
      ''}
    fi

    ${if hostIsDarwin then ''
      # VirtioFS cannot expose metadata for host Nix lock sidecars that the
      # host daemon owns with mode 0600. Select the exact sidecar shape after
      # all host-side Nix work so the guest can hide those foreign lock names
      # in its overlay.
      ${pkgs.findutils}/bin/find /nix/store \
        -maxdepth 1 \
        -type f \
        -name '*.lock' \
        -size 0c \
        -perm 0600 \
        -printf '%f\0' \
        > "$RUNDIR/store-lock-sidecars"

      printf '%s\n' "$KERNEL_PARAMS" > "$RUNDIR/kernel-params"
      llm-jail-vz \
        --cpus "$VCPU" \
        --memory "$MEM" \
        --kernel ${toplevel}/kernel \
        --initrd ${toplevel}/initrd \
        --cmdline-file "$RUNDIR/kernel-params" \
        --share "nix-store:/nix/store:ro" \
        --share "envfs:$RUNDIR:ro" \
        --winsize-input "$WINSIZE_FIFO" \
        "''${SUPERVISOR_VM_ARGS[@]}" \
        "''${SHARE_ARGS[@]}" \
        "''${DISK_ARGS[@]}"
    '' else ''
      ACCEL_ARGS=()
      if [ -w /dev/kvm ]; then
        ACCEL_ARGS+=("-accel" "kvm" "-cpu" "host")
      else
        echo "WARNING: /dev/kvm not available, falling back to emulation (slow)" >&2
        ACCEL_ARGS+=("-accel" "tcg" "-cpu" "max")
      fi

      MACHINE_ARGS=()
      SERIAL_ARGS=()
      ${if guestIsAarch64 then ''
        MACHINE_ARGS+=("-machine" "virt")
        SERIAL_ARGS+=("-serial" "file:$RUNDIR/kernel.log")
      '' else ''
        SERIAL_ARGS+=("-serial" "null" "-serial" "file:$RUNDIR/kernel.log")
      ''}

      socat -u "PIPE:$WINSIZE_FIFO" "UNIX-CONNECT:$WINSIZE_SOCK,retry=100,interval=0.1" 2>/dev/null &
      SOCAT_PID=$!
      cleanup_socat() {
        kill "$SOCAT_PID" 2>/dev/null
      }
      CLEANUP_FUNCS+=(cleanup_socat)

    # hvc0 (virtio-console) instead of ttyS0 (16550A): the UART transfers
    # output byte-at-a-time through port IO + per-byte interrupts, which
    # stutters on full-screen TUI redraws. virtio-console moves bulk frame
    # data over a virtqueue. SIGWINCH still works via the winsize side-channel
    # (TIOCSWINSZ is tty-core, driver-independent).
    #
    # -display none (not -nographic): we wire stdio explicitly via the mux
    # chardev; -nographic assumes a single serial-on-stdio and conflicts.
    # On x86, two serials are kept so `console=ttyS1` resolves: ttyS0=null and
    # ttyS1 -> kernel.log. ARM's virt machine instead routes its one PL011
    # `ttyAMA0` console to kernel.log.
    #
    # Console output pump. QEMU's virtconsole frontend silently DROPS guest
    # output when the host-side chardev write would block (EAGAIN) - console
    # ports are never throttled, unlike virtserialport ("rather than silently
    # dropping console data on EAGAIN", QEMU hw/char/virtio-console.c; unfixed
    # as of QEMU 11.0.1). TUI redraws burst whole frames (100KB+); a
    # momentarily-full terminal pty (64KB) then loses part of the frame. The
    # `| pv -q -B 64M` pipeline fixes this: pv drains QEMU's stdout eagerly
    # into a 64MB buffer and writes to the terminal as it becomes writable,
    # so the pipe QEMU writes to never stays full and the drop path is never
    # hit. pv flushes small writes promptly (<=90ms), so interactive echo is
    # unaffected. The pipeline is foreground: when QEMU exits, the pipe
    # closes, EOF drains the tail, pv exits, and pipefail propagates QEMU's
    # status - no FIFO, no background job, no cleanup.
      qemu-system-${arch} \
      "''${ACCEL_ARGS[@]}" \
      "''${MACHINE_ARGS[@]}" \
      -m "$MEM" \
      -smp "$VCPU" \
      -kernel ${toplevel}/kernel \
      -initrd ${toplevel}/initrd \
      -append "$KERNEL_PARAMS" \
      -display none \
      -chardev stdio,id=cons0,mux=on,signal=off \
      -mon chardev=cons0,mode=readline \
      -device virtio-serial-pci \
      -device virtconsole,chardev=cons0,nr=0 \
      -chardev "socket,id=winsize,path=$WINSIZE_SOCK,server=on,wait=off" \
      -device virtserialport,chardev=winsize,name=llmjail.winsize \
      "''${SUPERVISOR_VM_ARGS[@]}" \
      "''${SERIAL_ARGS[@]}" \
      -no-reboot \
      -device virtio-rng-pci \
      -nic user,model=virtio-net-pci \
      -virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store,readonly=on \
      -virtfs "local,path=$RUNDIR,security_model=none,mount_tag=envfs,readonly=on" \
      "''${SHARE_ARGS[@]}" \
      "''${DISK_ARGS[@]}" \
      | pv -q -B 64M
    ''}
  '';
}
