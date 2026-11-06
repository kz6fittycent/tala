#!/bin/bash
# Adds a launcher for this local build, which also gives the window its icon on
# Wayland. Remove with: rm ~/.local/share/applications/io.github.kz6fittycent.tala.desktop
here="$(cd "$(dirname "$0")/.." && pwd)"
apps="$HOME/.local/share/applications"
mkdir -p "$apps"
cat > "$apps/io.github.kz6fittycent.tala.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Tala
Comment=Chat and calls for Nextcloud Talk
Exec=$here/build/linux/x64/release/bundle/tala
Icon=$here/assets/icon/tala-512.png
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=io.github.kz6fittycent.tala
DESKTOP
update-desktop-database "$apps" 2>/dev/null || true
