# 1. Base: Use official Fedora 42 (Rawhide/Development) bootc
FROM quay.io/fedora/fedora-bootc:42

RUN set -euo pipefail

RUN << INIT

KERNEL_VERSION="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
FEDORA_RELEASE="$(rpm -E '%fedora')"
echo "▸ Detected kernel: ${KERNEL_VERSION}  (Fedora ${FEDORA_RELEASE})"
# For Fedora >= 41 the COPR uses "rawhide" as the release identifier
if [ "${FEDORA_RELEASE}" -ge 41 ]; then
    COPR_RELEASE="rawhide"
else
    COPR_RELEASE="${FEDORA_RELEASE}"
fi

# 2. Enable RPM Fusion and FaceTimeHD COPR
RUN dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm" && \
    dnf -y copr enable "https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-${COPR_RELEASE}/mulderje-facetimehd-kmod-fedora-${COPR_RELEASE}.repo"

INIT

# 3. Install Budgie Desktop (Onyx) and Essential Tools
# Includes WireGuard, Toolbox, and Silverblue-standard packages
RUN dnf -y groupinstall "Budgie Desktop" && \
    dnf -y install \
    fedora-release-onyx \
    budgie-desktop-view budgie-control-center network-manager-applet \
    lightdm slick-greeter \
    flatpak distrobox \
    wireguard-tools systemd-resolved nm-connection-editor \
    libavcodec-freeworld && \
    glibc-all-langpacks intel-media-driver ffmpeg mc btop libva-utils zram zip unzip usbutils lm_sensors \
    dnf clean all

# 4. MacBook Hardware: Drivers & Thermal Management
# broadcom-wl for WiFi, facetimehd for camera, mbpfan for cooling
RUN dnf -y install \
    broadcom-wl akmod-wl \
    akmod-facetimehd facetimehd-kmod-common \
    dkms kernel-devel akmods wget git make gcc curl xz cpio \
    mbpfan NetworkManager-wifi && \
    dnf clean all

# 4.1. Akmods
RUN << AKMODS

KERNEL_VERSION="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd && \
akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

AKMODS

# 5. Extract FaceTimeHD Firmware from Apple BootCamp Driver
RUN git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware && \
    cd /tmp/facetimehd-firmware && \
    make && make install \
    cd / && rm -rf /tmp/facetimehd-firmware

RUN << SYSCONFIG

# 5.1 Bootc Native Kernel Arguments (for MacBook hardware quirks)
mkdir -p /usr/lib/bootc/kargs.d/
# ── Kernel Arguments: ACPI OSI hacks for MacBook hardware ──
# Declaring kernel arguments via bootc-native configuration files.
mkdir -p /usr/lib/bootc/kargs.d/
cat > /usr/lib/bootc/kargs.d/10-macbook.toml <<'KARGS'
kargs = ["acpi_osi=!Darwin", "acpi_osi=!Windows 2012"]
match-architectures = ["x86_64"]
KARGS

# ── Kernel Arguments: Intel GPU + PCIe power savings (MacBookAir7,2 / Broadwell) ──
# PSR: Panel Self Refresh — cuts eDP link power when framebuffer is static
# FBC: Frame Buffer Compression — compresses framebuffer in VRAM
# pcie_aspm=force: enables PCIe ASPM link power states
cat > /usr/lib/bootc/kargs.d/20-macbook-power.toml <<'KARGS'
kargs = ["i915.enable_psr=1", "i915.enable_fbc=1", "pcie_aspm=force", "mem_sleep_default=s2idle"]
match-architectures = ["x86_64"]
KARGS

# ── Audio power save (Intel HDA codec off when idle for 1s) ──
echo 'options snd_hda_intel power_save=1' > /usr/lib/modprobe.d/audio-power-save.conf

SYSCONFIG

# 6. System Configuration & Services
# Load facetimehd module and enable critical hardware/GUI services
RUN echo "facetimehd" > /etc/modules-load.d/facetimehd.conf && \
    systemctl set-default graphical.target && \
    systemctl enable lightdm.service NetworkManager.service mbpfan.service && \
    systemctl --global enable pipewire.service wireplumber.service && \
    systemctl enable zram-swap.service

# 7. Regenerate Initramfs (CRITICAL)
# This packs your new MacBook drivers into the boot image
RUN set -x; \
    kver=$(cd /usr/lib/modules && echo *); \
    dracut -vf /usr/lib/modules/$kver/initramfs.img $kver

# 8. Lint the final image
RUN bootc container lint
