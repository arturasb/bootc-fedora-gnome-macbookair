# =============================================================================
# bootc-fedora-onyx-macbookair
# Immutable Fedora Onyx 43 (Budgie) tailored for MacBook Air hardware.
# =============================================================================

# ── Stage 1: Build out-of-tree kernel modules ──────────────────────────────
FROM quay.io/fedora/fedora-onyx:43

RUN <<BUILDER
set -euo pipefail
# Install build tools and kernel headers
dnf5 upgrade -y 'kernel*' --refresh
dnf5 -y install kernel-devel akmods wget git make gcc curl xz cpio --refresh

KERNEL_VERSION="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
FEDORA_RELEASE="$(rpm -E '%fedora')"
echo "▸ Detected kernel: ${KERNEL_VERSION}  (Fedora ${FEDORA_RELEASE})"

# 1. Broadcom WiFi (RPMFusion Non-Free)
echo "▸ Building and installing Broadcom WiFi drivers"
dnf5 -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"
dnf5 -y install akmod-wl
akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# 2. FaceTimeHD Camera Module (COPR)
# Note: Using rawhide if F43 specific repo isn't yet populated
echo "▸ Building and installing Broadcom WiFi drivers"
# For Fedora >= 41 the COPR uses "rawhide" as the release identifier
if [ "${FEDORA_RELEASE}" -ge 41 ]; then
    COPR_RELEASE="rawhide"
else
    COPR_RELEASE="${FEDORA_RELEASE}"
fi
curl -LsSf -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
        "https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-${COPR_RELEASE}/mulderje-facetimehd-kmod-fedora-${COPR_RELEASE}.repo"
ARCH="$(rpm -E '%_arch')"
dnf5 -y install "akmod-facetimehd-*.fc${FEDORA_RELEASE}.${ARCH}" || \
    dnf5 -y install akmod-facetimehd facetimehd-kmod-common
akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd

# Cleanup builder cache for this layer
dnf5 clean all && rm -rf /var/cache/libdnf5 /var/lib/dnf

# 3. FaceTimeHD Firmware Extraction
echo "▸ Building FaceTimeHD firmware from source"
git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware
cd /tmp/facetimehd-firmware
make && make install

BUILDER

# ── Stage 2: Final bootable image ──────────────────────────────────────────
FROM quay.io/fedora/fedora-onyx:43

# Copy pre-built kernel modules and firmware from builder
COPY --from=builder /var/cache/akmods/wl/kmod-wl*.rpm /tmp/kmods/
COPY --from=builder /var/cache/akmods/facetimehd/kmod-facetimehd*.rpm /tmp/kmods/
COPY --from=builder /usr/lib/firmware/facetimehd/ /usr/lib/firmware/facetimehd/
COPY --from=builder /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo /etc/yum.repos.d/

# Copy project configuration files directly to their final destinations
COPY packages.rpm /tmp/packages.rpm
# First-login Flatpak bootstrap (runs as user service)
COPY --chmod=755 post-install.sh /usr/bin/post-install.sh
# Triggers post-install.sh on first graphical login
COPY post-install.service /usr/lib/systemd/user/post-install.service
# MacBook keyboard: fn key behavior, swap alt/cmd
COPY hid-apple.conf /usr/lib/modprobe.d/hid-apple.conf
# Include FaceTimeHD firmware in initramfs
COPY dracut-facetimehd.conf /usr/lib/dracut.conf.d/facetimehd.conf
# Disable XHC1/LID0 ACPI wakeup sources (prevents spurious wakeups)
COPY suspend-fix.service /usr/lib/systemd/system/suspend-fix.service

RUN <<SYSCONFIG
set -euo pipefail
FEDORA_RELEASE="$(rpm -E '%fedora')"

echo "▸ Creating required directories"
mkdir -vp /var/roothome /data /var/home

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

# 5. Writable directories (bootc best practice) ──
# See: https://bootc-dev.github.io/bootc/building/guidance.html
echo "▸ Setting up writable /opt and /usr/local"
rm -rvf /opt && mkdir -vp /var/opt && ln -vs /var/opt /opt
mkdir -vp /var/usrlocal && mv -v /usr/local/* /var/usrlocal/ 2>/dev/null || true
rm -rvf /usr/local && ln -vs /var/usrlocal /usr/local

SYSCONFIG

RUN <<PACKAGES
# 6. Install User Packages from packages.rpm
dnf5 install -y --allowerasing $(grep -vE '^\s*(#|$)' packages.rpm)

# 7. Install mbpfan v2.4.0 from source ──
echo "▸ Installing mbpfan v2.4.0 from source"
git clone --depth 1 --branch v2.4.0 https://github.com/linux-on-mac/mbpfan.git /tmp/mbpfan
cd /tmp/mbpfan
make
make install
# Ensure service file is in the correct systemd directory
cp -v mbpfan.service /usr/lib/systemd/system/mbpfan.service
cd /

# 8. Services & Post-install
mv post-install.sh /usr/bin/ && chmod +x /usr/bin/post-install.sh
mv post-install.service /usr/lib/systemd/user/
mv suspend-fix.service powertop.service /usr/lib/systemd/system/

# Enable system-wide hardware services
systemctl enable \
    macbook-lighter.service \
    mbpfan.service \
    suspend-fix.service \
    zram-swap.service

# Enable user-level bootstrap services globally for all graphical sessions
systemctl --global enable \
    post-install.service

echo " 9. Final cleanup for bootc compliance"
# ── Final cleanup ──
echo "▸ Final cleanup for bootc compliance"
rm -f /tmp/packages.rpm
dnf5 clean all
rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/cache/libdnf5/* \
        /var/lib/dnf \
        /var/usrlocal/share/applications/mimeinfo.cache \
        /var/roothome/.*
# Final check for /usr/etc
rm -rvf /usr/etc

# ── Declare /var dirs for bootc lint compliance ──
echo " 10. Generating tmpfiles.d entries for /var dirs"
find /var -mindepth 1 -maxdepth 4 -type d \
  | grep -v '^/var/home' \
  | sort \
  | while read -r dir; do
      mode=$(stat -c '%a' "${dir}")
      user=$(stat -c '%u' "${dir}")
      group=$(stat -c '%g' "${dir}")
      echo "d ${dir} ${mode} ${user} ${group} - -"
    done > /usr/lib/tmpfiles.d/bootc-var-dirs.conf

PACKAGES

# ── Lint the final image ──
RUN bootc container lint
