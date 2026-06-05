# Plan: Fix Limine ESP_PATH error by removing hooks

## Root Cause
`limine-mkinitcpio-hook` installs alpm hooks (`80-limine-efi-deploy.hook`) that automatically run `/usr/bin/limine-install` on every install/upgrade. Inside `arch-chroot`, `limine-install` cannot access EFI variables, so it corrupts `/etc/default/limine` with its error message as `ESP_PATH`.

## Solution: simplify to manual Limine setup (no hooks)

### Change 1: PACKAGES array (line 131)
Replace:
```
  limine-mkinitcpio-hook
```
With:
```
  limine-entry-tool
```
(`limine-entry-tool` has NO alpm hooks, unlike `limine-mkinitcpio-hook`)

### Change 2: Rewrite Limine chroot section (lines 695-728)
**Remove** (everything that uses hooks):
- `/etc/default/limine` writing (lines 695-700)
- `HOOKS+=(sd-btrfs-overlayfs)` mkinitcpio conf (lines 707-710)
- `pacman -R limine-entry-tool` (line 712-713)
- `pacman -S limine-mkinitcpio-hook` (line 714)
- `limine-update` (line 715)

**Keep**:
- Copia `BOOTX64.EFI` a ESP (lines 689-693)
- `TARGET_OS_NAME` sed (lines 702-705)
- `efibootmgr` (lines 717-728)

**Add** (manual kernel detection + limine.conf, like reference script):
```bash
# Detectar kernel y generar limine.conf manualmente
echo "[chroot] Detectando kernel..."
KERNEL_IMG=$(ls /boot/vmlinuz-linux 2>/dev/null | head -1)
INITRD_IMG=$(ls /boot/initramfs-linux.img 2>/dev/null | head -1)
INITRD_FB=$(ls /boot/initramfs-linux-fallback.img 2>/dev/null || true)
KERNEL_BASE=$(basename "$KERNEL_IMG")
INITRD_BASE=$(basename "$INITRD_IMG")

echo "[chroot] Generando /boot/limine.conf..."
cat > /boot/limine.conf << LIMEOF
timeout: 5
default_entry: 1

/:Helix Linux
  comment: Arch Linux — niri + Noctalia
  protocol: linux
  kernel_path: boot():/${KERNEL_BASE}
  cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0
  module_path: boot():/${INITRD_BASE}
LIMEOF

if [[ -n "$INITRD_FB" ]]; then
  cat >> /boot/limine.conf << LIMEOF

/:Helix Linux (fallback)
  comment: Arch Linux — sin splash, initramfs fallback
  protocol: linux
  kernel_path: boot():/${KERNEL_BASE}
  cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw
  module_path: boot():/$(basename "$INITRD_FB")
LIMEOF
fi
```

### No other changes needed
- `limine-snapper-watcher` section stays as-is
- Snapper section stays as-is
- CPU microcode section stays as-is
- pacman.conf at start of chroot stays as-is
