#!/usr/bin/env bash
set -e

pacman-key --init
pacman-key --populate archlinux

pacman -Qqe | pacman -D --asexplicit -

echo "==> [HELIX] Generando locales..."
locale-gen

echo "==> [HELIX] Configurando timezone Argentina..."
ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime

echo "==> [HELIX] Activando colores en pacman..."
sed -i 's/#Color/Color/'                     /etc/pacman.conf
sed -i 's/#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
sed -i '/^#ParallelDownloads/s/^#//'         /etc/pacman.conf

echo "==> [HELIX] Creando usuario helix..."
useradd -m \
  -G wheel,docker,storage,audio,video,input,seat \
  -s /usr/bin/fish helix
echo "root:helix"  | chpasswd
echo "helix:helix" | chpasswd

echo "==> [HELIX] Configurando shell de root..."
chsh -s /usr/bin/fish root

echo "==> [HELIX] Habilitando servicios..."
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable docker
systemctl enable seatd

echo "==> [HELIX] Copiando configs al home de helix..."
cp -rn /etc/skel/. /home/helix/
mkdir -p /home/helix/{Imágenes,Proyectos,Descargas}
chown -R helix:helix /home/helix/

echo "==> [HELIX] Instalando Rust toolchain stable..."
runuser -u helix -- rustup default stable || true

echo "==> [HELIX] ¡Build completado exitosamente!"
