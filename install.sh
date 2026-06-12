#!/usr/bin/env bash
set -euo pipefail

echo "=== Arch Linux Automated Installer (LUKS2 + BTRFS + Limine) ==="

lsblk -f

# ========= USER INPUT =========
read -rp "Enter target disk (e.g. /dev/nvme0n1): " DISK
read -rp "Enter username: " USERNAME
read -srp "Enter user password: " USER_PASS
echo
read -srp "Enter root password: " ROOT_PASS
echo
read -srp "Enter LUKS encryption password: " LUKS_PASS
echo

# ========= GEO-LOCATION TIMEZONE =========
echo "Detecting timezone..."
TIMEZONE=$(curl -s https://ipapi.co/timezone || echo "UTC")
echo "Using timezone: $TIMEZONE"

# ========= PARTITIONING =========
echo "--- Partitioning $DISK ---"
sgdisk --zap-all "$DISK"
parted --script "$DISK" \
  mklabel gpt \
  mkpart ESP fat32 1MiB 2049MiB \
  set 1 esp on \
  mkpart Linux btrfs 2050MiB 100%

if [[ "$DISK" =~ nvme ]]; then
  BOOT="${DISK}p1"
  ROOT="${DISK}p2"
else
  BOOT="${DISK}1"
  ROOT="${DISK}2"
fi

ESP="$BOOT"

# ========= FORMAT ESP =========
mkfs.fat -F 32 "$ESP"

# ========= ENCRYPT + BTRFS =========
echo "--- Setting up LUKS2 encrypted BTRFS partition ---"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

mkfs.btrfs /dev/mapper/root
mount /dev/mapper/root /mnt

for sub in @ @home @var_log @pkg; do
  btrfs subvolume create "/mnt/$sub"
done

umount /mnt

# do not use mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg
# mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots /dev/mapper/root /mnt/.snapshots
mount --mkdir "$ESP" /mnt/boot

# ========= INSTALL BASE SYSTEM =========
echo "--- Installing base system ---"
pacman -Sy --needed --noconfirm archlinux-keyring reflector

reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- PACMAN CONF WITH MULTILIB + CORE_REPO ---
PACMAN_CONF=$(mktemp /tmp/pacman-online-XXXXXXXX.conf)
cat >"$PACMAN_CONF" <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[core_repo]
SigLevel = Never
Server = https://sourcecorearch.github.io/$repo/$arch
EOF

pacstrap -C "$PACMAN_CONF" -K /mnt \
  base base-devel linux linux-firmware linux-headers \
  sudo curl wget neovim lua \
  git lazygit github-cli \
  btrfs-progs dosfstools \
  limine efibootmgr binutils \
  amd-ucode intel-ucode \
  cryptsetup \
  networkmanager iwd \
  bluez bluez-utils \
  pipewire pipewire-alsa pipewire-pulse wireplumber sof-firmware \
  niri xwayland-satellite \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
  polkit polkit-kde-agent qt6-wayland qt5-wayland \
  sddm \
  fuzzel foot \
  grim slurp wl-clipboard wl-mirror \
  swayidle swaylock swaybg \
  brightnessctl playerctl \
  noto-fonts noto-fonts-emoji noto-fonts-cjk \
  ttf-jetbrains-mono-nerd papirus-icon-theme \
  plymouth zram-generator \
  nodejs npm go rustup \
  docker docker-compose podman \
  eza bat fzf ripgrep fd zoxide jq tree zip reflector pacman-contrib \
  sequoia-sq openpgp-card-tools seatd \
  btop fastfetch starship fish \
  thunar gvfs tumbler mpv imv pipewire-jack \
  paru noctalia-shell noctalia-qs \
  dhcpcd firewalld acpid avahi rsync bash-completion duf

genfstab -U /mnt >>/mnt/etc/fstab

sleep 5
echo ""
echo ""
echo "CHROOT"

# ========= CHROOT CONFIGURATION =========
arch-chroot /mnt /usr/bin/env \
    TIMEZONE="$TIMEZONE" \
    ROOT_PASS="$ROOT_PASS" \
    USERNAME="$USERNAME" \
    USER_PASS="$USER_PASS" \
    DISK="$DISK" \
    ROOT="$ROOT" \
    /bin/bash -e <<'EOF'
# --- TIMEZONE ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# --- LOCALE ---
sed -i 's/^#es_AR.UTF-8 UTF-8/es_AR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=es_AR.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf

# --- HOSTNAME ---
echo "arch" > /etc/hostname

# --- ROOT PASSWORD ---
echo "root:$ROOT_PASS" | chpasswd

# --- USER SETUP ---
useradd -mG wheel $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- COPY SKEL CONFIG ---
if [[ -d /etc/skel/.config ]]; then
  cp -a /etc/skel/. "/home/${USERNAME}/"
  chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/"
fi

# --- PACMAN CONF WITH MULTILIB + CORE_REPO ---
cat > /etc/pacman.conf << 'PACEOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
Color
VerbosePkgLists
ParallelDownloads = 8
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[core_repo]
SigLevel = Never
Server = https://sourcecorearch.github.io/$repo/$arch
PACEOF

# --- MKINITCPIO CONFIG ---
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^#BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- LIMINE SETUP ---
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/

efibootmgr --create --disk $DISK --part 1 \
      --label "Arch Linux Limine Bootloader" \
      --loader '\\EFI\\limine\\BOOTX64.EFI' \
      --unicode

LUKS_UUID=$(cryptsetup luksUUID "$ROOT")

cat <<LIMINECONF > /boot/EFI/limine/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet splash cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet splash cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

sleep 4

# --- ENABLE SERVICES ---
for s in NetworkManager dhcpcd iwd systemd-networkd systemd-resolved bluetooth avahi-daemon firewalld acpid reflector.timer sddm; do
    systemctl enable $s
done

EOF

# ========= FINAL CLEANUP =========
echo "--- Cleaning up ---"
sync
sleep 2
umount -R /mnt || echo "Some mounts could not be unmounted, continuing..."
cryptsetup close root

echo "=== Installation complete! Reboot now and remove installation media. ==="
