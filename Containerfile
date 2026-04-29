# 1. Base: Use official Fedora 44 bootc
FROM quay.io/fedora/fedora-bootc:44

RUN set -euo pipefail

# 2. Setup Repositories
RUN dnf5 -y --refresh install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm" && \
    # Direct download of COPR repo file to avoid dnf5 plugin issues
    curl -L -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
    https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-44/mulderje-facetimehd-kmod-fedora-44.repo

# 3. Install Budgie Desktop (Onyx) and Essential Tools
# Includes WireGuard, Toolbox, and Silverblue-standard packages
RUN dnf5 -y group install "Budgie Desktop" && \
    dnf5 -y --refresh install \
    budgie-desktop-services gtklock polkit \
    flatpak distrobox \
    wireguard-tools systemd-resolved nm-connection-editor \
    glibc-all-langpacks intel-media-driver ffmpeg mc btop libva-utils zram zip unzip usbutils lm_sensors powertop && \
    dnf5 clean all

# 4. MacBook Hardware: Drivers & Thermal Management
# broadcom-wl for WiFi, facetimehd for camera, mbpfan for cooling
RUN dnf5 -y --refresh install \
    broadcom-wl akmod-wl \
    akmod-facetimehd facetimehd-kmod-common \
    kernel-devel akmods wget git make gcc curl xz cpio \
    NetworkManager-wifi && \
    dnf5 clean all

# 4.1. Build Akmods for the specific kernel in the image
RUN KERNEL_VERSION=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    echo "▸ Building modules for kernel: ${KERNEL_VERSION}" && \
    akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd && \
    akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# 5. Extract FaceTimeHD Firmware from Apple BootCamp Driver
RUN git clone --depth 1 "https://github.com/patjak/facetimehd-firmware.git" /tmp/facetimehd-firmware && \
    cd /tmp/facetimehd-firmware && \
    make && \
    make install && \
    cd / && \
    rm -rf /tmp/facetimehd-firmware

# 5.1. Install mbpfan v2.4.0 from source (missing in Fedora 44 repos) ──
RUN echo "▸ Installing mbpfan v2.4.0 from source" && \
    git clone --depth 1 --branch v2.4.0 https://github.com/linux-on-mac/mbpfan.git /tmp/mbpfan  && \
    cd /tmp/mbpfan && \
    make && \
    make install && \
    # Ensure service file is in the correct systemd directory
    cp -v mbpfan.service /usr/lib/systemd/system/mbpfan.service && \
    cd /  && \
    rm -rf /tmp/mbpfan

# 5.2. Writable directories (bootc best practice)
# See: https://bootc-dev.github.io/bootc/building/guidance.html
RUN echo "▸ Setting up writable /opt and /usr/local" && \
    rm -rvf /opt && mkdir -vp /var/opt && ln -vs /var/opt /opt && \
    mkdir -vp /var/usrlocal && mv -v /usr/local/* /var/usrlocal/ 2>/dev/null || true && \
    rm -rvf /usr/local && ln -vs /var/usrlocal /usr/local


# 5.3 Bootc Native Kernel Arguments & Modprobe
RUN mkdir -p /usr/lib/bootc/kargs.d/ && \
    echo 'kargs = ["acpi_osi=!Darwin", "acpi_osi=!Windows 2012"]' > /usr/lib/bootc/kargs.d/10-macbook.toml && \
    mkdir -p /usr/lib/modprobe.d/ && \
    echo 'options snd_hda_intel power_save=1' > /usr/lib/modprobe.d/audio-power-save.conf

# 5.4. Disable XHC1/LID0 ACPI wakeup sources (prevents spurious wakeups)
COPY suspend-fix.service /usr/lib/systemd/system/suspend-fix.service

# 5.5. Powertop optimizations to save battery
COPY powertop.service /usr/lib/systemd/system/powertop.service

# 5.6 Kernel modules: ensure coretemp + applesmc loaded at boot
COPY macbook.conf /usr/lib/modules-load.d/macbook.conf

# 6. System Configuration & Services
# Load facetimehd module and enable critical hardware/GUI services
RUN echo "facetimehd" > /etc/modules-load.d/facetimehd.conf && \
    systemctl set-default graphical.target && \
    systemctl enable NetworkManager.service mbpfan.service suspend-fix.service powertop.service zram-swap.service && \
    systemctl --global enable pipewire.service wireplumber.service

# 6.1. systemd-remount-fs: bootc manages root mount options via initrd, not fstab
RUN systemctl mask systemd-remount-fs.service

# 6.2. Creating required directories
RUN echo "▸ Creating required directories" && \
    mkdir -vp /var/roothome /data /var/home

# 7. Regenerate Initramfs (CRITICAL)
# This packs your new MacBook drivers into the boot image
RUN kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    dracut -vf "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

RUN << CLEANUP

# 8. Final cleanup
echo "▸ Final cleanup for bootc compliance"
dnf5 clean all
rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/cache/libdnf5/* \
        /var/lib/dnf \
        /var/usrlocal/share/applications/mimeinfo.cache \
        /var/roothome/.*

# 8.1. Declare /var dirs for bootc lint compliance ──
echo "▸ Generating tmpfiles.d entries for /var dirs"
find /var -mindepth 1 -maxdepth 4 -type d \
  | grep -v '^/var/home' \
  | sort \
  | while read -r dir; do
      mode=$(stat -c '%a' "${dir}")
      user=$(stat -c '%u' "${dir}")
      group=$(stat -c '%g' "${dir}")
      echo "d ${dir} ${mode} ${user} ${group} - -"
    done > /usr/lib/tmpfiles.d/bootc-var-dirs.conf

CLEANUP

# 9. Lint the final image
RUN bootc container lint
