#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════
#  HELIX LINUX — Instalador interactivo
#  Arch Linux + niri + Noctalia + configuración Helix
# ══════════════════════════════════════════════════════════════════

ROOT_MOUNT="/mnt"

# ── Colores ─────────────────────────────────────────────────────
BOLD=$'\033[1m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

info()  { echo -e "${CYAN}::${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }
banner() {
  clear
  echo -e "${BOLD}"
  echo '  ╔══════════════════════════════════════════════════╗'
  echo '  ║              HELIX LINUX                         ║'
  echo '  ║   Arch Linux + niri + Noctalia                   ║'
  echo '  ╚══════════════════════════════════════════════════╝'
  echo -e "${NC}"
}

# ── Verificar root ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Este script debe ejecutarse como root."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PRIMERO: preguntar todo (interactivo)
# ═══════════════════════════════════════════════════════════════════════════════

banner
info "Bienvenido al instalador de Helix Linux."
echo ""

# ── 1. Selección de disco ─────────────────────────────────────────────────────
info "Discos disponibles:"
echo ""
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E 'disk'
echo ""
read -rp "${BOLD}¿En qué disco querés instalar? (ej: sda, nvme0n1): ${NC}" DISK
DISK="/dev/$DISK"
if [[ ! -b $DISK ]]; then
  error "El disco $DISK no existe."
  exit 1
fi
ok "Disco seleccionado: $DISK"
echo ""

# ── 2. Tipo de sistema ────────────────────────────────────────────────────────
read -rp "${BOLD}¿UEFI o BIOS? (uefi/bios): ${NC}" SYS_TYPE
case "$SYS_TYPE" in
  uefi|UEFI) SYS_TYPE="uefi" ;;
  bios|BIOS|legacy|Legacy) SYS_TYPE="bios" ;;
  *) warn "Opción inválida, asumiendo UEFI."; SYS_TYPE="uefi" ;;
esac
ok "Modo: $SYS_TYPE"
echo ""

# ── 3. Bootloader ──────────────────────────────────────────────────────────────
echo -e "${BOLD}Seleccioná el bootloader:${NC}"
echo "  1) GRUB  (recomendado)"
echo "  2) Limine"
read -rp "Opción (1/2): " BOOT_OPT
case "$BOOT_OPT" in
  2|limine|Limine) BOOTLOADER="limine" ;;
  *) BOOTLOADER="grub" ;;
esac
ok "Bootloader: $BOOTLOADER"
echo ""

# ── 4. Configuración del sistema (interactivo) ─────────────────────────────────
echo -e "${BOLD}Configuración del sistema:${NC}"
echo ""

read -rp "  Hostname [helix]: " HOSTNAME
HOSTNAME="${HOSTNAME:-helix}"

read -rp "  Locale [es_AR.UTF-8]: " LOCALE
LOCALE="${LOCALE:-es_AR.UTF-8}"

read -rp "  Timezone [America/Argentina/Buenos_Aires]: " TIMEZONE
TIMEZONE="${TIMEZONE:-America/Argentina/Buenos_Aires}"

echo ""
read -rsp "  Password de root: " ROOT_PASS
echo ""
read -rsp "  Repetir password de root: " ROOT_PASS2
echo ""
if [[ "$ROOT_PASS" != "$ROOT_PASS2" ]]; then
  error "Las passwords no coinciden."
  exit 1
fi

echo ""
read -rp "  Nombre de usuario [helix]: " USERNAME
USERNAME="${USERNAME:-helix}"
USER_HOME="/home/$USERNAME"

read -rsp "  Password de $USERNAME: " USER_PASS
echo ""
read -rsp "  Repetir password de $USERNAME: " USER_PASS2
echo ""
if [[ "$USER_PASS" != "$USER_PASS2" ]]; then
  error "Las passwords no coinciden."
  exit 1
fi

USER_GROUPS="wheel,storage,audio,video,input,seat,docker"

