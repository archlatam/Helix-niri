#!/usr/bin/env bash
# =============================================================================
#  helix-install — Instalador para Helix Linux (archlatam/Helix-niri)
#
#  Uso (desde la ISO live):
#    curl -fsSL https://raw.githubusercontent.com/archlatam/Helix-niri/main/install.sh | bash
#    — o —
#    bash install.sh
#
#  Qué hace:
#    - Particiona el disco elegido (GPT: EFI 2048M + Btrfs resto)
#    - Subvólumenes @  @home  @snapshots  @log  @cache
#    - Instala desde repo offline si está en la ISO, si no usa internet
#    - Instala paquetes locales noctalia-shell y noctalia-qs del repo
#    - Copia toda la configuración de /etc/skel (igual que la ISO live)
#    - Limine como bootloader EFI
#    - SDDM con autologin + sesión niri
#    - Plymouth splash
#    - Pide: disco, usuario, contraseña, hostname, timezone, locale
# =============================================================================

set -euo pipefail

# =============================================================================
#  Colores / helpers
# =============================================================================
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' W='\033[1m' N='\033[0m'

info() { echo -e "${B}${W} ==> ${N}${W}$*${N}"; }
ok() { echo -e "${G}${W} ✓  ${N}$*"; }
warn() { echo -e "${Y}${W} !  ${N}$*"; }
die() {
  echo -e "${R}${W} ✗  $*${N}" >&2
  exit 1
}
ask() { echo -e "${W}$*${N}"; } # prompt label

banner() {
  echo -e "${B}${W}"
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │                                          │"
  echo "  │   Helix Linux — Instalador v0.2.0        │"
  echo "  │   niri + Noctalia + Btrfs + Limine        │"
  echo "  │                                          │"
  echo "  └──────────────────────────────────────────┘"
  echo -e "${N}"
}

# =============================================================================
#  Variables globales (se rellenan interactivamente)
# =============================================================================
TARGET_DISK=""
USERNAME=""
USER_PASS=""
ROOT_PASS=""
HOSTNAME=""
TIMEZONE=""
LOCALE=""
KEYMAP=""

EFI_PART=""
ROOT_PART=""
PACMAN_CONF="/etc/pacman.conf"
OFFLINE_MODE=false

# Paquetes locales en el repo del proyecto (en la ISO o junto al script)
LOCAL_PKGS_DIR="/var/cache/offline-repo" # ruta en la ISO live
LOCAL_PKG_NAMES=("noctalia-shell" "noctalia-qs")

# Paquetes a instalar vía pacstrap
PACKAGES=(
  # Base
  base base-devel linux linux-firmware linux-headers
  sudo curl wget

  # Editores
  neovim lua

  # Git
  git lazygit github-cli

  # Filesystem / boot
  btrfs-progs dosfstools
  limine efibootmgr binutils
  amd-ucode intel-ucode

  # Red
  networkmanager iwd
  bluez bluez-utils

  # Audio
  pipewire pipewire-alsa pipewire-pulse wireplumber
  sof-firmware

  # Wayland / niri
  niri
  xwayland-satellite
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk
  polkit polkit-kde-agent
  qt6-wayland qt5-wayland

  # Display manager
  sddm

  # Herramientas del escritorio
  fuzzel foot
  grim slurp wl-clipboard wl-mirror
  swayidle swaylock swaybg
  brightnessctl playerctl

  # quickshell (dep de noctalia)
  noctalia-shell
  noctalia-qs

  # Fuentes e iconos
  noto-fonts noto-fonts-emoji noto-fonts-cjk
  ttf-jetbrains-mono-nerd
  papirus-icon-theme

  # Plymouth
  plymouth

  # zram
  zram-generator

  # Snapshots Btrfs
  snapper snap-pac
  limine-snapper-sync
  # son AUR — disponibles en core_repo
  limine-mkinitcpio-hook

  # Lenguajes
  nodejs npm go rustup

  # Contenedores
  docker docker-compose podman

  # CLI tools
  eza bat fzf ripgrep fd zoxide jq tree zip reflector pacman-contrib
  sequoia-sq openpgp-card-tools

  # Utilidades
  btop fastfetch starship fish
  thunar gvfs tumbler
  mpv imv
  pipewire-jack
  paru
)

# =============================================================================
#  Verificaciones
# =============================================================================
check_requirements() {
  info "Verificando entorno..."
  [[ "$(id -u)" -eq 0 ]] || die "Corré el script como root"
  [[ -d /sys/firmware/efi ]] || die "Requiere UEFI"
  command -v pacstrap &>/dev/null || die "pacstrap no encontrado — ¿estás en la ISO?"
  command -v sgdisk &>/dev/null || die "sgdisk no encontrado (instala gptfdisk)"
  ok "Entorno OK"
}

# =============================================================================
#  Preguntas interactivas
# =============================================================================
ask_disk() {
  echo
  info "Discos disponibles:"
  lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
  echo
  while true; do
    ask "Disco a usar (ej: /dev/nvme0n1 o /dev/sda): "
    read -r TARGET_DISK
    [[ -b "$TARGET_DISK" ]] && break
    warn "$TARGET_DISK no es un dispositivo de bloque válido, intentá de nuevo"
  done
  echo
  warn "⚠  Se borrará TODO el contenido de $TARGET_DISK"
  ask "Escribí 'si' para confirmar: "
  read -r _confirm
  [[ "$_confirm" == "si" ]] || die "Instalación cancelada por el usuario"
}

ask_user() {
  echo
  while true; do
    ask "Nombre de usuario: "
    read -r USERNAME
    [[ -n "$USERNAME" && "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    warn "Nombre inválido (solo letras minúsculas, números, _ y -)"
  done

  ask "Contraseña para $USERNAME: "
  read -rs USER_PASS
  echo
  ask "Confirmar contraseña:       "
  read -rs _up2
  echo
  [[ "$USER_PASS" == "$_up2" ]] || die "Las contraseñas no coinciden"

  ask "Contraseña para root:       "
  read -rs ROOT_PASS
  echo
  ask "Confirmar contraseña root:  "
  read -rs _rp2
  echo
  [[ "$ROOT_PASS" == "$_rp2" ]] || die "Las contraseñas root no coinciden"
}

ask_system() {
  echo
  ask "Hostname [helix]: "
  read -r HOSTNAME
  HOSTNAME="${HOSTNAME:-helix}"

  echo
  info "Ejemplos de timezone: America/Argentina/Buenos_Aires  America/Argentina/Buenos_Aires"
  ask "Timezone [America/Argentina/Buenos_Aires]: "
  read -r TIMEZONE
  TIMEZONE="${TIMEZONE:-America/Argentina/Buenos_Aires}"

  echo
  info "Ejemplos de locale: es_AR.UTF-8  es_ES.UTF-8  en_US.UTF-8"
  ask "Locale [es_AR.UTF-8]: "
  read -r LOCALE
  LOCALE="${LOCALE:-es_AR.UTF-8}"

  echo
  info "Ejemplos de keymap: la-latin1  es  us"
  ask "Keymap de consola [la-latin1]: "
  read -r KEYMAP
  KEYMAP="${KEYMAP:-la-latin1}"
}

# =============================================================================
#  Particionado
# =============================================================================
partition_disk() {
  info "Particionando $TARGET_DISK..."

  # Prefijo de partición
  if [[ "$TARGET_DISK" =~ nvme|mmcblk ]]; then
    PART_PREFIX="${TARGET_DISK}p"
  else
    PART_PREFIX="${TARGET_DISK}"
  fi
  EFI_PART="${PART_PREFIX}1"
  ROOT_PART="${PART_PREFIX}2"

  wipefs -af "$TARGET_DISK" >/dev/null
  sgdisk -Z "$TARGET_DISK" >/dev/null
  sgdisk -n 1:0:+2048M -t 1:ef00 -c 1:"EFI System" "$TARGET_DISK" >/dev/null
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$TARGET_DISK" >/dev/null
  partprobe "$TARGET_DISK"
  sleep 1

  ok "Particiones: EFI=$EFI_PART  ROOT=$ROOT_PART"
}

# =============================================================================
#  Formateo y montaje Btrfs
# =============================================================================
format_and_mount() {
  info "Formateando..."
  mkfs.fat -F32 -n EFI "$EFI_PART" >/dev/null
  mkfs.btrfs -f -L ROOT "$ROOT_PART" >/dev/null

  info "Creando subvólumenes Btrfs..."
  mount "$ROOT_PART" /mnt
  for sv in @ @home @snapshots @log @cache; do
    btrfs subvolume create "/mnt/$sv" >/dev/null
  done
  umount /mnt

  info "Montando..."
  local OPTS="noatime,compress=zstd:1,space_cache=v2"
  mount -o "${OPTS},subvol=@" "$ROOT_PART" /mnt
  mkdir -p /mnt/{home,.snapshots,var/log,var/cache,boot/efi}
  mount -o "${OPTS},subvol=@home" "$ROOT_PART" /mnt/home
  mount -o "${OPTS},subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
  mount -o "${OPTS},subvol=@log" "$ROOT_PART" /mnt/var/log
  mount -o "${OPTS},subvol=@cache" "$ROOT_PART" /mnt/var/cache
  mount "$EFI_PART" /mnt/boot/efi

  ok "Sistema de archivos montado"
}

# =============================================================================
#  Detección repo offline / online
# =============================================================================
setup_pacman() {
  if [[ -d "$LOCAL_PKGS_DIR" && -f "$LOCAL_PKGS_DIR/offline.db" ]]; then
    warn "Repo offline detectado → $LOCAL_PKGS_DIR"
    PACMAN_CONF=$(mktemp /tmp/pacman-offline-XXXXXXXX.conf)
    cat >"$PACMAN_CONF" <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
SigLevel          = Never
LocalFileSigLevel = Optional

[offline]
SigLevel = Never
Server   = file:///var/cache/offline-repo/
EOF
    OFFLINE_MODE=true
    ok "Modo offline activado"
  else
    info "Usando repositorios online"
    OFFLINE_MODE=false
    # Crear pacman.conf temporal con repos oficiales + core_repo
    PACMAN_CONF=$(mktemp /tmp/pacman-online-XXXXXXXX.conf)
    cat >"$PACMAN_CONF" <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
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
EOF
    ok "Modo online — pacman.conf con core_repo"
  fi
}

# =============================================================================
#  Actualizar mirrors con reflector (top 10)
# =============================================================================
update_mirrors() {
  info "Actualizando mirrors con reflector..."
  if command -v reflector &>/dev/null; then
    reflector --latest 10 --sort score --protocol https \
      --connection-timeout 3 --download-timeout 3 \
      --save /etc/pacman.d/mirrorlist 2>&1 &&
      ok "Mirrors actualizados (top 10)" ||
      warn "reflector falló — usando mirrors actuales"
  else
    warn "reflector no instalado — usando mirrors actuales"
  fi
}

# =============================================================================
#  pacstrap
# =============================================================================
install_base() {
  info "Instalando sistema base con pacstrap..."
  pacstrap -C "$PACMAN_CONF" -K /mnt "${PACKAGES[@]}"
  ok "pacstrap completado"
}

# =============================================================================
#  Instalar paquetes locales (.pkg.tar.zst) del repo — noctalia-shell, noctalia-qs
# =============================================================================
install_local_packages() {
  # Buscar los .pkg.tar.zst en varias ubicaciones posibles
  local search_dirs=(
    "$LOCAL_PKGS_DIR"
    "$(dirname "$(realpath "$0")" 2>/dev/null || echo /root)"
    "/root"
    "/run/archiso/bootmnt"
  )

  local found_pkgs=()
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' pkg; do
      found_pkgs+=("$pkg")
    done < <(find "$dir" -maxdepth 2 -name "noctalia-*.pkg.tar.zst" -print0 2>/dev/null)
  done

  if [[ ${#found_pkgs[@]} -eq 0 ]]; then
    warn "No se encontraron paquetes locales noctalia-*.pkg.tar.zst"
    warn "Intentando desde AUR con paru si está disponible..."
    return 0
  fi

  info "Copiando paquetes locales al sistema instalado..."
  local pkg_dest="/mnt/var/cache/pacman/pkg"
  mkdir -p "$pkg_dest"

  for pkg in "${found_pkgs[@]}"; do
    cp "$pkg" "$pkg_dest/"
    ok "Copiado: $(basename "$pkg")"
  done

  info "Instalando paquetes locales con pacman en chroot..."
  # Construir lista de paths dentro del chroot
  local chroot_pkgs=()
  for pkg in "${found_pkgs[@]}"; do
    chroot_pkgs+=("/var/cache/pacman/pkg/$(basename "$pkg")")
  done

  arch-chroot /mnt pacman -U --noconfirm --needed "${chroot_pkgs[@]}" ||
    warn "Algún paquete local falló al instalar — verificá manualmente"

  ok "Paquetes locales instalados"
}

# =============================================================================
#  Copiar configuración del skel (igual que la ISO live)
# =============================================================================
copy_skel_config() {
  info "Copiando configuración de /etc/skel al nuevo sistema..."

  # En archiso, el skel suele estar en /etc/skel o dentro del squashfs
  local skel_sources=(
    "/etc/skel"
    "/run/archiso/airootfs/etc/skel"
  )

  local skel_found=false
  for skel in "${skel_sources[@]}"; do
    if [[ -d "$skel/.config" || -d "$skel/.local" ]]; then
      info "Skel encontrado en $skel"
      # Copiar al skel del sistema instalado (para nuevos usuarios futuros)
      cp -a "$skel/." /mnt/etc/skel/ 2>/dev/null || true
      skel_found=true
      break
    fi
  done

  if [[ "$skel_found" == false ]]; then
    warn "No se encontró skel con configuraciones del live — el usuario tendrá config mínima"
  else
    ok "Skel copiado"
  fi
}

# =============================================================================
#  fstab
# =============================================================================
gen_fstab() {
  info "Generando fstab..."
  genfstab -U /mnt >>/mnt/etc/fstab
  ok "fstab generado"
}

# =============================================================================
#  Configuración dentro del chroot
# =============================================================================
configure_chroot() {
  info "Configurando sistema (chroot)..."

  # Exportar variables para el heredoc
  arch-chroot /mnt /usr/bin/env \
    HOSTNAME="$HOSTNAME" \
    TIMEZONE="$TIMEZONE" \
    LOCALE="$LOCALE" \
    KEYMAP="$KEYMAP" \
    USERNAME="$USERNAME" \
    USER_PASS="$USER_PASS" \
    ROOT_PASS="$ROOT_PASS" \
    EFI_PART="$EFI_PART" \
    ROOT_PART="$ROOT_PART" \
    /bin/bash <<'CHROOT_END'

set -euo pipefail

# Escribir pacman.conf con core_repo al inicio para que todos los pacman -S funcionen
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

echo "[chroot] Hostname..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

echo "[chroot] Timezone..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "[chroot] Locale..."
# Descomentar el locale elegido y en_US como fallback
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "[chroot] Keymap..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "[chroot] mkinitcpio..."
# Agregar btrfs a módulos y plymouth al hook
sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
# btrfs-overlayfs al final de HOOKS permite bootear snapshots read-only de snapper
# (los monta con OverlayFS para que /var sea escribible sin modificar el snapshot)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck plymouth btrfs-overlayfs)/' \
    /etc/mkinitcpio.conf
mkinitcpio -P

echo "[chroot] Contraseña root..."
echo "root:${ROOT_PASS}" | chpasswd

echo "[chroot] Usuario $USERNAME..."
useradd -m -G wheel,video,audio,input,seat,power -s /usr/bin/fish "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
# wheel sin contraseña de sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "[chroot] Copiar skel al home del usuario..."
# useradd ya copió el skel, pero si hay config nueva la aplicamos
if [[ -d /etc/skel/.config ]]; then
  cp -a /etc/skel/. "/home/${USERNAME}/"
  chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/"
fi

echo "[chroot] Servicios..."
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable docker
systemctl enable seatd
systemctl enable sddm
systemctl enable plymouth-quit-wait.service 2>/dev/null || true

echo "[chroot] zram..."
cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

echo "[chroot] SDDM + autologin..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << EOF
[Autologin]
User=${USERNAME}
Session=niri
Relogin=false
EOF

# Verificar que la sesión niri.desktop exista
if [[ ! -f /usr/share/wayland-sessions/niri.desktop ]]; then
  mkdir -p /usr/share/wayland-sessions
  cat > /usr/share/wayland-sessions/niri.desktop << 'EOF'
[Desktop Entry]
Name=Niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
EOF
fi

echo "[chroot] Plymouth theme..."
# Usar el tema que traiga la ISO si existe, si no bgrt
PLYMOUTH_THEME=$(plymouth-set-default-theme 2>/dev/null | head -1 || echo "bgrt")
plymouth-set-default-theme -R "$PLYMOUTH_THEME" 2>/dev/null || true

echo "[chroot] Config de niri mínima si no hay skel..."
NIRI_CFG="/home/${USERNAME}/.config/niri/config.kdl"
if [[ ! -f "$NIRI_CFG" ]]; then
  mkdir -p "$(dirname "$NIRI_CFG")"
  cat > "$NIRI_CFG" << 'EOF'
// Configuración mínima de niri — editá según tu gusto
// Documentación: https://github.com/YaLTeR/niri/wiki/Configuration

input {
  keyboard {
    xkb {
      layout "latam"
    }
  }
  touchpad {
    tap
    natural-scroll
  }
}

layout {
  gaps 8
  preset-column-widths {
    proportion 0.33333
    proportion 0.5
    proportion 0.66667
  }
  default-column-width { proportion 0.5; }
  focus-ring {
    width 2
    active-color "#7fc8ff"
    inactive-color "#505050"
  }
}

prefer-no-csd

screenshot-path "~/Imágenes/Capturas/captura-%Y-%m-%dT%H:%M:%S.png"

animations { }

binds {
  Mod+Return      { spawn "foot"; }
  Mod+D           { spawn "fuzzel"; }
  Mod+Shift+Q     { close-window; }
  Mod+Shift+E     { quit; }

  Mod+Left        { focus-column-left; }
  Mod+Right       { focus-column-right; }
  Mod+Up          { focus-window-up; }
  Mod+Down        { focus-window-down; }
  Mod+Shift+Left  { move-column-left; }
  Mod+Shift+Right { move-column-right; }

  Mod+1 { focus-workspace 1; }
  Mod+2 { focus-workspace 2; }
  Mod+3 { focus-workspace 3; }
  Mod+4 { focus-workspace 4; }
  Mod+5 { focus-workspace 5; }
  Mod+Shift+1 { move-window-to-workspace 1; }
  Mod+Shift+2 { move-window-to-workspace 2; }
  Mod+Shift+3 { move-window-to-workspace 3; }
  Mod+Shift+4 { move-window-to-workspace 4; }
  Mod+Shift+5 { move-window-to-workspace 5; }

  Mod+F           { maximize-column; }
  Mod+Shift+F     { fullscreen-window; }
  Mod+O           { toggle-overview; }

  Print           { screenshot; }
  Ctrl+Print      { screenshot-screen; }
  Alt+Print       { screenshot-window; }

  XF86AudioRaiseVolume  allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+"; }
  XF86AudioLowerVolume  allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"; }
  XF86AudioMute         allow-when-locked=true { spawn "wpctl" "set-mute"   "@DEFAULT_AUDIO_SINK@" "toggle"; }
  XF86MonBrightnessUp   { spawn "brightnessctl" "s" "+10%"; }
  XF86MonBrightnessDown { spawn "brightnessctl" "s" "10%-"; }
}

spawn-at-startup "xwayland-satellite"
EOF
  chown "${USERNAME}:${USERNAME}" "$NIRI_CFG"
fi

mkdir -p "/home/${USERNAME}/Imágenes/Capturas"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/Imágenes"

echo "[chroot] Instalando Rust toolchain stable..."
runuser -u "${USERNAME}" -- rustup default stable || true

echo "[chroot] Limine bootloader..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# Detectar disco y número de partición EFI
if [[ "$EFI_PART" =~ (.*[a-z])([0-9]+)$ ]]; then
  DISK="${BASH_REMATCH[1]}"
  PART_NUM="${BASH_REMATCH[2]}"
  [[ "$DISK" =~ p$ ]] && DISK="${DISK%p}"
fi

# 1. Copiar BOOTX64.EFI a la ESP
EFI_DIR="/boot/efi"
mkdir -p "${EFI_DIR}/EFI/BOOT" "${EFI_DIR}/EFI/limine"
cp /usr/share/limine/BOOTX64.EFI "${EFI_DIR}/EFI/BOOT/BOOTX64.EFI"
cp /usr/share/limine/BOOTX64.EFI "${EFI_DIR}/EFI/limine/BOOTX64.EFI"

# Eliminar hook alpm que ejecuta limine-install automáticamente (falla en chroot y corrompe /etc/default/limine)
rm -f /usr/share/libalpm/hooks/80-limine-efi-deploy.hook

# 2. Detectar kernel y generar limine.conf manualmente (sin hooks alpm)
echo "[chroot] Detectando kernel..."
KERNEL_IMG=$(ls /boot/vmlinuz-linux 2>/dev/null | head -1)
INITRD_IMG=$(ls /boot/initramfs-linux.img 2>/dev/null | head -1)
INITRD_FB=$(ls /boot/initramfs-linux-fallback.img 2>/dev/null || true)

echo "[chroot] Generando /boot/limine.conf..."
cat > /boot/limine.conf << LIMEOF
timeout: 5
default_entry: 1

/:Helix Linux
  comment: Arch Linux — niri + Noctalia
  protocol: linux
  kernel_path: boot():/$(basename "$KERNEL_IMG")
  cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0
  module_path: boot():/$(basename "$INITRD_IMG")
LIMEOF

if [[ -n "$INITRD_FB" ]]; then
  cat >> /boot/limine.conf << LIMEOF

/:Helix Linux (fallback)
  comment: Arch Linux — sin splash, initramfs fallback
  protocol: linux
  kernel_path: boot():/$(basename "$KERNEL_IMG")
  cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw
  module_path: boot():/$(basename "$INITRD_FB")
LIMEOF
fi

# 3. Configurar limine-snapper-sync (TARGET_OS_NAME para los snapshots)
if [[ -f /etc/limine-snapper-sync.conf ]]; then
  sed -i 's/TARGET_OS_NAME=".*"/TARGET_OS_NAME="Helix Linux"/' /etc/limine-snapper-sync.conf
fi

# 4. Hook mkinitcpio sd-btrfs-overlayfs (necesario para bootear snapshots con limine-snapper-sync)
cat > /etc/mkinitcpio.conf.d/10-limine-snapper-sync.conf << 'EOF'
HOOKS+=(sd-btrfs-overlayfs)
EOF

# 5. Registrar en NVRAM (falla en chroot, se ignora)
if efibootmgr --create \
  --disk "/dev/$DISK" \
  --part "$PART_NUM" \
  --label "Helix Linux (Limine)" \
  --loader "EFI/BOOT/BOOTX64.EFI" \
  2>/dev/null; then
  echo "[chroot] ✓ Limine registrado en UEFI"
else
  echo "[chroot] ⚠ efibootmgr no disponible en chroot — registralo manualmente al reiniciar:"
  echo "[chroot]    efibootmgr --create --disk /dev/$DISK --part $PART_NUM --label 'Helix Linux' --loader '\\EFI\\limine\\BOOTX64.EFI'"
fi

echo "[chroot] Snapper..."

# Guard: si no es Btrfs, remover snapper stack
if [[ $(findmnt -n -o FSTYPE /) != "btrfs" ]]; then
  echo "[chroot] Non-Btrfs detected, removing Snapper stack..."
  pacman -Rns --noconfirm snapper snap-pac 2>/dev/null || true
else
  # Desmontar /.snapshots para que snapper pueda crear su propio subvol
  umount /.snapshots 2>/dev/null || true
  rm -rf /.snapshots

  snapper -c root create-config /

  # Re-montar el @snapshots que creamos antes (snapper habría creado el suyo)
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots
  mount /.snapshots

  # Permisos para que wheel pueda listar snapshots sin sudo
  chmod 750 /.snapshots
  chown ":wheel" /.snapshots

  # Timeline limits
  sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/'   /etc/snapper/configs/root
  sed -i 's/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP="yes"/' /etc/snapper/configs/root
  sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/'               /etc/snapper/configs/root
  sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'   /etc/snapper/configs/root
  sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/'     /etc/snapper/configs/root
  sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="4"/'   /etc/snapper/configs/root
  sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="3"/' /etc/snapper/configs/root
  sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="1"/'   /etc/snapper/configs/root

  # Snapper config for /home (si existe como subvolumen)
  if [[ -d /home ]] && [[ ! -f /etc/snapper/configs/home ]]; then
    snapper -c home create-config /home
  fi

  # Initial snapshots
  snapper --no-dbus -c root create --description "Initial system snapshot" --cleanup-algorithm number
  if [[ -f /etc/snapper/configs/home ]]; then
    snapper --no-dbus -c home create --description "Initial home snapshot" --cleanup-algorithm number
  fi

  systemctl enable snapper-timeline.timer
  systemctl enable snapper-cleanup.timer
fi

# limine-snapper-sync — sincroniza entradas de Limine con snapshots de snapper
# Habilitar el watcher si está instalado (paquete AUR del repo local)
if systemctl list-unit-files limine-snapper-watcher.service &>/dev/null; then
  systemctl enable limine-snapper-watcher.service
  echo "[chroot] limine-snapper-watcher habilitado"
else
  echo "[chroot] WARN: limine-snapper-watcher no encontrado — instalalo desde AUR después"
  echo "[chroot]       yay -S limine-snapper-sync limine-mkinitcpio-hook"
fi

echo "[chroot] Detectando CPU para microcode..."
if grep -q GenuineIntel /proc/cpuinfo; then
  echo "[chroot] CPU Intel — removiendo amd-ucode..."
  pacman -R --noconfirm amd-ucode 2>/dev/null || true
elif grep -q AuthenticAMD /proc/cpuinfo; then
  echo "[chroot] CPU AMD — removiendo intel-ucode..."
  pacman -R --noconfirm intel-ucode 2>/dev/null || true
fi

echo "[chroot] ¡Listo!"
CHROOT_END

  ok "Chroot completado"
}

# =============================================================================
#  Limpieza
# =============================================================================
finish() {
  info "Desmontando..."
  umount -R /mnt 2>/dev/null || true

  # Eliminar pacman.conf temporal si se creó
  if [[ "$PACMAN_CONF" == /tmp/pacman-* && -f "$PACMAN_CONF" ]]; then
    rm -f "$PACMAN_CONF"
  fi

  echo
  echo -e "${G}${W}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║                                              ║"
  echo "  ║   🎉  Instalación completada con éxito!      ║"
  echo "  ║                                              ║"
  echo "  ║   Podés reiniciar ahora:                     ║"
  echo "  ║   $ reboot                                   ║"
  echo "  ║                                              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${N}"
}

# =============================================================================
#  Resumen antes de empezar
# =============================================================================
show_summary() {
  echo
  echo -e "${W}┌─ Resumen de instalación ─────────────────────────────┐${N}"
  echo -e "  Disco:     ${Y}${TARGET_DISK}${N}"
  echo -e "  EFI:       ${EFI_PART}  (2048M, FAT32)"
  echo -e "  Root:      ${ROOT_PART}  (Btrfs — @  @home  @snapshots  @log  @cache)"
  echo -e "  Usuario:   ${Y}${USERNAME}${N}"
  echo -e "  Hostname:  ${HOSTNAME}"
  echo -e "  Timezone:  ${TIMEZONE}"
  echo -e "  Locale:    ${LOCALE}"
  echo -e "  Keymap:    ${KEYMAP}"
  echo -e "  Modo:      $([[ "$OFFLINE_MODE" == true ]] && echo "offline 📦" || echo "online 🌐")"
  echo -e "${W}└──────────────────────────────────────────────────────┘${N}"
  echo
  ask "¿Todo correcto? Escribí 'si' para comenzar: "
  read -r _go
  [[ "$_go" == "si" ]] || die "Cancelado"
}

# =============================================================================
#  Main
# =============================================================================
main() {
  banner
  check_requirements

  # Recolectar toda la info antes de tocar el disco
  ask_disk
  ask_user
  ask_system
  setup_pacman
  update_mirrors

  show_summary

  # A partir de aquí se modifica el sistema
  partition_disk
  format_and_mount
  install_base
  install_local_packages
  copy_skel_config
  gen_fstab
  configure_chroot

  finish
}

main "$@"
