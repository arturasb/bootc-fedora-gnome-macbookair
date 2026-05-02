# 1. Base: Use unofficial Fedora Ostree Desktop for Budgie Atomic 44 bootc 
FROM quay.io/fedora-ostree-desktops/budgie-atomic:44

# 1.1. Making /opt immutable
RUN rm /opt && mkdir /opt

# 2. Setup Repositories
RUN dnf5 -y --refresh install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-44.noarch.rpm" && \
    # Direct download of COPR repo file to avoid dnf5 plugin issues
    curl -L -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
    https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-44/mulderje-facetimehd-kmod-fedora-44.repo

# 2.1 MacBook Hardware: Drivers & Thermal Management
# broadcom-wl for WiFi, facetimehd for camera, mbpfan for cooling
RUN dnf5 -y install \
    kernel-devel akmods wget git make gcc curl xz cpio \
    NetworkManager-wifi

# 2.2. Create unprivileged build user and akmods dirs before any akmods runs
RUN useradd -m -s /bin/bash akmodsbuild && \
    mkdir -p /var/lib/akmods/build /var/cache/akmods/output && \
    chown -R akmodsbuild:akmodsbuild /var/lib/akmods /var/cache/akmods /home/akmodsbuild

# 2.3. MacBook Hardware: only download drivers for later build
RUN dnf5 -y install --setopt=tsflags=noscripts \
    broadcom-wl akmod-wl \
    akmod-facetimehd facetimehd-kmod-common

# 2.4. Make akmods build-only (prevent it from trying to install modules)
RUN printf 'AKMODS_BUILD_DIR=/var/lib/akmods/build\nAKMODS_OUTPUT_DIR=/var/cache/akmods/output\nAKMODS_INSTALL=no\n' > /etc/akmods.conf

# 2.5. Build facetimehd + wl as non-root (produces rpms under /var/cache/akmods/<kmod>/)
RUN KERNEL_VERSION=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    runuser -u akmodsbuild -- akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd && \
    runuser -u akmodsbuild -- akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# 2.6. Install the generated rpms but skip their %post scriptlets (they would try to run akmods)
RUN rpm -Uvh --noscripts /var/cache/akmods/wl/*.rpm /var/cache/akmods/facetimehd/*.rpm || \
    dnf5 -y localinstall /var/cache/akmods/wl/*.rpm /var/cache/akmods/facetimehd/*.rpm || true

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

# 5.2 Installing codecs and media drivers
RUN dnf5 install -y --allowerasing \
    gstreamer1-plugin-libav \
    gstreamer1-plugins-bad-free-extras \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    gstreamer1-vaapi \
    ffmpeg
    
RUN dnf5 install -y intel-media-driver

# 5.3. Now disable RPM Fusion repos
RUN dnf5 config-manager setopt 'rpmfusion-*.enabled=0'

# 5.4. Installing packages
RUN dnf5 install -y \
    mc \
    btop \
    libva-utils \
    zram \
    zip \
    unzip \
    usbutils \
    lm_sensors \
    powertop

# 5.5. Bootc Native Kernel Arguments & Modprobe
RUN mkdir -p /usr/lib/bootc/kargs.d/ && \
    echo 'kargs = ["acpi_osi=!Darwin", "acpi_osi=!Windows 2012", "rhgb", "quiet"]' > /usr/lib/bootc/kargs.d/10-macbook.toml && \
    mkdir -p /usr/lib/modprobe.d/ && \
    echo 'options snd_hda_intel power_save=1' > /usr/lib/modprobe.d/audio-power-save.conf

# 5.6. Disable XHC1/LID0 ACPI wakeup sources (prevents spurious wakeups)
COPY suspend-fix.service /usr/lib/systemd/system/suspend-fix.service

# 5.7. Powertop optimizations to save battery
COPY powertop.service /usr/lib/systemd/system/powertop.service

# 5.8. Kernel modules: ensure coretemp + applesmc loaded at boot
COPY macbook.conf /usr/lib/modules-load.d/macbook.conf

# 5.9. MacBook keyboard: fn key behavior
COPY hid-apple.conf /usr/lib/modprobe.d/hid-apple.conf

# 5.10. Make logind to ignore power button activation resulting to immediate poweroff
# RUN mkdir /etc/systemd/logind.conf.d/
# COPY 10-powerkey.conf /etc/systemd/logind.conf.d/10-powerkey.conf

# 6. System Configuration & Services
# Load facetimehd module and enable critical hardware/GUI services
RUN echo "facetimehd" > /etc/modules-load.d/facetimehd.conf && \
    systemctl enable mbpfan.service suspend-fix.service powertop.service zram-swap.service

# 6.1. systemd-remount-fs: bootc manages root mount options via initrd, not fstab
RUN systemctl mask systemd-remount-fs.service

# 7. Regenerate Initramfs (CRITICAL)
# This packs your new MacBook drivers into the boot image
RUN kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')" && \
    dracut -vf "/usr/lib/modules/${kver}/initramfs.img" "${kver}"


# 8. Final cleanup
RUN echo "▸ Final cleanup for bootc compliance" && \
    dnf5 clean all && \
    rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/cache/libdnf5/* \
        /var/lib/dnf \
        /var/usrlocal/share/applications/mimeinfo.cache 

# 8.1. Remove Fedora flatpak repo
RUN flatpak remote-delete --system fedora || true && \
  flatpak remote-delete --system fedora-testing || true
# 8.2. Add Flathub flatpak repo
RUN flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# 9. Lint the final image
RUN bootc container lint
