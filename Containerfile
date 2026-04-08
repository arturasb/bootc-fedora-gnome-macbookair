# 1. Base: Use official Fedora 42 (Rawhide/Development) bootc
FROM quay.io/fedora/fedora-bootc:42

RUN set -euo pipefail

# 2. Setup Repositories
# Using 'dnf copr enable' by name is much safer than hardcoded URLs
RUN dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm" && \
    dnf -y copr enable   "https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-rawhide/mulderje-facetimehd-kmod-fedora-rawhide.repo"

# 3. Install Budgie Desktop (Onyx) and Essential Tools
# Includes WireGuard, Toolbox, and Silverblue-standard packages
RUN dnf -y groupinstall "Budgie Desktop" && \
    dnf -y install \
    fedora-release-onyx \
    budgie-desktop-view budgie-control-center network-manager-applet \
    lightdm slick-greeter \
    flatpak distrobox \
    wireguard-tools systemd-resolved nm-connection-editor \
    libavcodec-freeworld \
    glibc-all-langpacks intel-media-driver ffmpeg mc btop libva-utils zram zip unzip usbutils lm_sensors && \
    dnf clean all

# 4. MacBook Hardware: Drivers & Thermal Management
# broadcom-wl for WiFi, facetimehd for camera, mbpfan for cooling
RUN dnf -y install \
    broadcom-wl akmod-wl \
    akmod-facetimehd facetimehd-kmod-common \
    dkms kernel-devel akmods wget git make gcc curl xz cpio \
    mbpfan NetworkManager-wifi && \
    dnf clean all

# 4.1. Build Akmods for the specific kernel in the image
RUN KERNEL_VERSION=$(cd /usr/lib/modules && echo *) && \
    echo "▸ Building modules for kernel: ${KERNEL_VERSION}" && \
    akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd && \
    akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# 5. Extract FaceTimeHD Firmware from Apple BootCamp Driver
RUN git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware && \
    cd /tmp/facetimehd-firmware && \
    make && make install \
    cd / && rm -rf /tmp/facetimehd-firmware

# 5.1 Bootc Native Kernel Arguments & Modprobe
RUN mkdir -p /usr/lib/bootc/kargs.d/ && \
    echo 'kargs = ["acpi_osi=!Darwin", "acpi_osi=!Windows 2012", "i915.enable_psr=1", "i915.enable_fbc=1", "pcie_aspm=force", "mem_sleep_default=s2idle"]' > /usr/lib/bootc/kargs.d/10-macbook.toml && \
    mkdir -p /usr/lib/modprobe.d/ && \
    echo 'options snd_hda_intel power_save=1' > /usr/lib/modprobe.d/audio-power-save.conf


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