# ── Confirmar ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║  ¡ATENCIÓN! Esto va a BORRAR COMPLETAMENTE $DISK  ║${NC}"
echo -e "${BOLD}${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "${BOLD}¿Estás seguro de querer continuar? (escribí 'YES'): ${NC}" CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  error "Abortando."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  SEGUNDO: ejecutar instalación
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
banner
info "Comenzando instalación..."
echo ""

# ── Particionado ───────────────────────────────────────────────────────────────
info "Particionando $DISK..."
wipefs -af "$DISK"
partprobe "$DISK" 2>/dev/null || true

if [[ "$SYS_TYPE" == "uefi" ]]; then
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
  parted -s "$DISK" set 1 esp on
  parted -s "$DISK" mkpart primary btrfs 513MiB 100%
else
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary 1MiB 2MiB
  parted -s "$DISK" set 1 bios_grub on
  parted -s "$DISK" mkpart primary btrfs 2MiB 100%
fi

partprobe "$DISK" 2>/dev/null || true
sleep 2

if echo "$DISK" | grep -q 'nvme\|mmc'; then
  PART_BOOT="${DISK}p1"
  PART_ROOT="${DISK}p2"
else
  PART_BOOT="${DISK}1"
  PART_ROOT="${DISK}2"
fi

ok "Particiones creadas."
echo ""

# ── Formateo ───────────────────────────────────────────────────────────────────
info "Formateando particiones..."

if [[ "$SYS_TYPE" == "uefi" ]]; then
  mkfs.fat -F32 "$PART_BOOT"
  ok "$PART_BOOT → FAT32 (EFI)"
fi

mkfs.btrfs -f "$PART_ROOT"
ok "$PART_ROOT → btrfs"
echo ""

# ── Subvolumes btrfs ───────────────────────────────────────────────────────────
info "Creando subvolumes btrfs..."
mount "$PART_ROOT" "$ROOT_MOUNT"

for subvol in @ @home @log @pkg @snapshots; do
  btrfs subvolume create "$ROOT_MOUNT/$subvol"
done

umount "$ROOT_MOUNT"
ok "Subvolumes: @, @home, @log, @pkg, @snapshots"
echo ""

# ── Montaje ────────────────────────────────────────────────────────────────────
info "Montando particiones..."

BTRFS_OPTS="compress=zstd:3,noatime"

mount -o "$BTRFS_OPTS,subvol=@" "$PART_ROOT" "$ROOT_MOUNT"

mkdir -p "$ROOT_MOUNT"/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}

mount -o "$BTRFS_OPTS,subvol=@home" "$PART_ROOT" "$ROOT_MOUNT/home"
mount -o "$BTRFS_OPTS,subvol=@log" "$PART_ROOT" "$ROOT_MOUNT/var/log"
mount -o "$BTRFS_OPTS,subvol=@pkg" "$PART_ROOT" "$ROOT_MOUNT/var/cache/pacman/pkg"
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$PART_ROOT" "$ROOT_MOUNT/.snapshots"

if [[ "$SYS_TYPE" == "uefi" ]]; then
  mount "$PART_BOOT" "$ROOT_MOUNT/boot"
fi

ok "Particiones montadas."
echo ""

# ── Pacstrap ───────────────────────────────────────────────────────────────────
info "Configurando pacman.conf de la ISO live..."

if ! grep -q '^\[core_repo\]' /etc/pacman.conf; then
  # Verificar que el repo AUR local esté accesible antes de agregarlo
  if curl -sf --max-time 5 "https://sourcecorearch.github.io/core_repo/x86_64/" > /dev/null 2>&1; then
    cat >> /etc/pacman.conf << PACMANEOF

[multilib]
Include = /etc/pacman.d/mirrorlist

[core_repo]
SigLevel = Never
Server = https://sourcecorearch.github.io/core_repo/\$arch
PACMANEOF
  else
    warn "No se pudo alcanzar core_repo — noctalia-qs y noctalia-shell no estarán disponibles."
  fi
fi

