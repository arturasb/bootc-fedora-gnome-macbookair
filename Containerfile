# =============================================================================
# bootc-fedora-onyx-macbookair
# Immutable Fedora Onyx 43 (Budgie) tailored for MacBook Air hardware.
# =============================================================================

# ── Stage 1: Build out-of-tree kernel modules ──────────────────────────────
FROM quay.io/fedora-ostree-desktops/onyx:43 AS builder

RUN <<BUILDER
set -euo pipefail
# Install build tools and kernel headers
dnf5 upgrade -y 'kernel*' --refresh
dnf5 -y install kernel-devel akmods wget git make gcc curl xz cpio --refresh

KERNEL_VERSION="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
FEDORA_RELEASE="$(rpm -E '%fedora')"

# 1. Broadcom WiFi (RPMFusion Non-Free)
dnf5 -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"
dnf5 -y install akmod-wl
akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# 2. FaceTimeHD Camera Module (COPR)
# Note: Using rawhide if F43 specific repo isn't yet populated
curl -LsSf -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
    "https://fedorainfracloud.org"
dnf5 -y install akmod-facetimehd
akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd

# 3. FaceTimeHD Firmware Extraction
# Corrected URL: https://github.com/patjak/facetimehd-firmware.git
git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware
cd /tmp/facetimehd-firmware
make && make install
BUILDER

# ── Stage 2: Final bootable image ──────────────────────────────────────────
FROM quay.io/fedora-ostree-desktops/onyx:43

# Copy pre-built kernel modules and firmware from builder
COPY --from=builder /var/cache/akmods/wl/kmod-wl*.rpm /tmp/kmods/
COPY --from=builder /var/cache/akmods/facetimehd/kmod-facetimehd*.rpm /tmp/kmods/
COPY --from=builder /usr/lib/firmware/facetimehd/ /usr/lib/firmware/facetimehd/

# Copy your local project configuration files
COPY packages.rpm post-install.sh post-install.service \
     hid-apple.conf dracut-facetimehd.conf \
     suspend-fix.service powertop.service ./

RUN <<SYSCONFIG
set -euo pipefail
FEDORA_RELEASE="$(rpm -E '%fedora')"

# 1. Enable Official Repositories
dnf5 -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# 2. Install Hardware Drivers & Modules
dnf5 -y install kernel-modules-extra /tmp/kmods/*.rpm --refresh
ln -sf /usr/share/zoneinfo/Europe/Vilnius /etc/localtime
mv hid-apple.conf /etc/modprobe.d/

# 3. Setup Dracut & Regenerate Initramfs
# This ensures drivers load during the early boot process
mv dracut-facetimehd.conf /etc/dracut.conf.d/facetimehd.conf
KVER=$(ls /usr/lib/modules | head -n 1)
echo "▸ Regenerating initramfs for kernel: ${KVER}"
dracut -vf "/usr/lib/modules/${KVER}/initramfs.img" "${KVER}"

# 4. Bootc Native Kernel Arguments (for MacBook hardware quirks)
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

# 5. Services & Post-install
mv post-install.sh /usr/bin/ && chmod +x /usr/bin/post-install.sh
mv post-install.service /usr/lib/systemd/user/
mv suspend-fix.service powertop.service /usr/lib/systemd/system/
systemctl --global enable post-install.service
systemctl enable suspend-fix.service powertop.service

SYSCONFIG

RUN <<PACKAGES
# 6. Install User Packages from packages.rpm
dnf5 install -y --allowerasing $(grep -vE '^\s*(#|$)' packages.rpm)

# Cleanup build artifacts
rm -rf /tmp/kmods /var/cache/* /var/log/*
dnf5 clean all

PACKAGES

# ── Lint the final image ──
RUN bootc container lint
