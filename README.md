# Helix Linux

ISO de Arch Linux con el compositor **niri** y el entorno **Noctalia** (noctalia-shell + noctalia-qs).

## Requisitos

- `archiso` instalado en el sistema host
- `pacman` con `pacman-contrib`

## Construir la ISO

```bash
# 1. Clonar el repositorio
git clone https://github.com/tu-usuario/helix-niri.git
cd helix-niri

# 2. Crear el repositorio local de paquetes
mkdir -p archlatam/x86_64

# 3. Copiar los paquetes .pkg.tar.zst al repositorio local
cp *.pkg.tar.zst archlatam/x86_64/

# 4. Generar la base de datos del repositorio local
cd archlatam/x86_64
repo-add archlatam.db.tar.gz *.pkg.tar.zst
cd ../..

# 5. Crear directorios de trabajo
mkdir -p out work

# 6. Construir la ISO
sudo mkarchiso -v -w work -o out helix
```

La ISO generada estará en `out/` con el nombre `helix-*.iso`.

## Vista previa

![Helix Linux - niri + Noctalia](.assets/niri-desktop.png)