PACKAGES=(
  mkinitcpio
  base base-devel sudo linux linux-firmware linux-firmware-marvell
  sof-firmware amd-ucode intel-ucode man-db man-pages less vim nano
  diffutils seatd dbus dbus-broker
  grub limine efibootmgr os-prober dosfstools mtools
  btrfs-progs e2fsprogs xfsprogs f2fs-tools jfsutils exfatprogs
  udftools ntfs-3g nilfs-utils bcachefs-tools snapper snap-pac
  parted gptfdisk gpart fatresize hdparm sdparm smartmontools nvme-cli
  lvm2 mdadm dmraid cryptsetup arch-install-scripts archinstall
  clonezilla partclone partimage ddrescue fsarchiver fastfetch testdisk
  networkmanager network-manager-applet nm-connection-editor dhcpcd
  iw iwd wpa_supplicant wireless-regdb wireless_tools usb_modeswitch
  modemmanager openconnect openvpn vpnc ppp pptpclient xl2tpd nbd
  open-iscsi nfs-utils ndisc6 ldns tcpdump bind dnsmasq rsync curl wget
  openssh ethtool
  bolt usbutils usbmuxd pcsclite libfido2 libusb-compat tpm2-tss
  sg3_utils lsscsi mmc-utils dmidecode pv broadcom-wl b43-fwcutter
  fish foot foot-terminfo kitty-terminfo rxvt-unicode-terminfo tmux
  screen starship zsh grml-zsh-config terminus-font
  niri xdg-utils xdg-user-dirs polkit-gnome qt5-wayland qt6-wayland
  qt6-multimedia qt6-multimedia-ffmpeg xorg-xwayland xdg-desktop-portal
  xdg-desktop-portal-gnome libappindicator-gtk3 wlr-randr
  sddm
  noctalia-qs noctalia-shell
  brightnessctl imagemagick python cliphist wlsunset
  power-profiles-daemon upower
  pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol
  alsa-utils
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji ttf-font-awesome
  neovim lua git lazygit github-cli
  nodejs npm go rustup
  docker docker-compose podman
  eza bat fzf ripgrep fd zoxide btop jq tree zip reflector
  pacman-contrib sequoia-sq openpgp-card-tools
  thunar gvfs imv acpi udiskie bluez bluez-utils
)

info "Instalando sistema base con pacstrap..."
pacstrap "$ROOT_MOUNT" "${PACKAGES[@]}"

ok "Sistema base instalado."
echo ""

# ── Fstab ──────────────────────────────────────────────────────────────────────
info "Generando fstab..."
genfstab -U "$ROOT_MOUNT" > "$ROOT_MOUNT/etc/fstab"
sed -i 's/subvolid=[0-9]*,\?//g; s/,\([ \t]\)/\1/g' "$ROOT_MOUNT/etc/fstab"
ok "fstab generado."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  CHROOT
# ═══════════════════════════════════════════════════════════════════════════════

info "Configurando sistema via chroot..."

ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

# Escapar passwords para evitar problemas con caracteres especiales en el heredoc
ROOT_PASS_ESC=$(printf '%s' "$ROOT_PASS" | sed 's/[\/&]/\\&/g')
USER_PASS_ESC=$(printf '%s' "$USER_PASS" | sed 's/[\/&]/\\&/g')

arch-chroot "$ROOT_MOUNT" /bin/bash <<CHROOTEOF
set -euo pipefail

echo "LANG=$LOCALE" > /etc/locale.conf
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTSEOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTSEOF

sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi

if ! grep -q '^\[core_repo\]' /etc/pacman.conf; then
  cat >> /etc/pacman.conf << 'REPOEOF'

[core_repo]
SigLevel = Never
Server = https://sourcecorearch.github.io/core_repo/$arch
REPOEOF
fi

printf '%s:%s\n' root "$ROOT_PASS_ESC" | chpasswd

useradd -m -G "$USER_GROUPS" -s /usr/bin/fish "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS_ESC" | chpasswd

sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

if [[ -d /etc/skel/.config ]]; then
  cp -rn /etc/skel/. "$USER_HOME/"
  chown -R "$USERNAME:$USERNAME" "$USER_HOME/"
fi

