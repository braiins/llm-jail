{ pkgs, ... }:

{
  # Parses kernel cmdline for llmjail.mounts=tag0:/path:rw,tag1:/path:ro,...
  # and mounts each entry via 9p.
  systemd.services.llmjail-mounts = {
    description = "Mount llmjail 9p shares from kernel cmdline";
    wantedBy = [ "multi-user.target" ];
    before = [ "llmjail-tool.service" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      MOUNTS=""
      for arg in $(cat /proc/cmdline); do
        case "$arg" in
          llmjail.mounts=*) MOUNTS="''${arg#llmjail.mounts=}" ;;
        esac
      done

      if [ -z "$MOUNTS" ]; then
        echo "No llmjail mounts specified."
        exit 0
      fi

      IFS=',' read -ra ENTRIES <<< "$MOUNTS"
      for entry in "''${ENTRIES[@]}"; do
        IFS=':' read -r tag mpath mode <<< "$entry"

        echo "Mounting $tag -> $mpath ($mode)"
        ${pkgs.coreutils}/bin/mkdir -p "$mpath"

        OPTS="trans=virtio,version=9p2000.L,cache=mmap,msize=1048576"
        if [ "$mode" = "ro" ]; then
          OPTS="$OPTS,ro"
        elif [ "$mode" = "ro-nocache" ]; then
          OPTS="trans=virtio,version=9p2000.L,cache=none,msize=1048576,ro"
        fi
        ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$mpath" -o "$OPTS"

        # Fix ownership for paths under /home/user
        case "$mpath" in
          /home/user|/home/user/*)
            ${pkgs.coreutils}/bin/chown user:users "$mpath" 2>/dev/null || true
            ;;
        esac
      done

      # Copy dotfiles provided via envfs (can't mount individual files via
      # 9p). Currently just .gitconfig, placed there by mkRunner.
      for src in /llmjail-env/.*; do
        [ -f "$src" ] || continue
        name="''${src##*/}"
        ${pkgs.coreutils}/bin/cp "$src" "/home/user/$name"
        ${pkgs.coreutils}/bin/chown user:users "/home/user/$name"
      done

      # Apply --mask patterns to user-data roots.
      # Bind-mounts an empty dir/file over each matched path so the
      # tool sees no contents (the name stays visible, only contents
      # are hidden). Static: applied once at boot. New files matching
      # the pattern after boot are NOT masked.
      if [ -s /llmjail-env/mask-patterns ] && [ -s /llmjail-env/mask-roots ]; then
        ${pkgs.coreutils}/bin/mkdir -p /run/llmjail-mask/empty-dir
        : > /run/llmjail-mask/empty-file
        ${pkgs.coreutils}/bin/chmod 0555 /run/llmjail-mask/empty-dir
        ${pkgs.coreutils}/bin/chmod 0444 /run/llmjail-mask/empty-file

        while IFS= read -r root || [ -n "$root" ]; do
          [ -z "$root" ] && continue
          [ -d "$root" ] || continue

          EXPR=()
          while IFS= read -r p || [ -n "$p" ]; do
            [ -z "$p" ] && continue
            if [ ''${#EXPR[@]} -gt 0 ]; then EXPR+=("-o"); fi
            case "$p" in
              */*) EXPR+=("-path" "$root/$p") ;;
              *)   EXPR+=("-name" "$p") ;;
            esac
          done < /llmjail-env/mask-patterns

          [ ''${#EXPR[@]} -eq 0 ] && continue

          # -xdev keeps the walk inside the root's filesystem (the
          # 9p mount), so we never wander into nested mounts.
          # -prune skips descent into matched dirs (cheap on big trees).
          ${pkgs.findutils}/bin/find "$root" -xdev \( "''${EXPR[@]}" \) -prune -print0 |
            while IFS= read -r -d "" target; do
              [ "$target" = "$root" ] && continue
              # Skip symlinks: mount --bind resolves the link, and we don't
              # want to mask the target instead of the link itself.
              # Notify the user and skip.
              if [ -L "$target" ]; then
                echo "mask: skipping symlink (not masked): $target"
                continue
              fi
              if [ -d "$target" ]; then
                ${pkgs.util-linux}/bin/mount --bind /run/llmjail-mask/empty-dir "$target"
              elif [ -e "$target" ]; then
                ${pkgs.util-linux}/bin/mount --bind /run/llmjail-mask/empty-file "$target"
              else
                continue
              fi
              ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$target"
              echo "masked: $target"
            done
        done < /llmjail-env/mask-roots
      fi
    '';
  };
}
