#!/bin/bash
# First-login bootstrap: installs Flatpak applications as --user.
# Runs once per user via a systemd user service (post-install.service).
set -euo pipefail

FLAG="${XDG_DATA_HOME:-$HOME/.local/share}/.flatpaks-bootstrapped"

# Skip if already completed
if [ -f "$FLAG" ]; then
    echo "Flatpaks already bootstrapped — skipping."
    exit 0
fi

echo "Adding Flathub remote (user-level)…"
flatpak remote-add --user --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo
sleep 2

echo "Installing Flatpak applications (user-level)…"
flatpak install --user --noninteractive flathub \
    com.github.tchx84.Flatseal \
    com.mattjakeman.ExtensionManager \
    dev.geopjr.Tuba \
    org.gnome.Showtime \
    net.nokyan.Resources \
    org.gnome.Calculator \
    org.gnome.Characters \
    org.gnome.Clocks \
    org.gnome.Evince \
    org.gnome.Fractal \
    org.gnome.Logs \
    org.gnome.Loupe \
    org.gnome.Maps \
    org.gnome.Snapshot \
    org.gnome.TextEditor \
    org.gnome.Weather \
    org.gnome.font-viewer \
    org.mozilla.firefox \
    org.telegram.desktop \
    org.gnome.Extensions \
    org.keepassxc.KeePassXC \
    io.freetubeapp.FreeTube \
    io.github.totoshko88.RustConn \
    org.gnome.Calendar \
    org.gnome.Contacts \
    org.signal.Signal \
    org.freedesktop.Platform.VAAPI.Intel

# Mark as completed so this service won't run again
mkdir -p "$(dirname "$FLAG")"
touch "$FLAG"
echo "Flatpak bootstrap complete."
