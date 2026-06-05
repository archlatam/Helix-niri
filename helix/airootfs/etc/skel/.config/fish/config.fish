# ── Variables de entorno (login shell y interactivo) ─────────────────
# Se declaran fuera del bloque is-interactive para que estén
# disponibles cuando fish arranca niri desde una login shell.
set fish_greeting ""
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx TERM foot
set -gx XDG_SESSION_TYPE wayland
set -gx XDG_CURRENT_DESKTOP niri
set -gx QT_QPA_PLATFORM wayland
set -gx GDK_BACKEND wayland
set -gx SDL_VIDEODRIVER wayland
set -gx LIBSEAT_BACKEND seatd
set -gx NIXOS_OZONE_WL 1
set -gx MOZ_ENABLE_WAYLAND 1

# ── Arrancar niri en tty1 (autologin) ────────────────────────────────
# Debe ir antes del bloque is-interactive para que se ejecute
# incluso en shells no interactivas (login shell de getty).
if status is-login
    if test (tty) = /dev/tty1
        if not set -q WAYLAND_DISPLAY
            echo "Start Niri..."
            sleep 5
            exec dbus-run-session -- niri
        end
    end
end

# ── Configuración interactiva ─────────────────────────────────────────
if status is-interactive
    zoxide init fish | source
    starship init fish | source

    alias ls='eza --icons'
    alias ll='eza -la --icons --git'
    alias lt='eza --tree --icons --level=2'
    alias cat='bat --style=plain'
    alias vim='nvim'
    alias vi='nvim'
    alias g='git'
    alias lg='lazygit'
    alias dk='docker'
    alias dkc='docker compose'
end
