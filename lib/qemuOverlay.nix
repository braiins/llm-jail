# Overlay that patches the nixpkgs QEMU with virtio-console terminal resize
# support (SIGWINCH propagation to guest). The resize feature is not upstream
# yet — it comes from the patch series below. Once merged in a stable QEMU
# release, the patches and this overlay can be dropped.
final: prev: {
  qemu = prev.qemu.overrideAttrs (old: {
    # virtio-console resize patch series (v6) by Filip Hejsek & Szymon Lukasz
    # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-0-33a7b0330a7a@gmail.com/
    # Patches adapted to apply against QEMU 10.2.x where noted.
    patches = (old.patches or [ ]) ++ [
      # 01/12: chardev: add cols, rows fields
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-1-33a7b0330a7a@gmail.com/
      ./qemu-patches/0001-console-resize.patch
      # 02/12: chardev: add CHR_EVENT_RESIZE
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-2-33a7b0330a7a@gmail.com/
      ./qemu-patches/0002-console-resize.patch
      # 03/12: chardev: add qemu_chr_resize()
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-3-33a7b0330a7a@gmail.com/
      ./qemu-patches/0003-console-resize.patch
      # 04/12: char-mux: add support for the terminal size
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-4-33a7b0330a7a@gmail.com/
      # Adapted: updated context for qemu_chr_open_mux signature (void + be_opened in 10.2.x)
      ./qemu-patches/0004-console-resize.patch
      # 05/12: main-loop: change the handling of SIGWINCH
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-5-33a7b0330a7a@gmail.com/
      ./qemu-patches/0005-console-resize.patch
      # 06/12: char-stdio: add support for the terminal size
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-6-33a7b0330a7a@gmail.com/
      # Adapted: updated context for qemu_chr_open_stdio/qemu_chr_set_echo_stdio names (10.2.x)
      ./qemu-patches/0006-console-resize.patch
      # 07/12: qmp: add chardev-window-size-changed command
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-7-33a7b0330a7a@gmail.com/
      ./qemu-patches/0007-console-resize.patch
      # 08/12: virtio-serial-bus: add terminal resize messages
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-8-33a7b0330a7a@gmail.com/
      # Adapted: updated virtio_serial_properties context (emergency-write exists in 10.2.x),
      # removed hw_compat_10_2 hunk (doesn't exist in 10.2.x)
      ./qemu-patches/0008-console-resize.patch
      # 09/12: virtio-console: notify the guest about terminal resizes
      # https://lore.kernel.org/qemu-devel/20260119-console-resize-v6-9-33a7b0330a7a@gmail.com/
      ./qemu-patches/0009-console-resize.patch
      # Patches 10-12 (curses, GTK, tests) are not needed for headless virtio-console use.
    ];
  });
}
