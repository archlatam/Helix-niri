# Remove waybar from PACKAGES

## Change
In `install.sh`, lines 108-112, remove `waybar` from the PACKAGES array.

**Before:**
```bash
  swayidle swaylock swaybg
  brightnessctl playerctl
  waybar

  # quickshell (dep de noctalia)
  noctalia-shell
```

**After:**
```bash
  swayidle swaylock swaybg
  brightnessctl playerctl

  # quickshell (dep de noctalia)
  noctalia-shell
```