mkdir -p "$USER_HOME/"{Imágenes,Proyectos,Descargas}
chown -R "$USERNAME:$USERNAME" "$USER_HOME/"{Imágenes,Proyectos,Descargas}

cat > /etc/systemd/zram-generator.conf << ZRAMEOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAMEOF

systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable docker
systemctl enable seatd
systemctl enable sddm

# ── SDDM autologin ───────────────────────────────────────────────
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << SDDMEOF
[Autologin]
User=$USERNAME
Session=niri
SDDMEOF

runuser -u "$USERNAME" -- rustup default stable 2>/dev/null || true

# ── Bootloader ──────────────────────────────────────────────────
if [[ "$BOOTLOADER" == "grub" ]]; then
  if [[ "$SYS_TYPE" == "uefi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  else
    grub-install --target=i386-pc "$DISK"
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
  pacman -Rns --noconfirm limine 2>/dev/null || true
elif [[ "$BOOTLOADER" == "limine" ]]; then
  if [[ "$SYS_TYPE" == "uefi" ]]; then
    # Instalar Limine UEFI copiando el stub EFI
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
    # Registrar entrada en NVRAM (fallo no fatal — funciona igual con BOOTX64.EFI)
    efibootmgr --create \
      --disk "${DISK}" --part 1 \
      --label "Helix Linux (Limine)" \
      --loader '\EFI\BOOT\BOOTX64.EFI' 2>/dev/null || true
  else
    limine bios-install "$DISK"
    cp /usr/share/limine/limine-bios.sys /boot/
  fi
  mkdir -p /boot/limine
  cat > /boot/limine.conf << LIMINEEOF
timeout: 5

/Helix Linux
  protocol: linux
  kernel_path: boot():/vmlinuz-linux
  cmdline: root=UUID=$ROOT_UUID rw rootflags=subvol=@ quiet splash
  module_path: boot():/initramfs-linux.img
LIMINEEOF
fi

# ── Snapper ───────────────────────────────────────────────────────
# snapper crea su propio subvolumen /.snapshots; hay que desmontar
# el @snapshots que ya montamos, dejar que snapper haga su trabajo,
# y luego reemplazarlo con nuestro subvolumen.
umount /.snapshots 2>/dev/null || true
rmdir /.snapshots 2>/dev/null || true
snapper -c root create-config /
# Eliminar el subvol que snapper acaba de crear y usar nuestro @snapshots
btrfs subvolume delete /.snapshots
mkdir -p /.snapshots
mount -o "compress=zstd:3,noatime,subvol=@snapshots" "$(findmnt -n -o SOURCE /)" /.snapshots || \
  mount -o "compress=zstd:3,noatime,subvol=@snapshots" "/dev/disk/by-uuid/$ROOT_UUID" /.snapshots
chmod 750 /.snapshots
snapper -c root set-config \
  "TIMELINE_CREATE=yes" \
  "TIMELINE_CLEANUP=yes" \
  "TIMELINE_MIN_AGE=1800" \
  "TIMELINE_LIMIT_HOURLY=5" \
  "TIMELINE_LIMIT_DAILY=7" \
  "TIMELINE_LIMIT_WEEKLY=0" \
  "TIMELINE_LIMIT_MONTHLY=0" \
  "TIMELINE_LIMIT_YEARLY=0"
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

CHROOTEOF

ok "Configuración completada."
echo ""

# ── Desmontar ──────────────────────────────────────────────────────────────────
info "Desmontando particiones..."
umount -R "$ROOT_MOUNT"
ok "Particiones desmontadas."
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  FINAL
# ═══════════════════════════════════════════════════════════════════════════════

banner
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   Instalación completada exitosamente            ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Hostname:    ${CYAN}$HOSTNAME${NC}"
echo -e "  Usuario:     ${CYAN}$USERNAME${NC}"
echo -e "  Bootloader:  ${CYAN}$BOOTLOADER${NC}"
echo -e "  Sistema:     ${CYAN}$SYS_TYPE${NC}"
echo ""
info "Ejecutá 'reboot' para reiniciar e iniciar Helix Linux."
echo ""
