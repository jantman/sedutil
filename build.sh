#!/bin/bash
set -euo pipefail

# Build script for sedutil: sedutil_LINUX.tgz, UEFI64.img.gz, and RESCUE64.img.gz
# This consolidates the various scripts in images/ into a single automated build.
#
# Usage:
#   ./build.sh [--install-deps] [--cli-only] [--skip-cli] [--skip-32bit-cli]
#
# Stages:
#   1. Build sedutil_LINUX.tgz (sedutil-cli for x86_64, optionally i686)
#   2. Download syslinux and clone buildroot (images/getresources)
#   3. Build PBA rootfs via buildroot for 64-bit and 32-bit (images/buildpbaroot)
#   4. Build UEFI64.img.gz
#   5. Build BIOS32.img.gz (needed by RESCUE64)
#   6. Build RESCUE64.img.gz

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DEPS=0
CLI_ONLY=0
SKIP_CLI=0
SKIP_32BIT_CLI=0

for arg in "$@"; do
    case "$arg" in
        --install-deps)  INSTALL_DEPS=1 ;;
        --cli-only)      CLI_ONLY=1 ;;
        --skip-cli)      SKIP_CLI=1 ;;
        --skip-32bit-cli) SKIP_32BIT_CLI=1 ;;
        -h|--help)
            echo "Usage: $0 [--install-deps] [--cli-only] [--skip-cli] [--skip-32bit-cli]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# Source the version config
. images/conf

VERSIONINFO=$(git describe --dirty 2>/dev/null || echo "tarball")
echo "=== Building sedutil ${VERSIONINFO} ==="

die() {
    echo "FATAL: $*" >&2
    exit 1
}

########################################
# Stage 0: Install build dependencies
########################################
if [ "$INSTALL_DEPS" -eq 1 ]; then
    echo "=== Installing build dependencies ==="
    sudo apt-get update
    sudo apt-get install -y \
        build-essential g++ autoconf automake \
        libsystemd-dev \
        gdisk dosfstools e2fsprogs \
        wget git xz-utils cpio gzip \
        bc rsync unzip python3 file \
        gcc-multilib g++-multilib
    # 32-bit libsystemd for 32-bit CLI build
    if [ "$SKIP_32BIT_CLI" -eq 0 ]; then
        sudo dpkg --add-architecture i386
        sudo apt-get update
        sudo apt-get install -y libsystemd-dev:i386
    fi
fi

########################################
# Stage 1: Build sedutil_LINUX.tgz
########################################
if [ "$SKIP_CLI" -eq 0 ]; then
    echo "=== Stage 1: Building sedutil_LINUX.tgz ==="
    mkdir -p linux/CLI/dist/Release_x86_64/

    autoreconf -i
    ./configure --enable-silent-rules

    if [ "$SKIP_32BIT_CLI" -eq 0 ]; then
        mkdir -p linux/CLI/dist/Release_i686/
        echo "--- Building 32-bit sedutil-cli ---"
        make CFLAGS='-m32 -O2' CXXFLAGS='-m32 -O2' all
        cp sedutil-cli linux/CLI/dist/Release_i686/
        make clean
    fi

    echo "--- Building 64-bit sedutil-cli ---"
    make CFLAGS='-m64 -O2' CXXFLAGS='-m64 -O2' all
    cp sedutil-cli linux/CLI/dist/Release_x86_64/

    if [ "$SKIP_32BIT_CLI" -eq 0 ]; then
        strip --strip-debug --strip-unneeded linux/CLI/dist/Release_i686/sedutil-cli
    fi
    strip --strip-debug --strip-unneeded linux/CLI/dist/Release_x86_64/sedutil-cli

    cd linux
    TARFILES=(*.txt TestSuite.sh)
    TAR_ARGS=()
    for f in "${TARFILES[@]}"; do
        [ -f "$f" ] && TAR_ARGS+=("$f")
    done
    if [ "$SKIP_32BIT_CLI" -eq 0 ]; then
        tar --xform 's,^,sedutil/,' -czf sedutil_LINUX.tgz \
            "${TAR_ARGS[@]}" ../docs/* \
            -C ./CLI/dist Release_i686/sedutil-cli Release_x86_64/sedutil-cli
    else
        tar --xform 's,^,sedutil/,' -czf sedutil_LINUX.tgz \
            "${TAR_ARGS[@]}" ../docs/* \
            -C ./CLI/dist Release_x86_64/sedutil-cli
    fi
    cd "$SCRIPT_DIR"
    cp linux/sedutil_LINUX.tgz .
    echo "--- Built sedutil_LINUX.tgz ---"
    make distclean || true

    if [ "$CLI_ONLY" -eq 1 ]; then
        echo "=== CLI-only build complete ==="
        exit 0
    fi
fi

########################################
# Stage 2: Get resources
########################################
echo "=== Stage 2: Downloading resources ==="
cd images

if [ ! -d scratch ]; then
    mkdir scratch
fi
cd scratch

if [ ! -f "${SYSLINUX}.tar.xz" ]; then
    wget "https://www.kernel.org/pub/linux/utils/boot/syslinux/${SYSLINUX}.tar.xz"
fi
if [ ! -d "${SYSLINUX}" ]; then
    tar xf "${SYSLINUX}.tar.xz"
fi

if [ ! -d buildroot.git ]; then
    # Use HTTPS for CI compatibility
    git clone --bare https://github.com/buildroot/buildroot.git buildroot.git
fi

cd "$SCRIPT_DIR/images"

########################################
# Stage 3: Build PBA rootfs via buildroot
########################################
echo "=== Stage 3: Building PBA rootfs via buildroot ==="
cd scratch

rm -rf buildroot
git clone buildroot.git || die "Failed to clone buildroot"
cd buildroot
git checkout -b PBABUILD "${BUILDROOT_TAG}" || die "Failed to checkout ${BUILDROOT_TAG}"
git reset --hard
git clean -df

# Apply patches
cd ..
mkdir -p patches
cp -r ../buildroot/patches/* patches/

cd buildroot

# Set up 64-bit out-of-tree build
mkdir 64bit
cp ../../buildroot/64bit/.config 64bit/
cp ../../buildroot/64bit/* 64bit/ 2>/dev/null || true
cp -r ../../buildroot/64bit/overlay 64bit/

# Set up 32-bit out-of-tree build
mkdir 32bit
cp ../../buildroot/32bit/.config 32bit/
cp ../../buildroot/32bit/* 32bit/ 2>/dev/null || true
cp -r ../../buildroot/32bit/overlay 32bit/

# Add sedutil package to buildroot
sed -i '/sedutil/d' package/Config.in
sed -i '/menu "System tools"/a \\tsource "package/sedutil/Config.in"' package/Config.in
cp -r ../../buildroot/package/sedutil/ package/

# Make a distribution tarball from the current source
cd "$SCRIPT_DIR"
autoreconf -i
./configure
make dist
mkdir -p images/scratch/buildroot/dl/
cp sedutil-*.tar.gz images/scratch/buildroot/dl/
make distclean || true

cd images/scratch/buildroot

echo "--- Building 64-bit PBA Linux system ---"
make O=64bit 2>&1 | tee 64bit/build_output.txt
echo "--- Building 32-bit PBA Linux system ---"
make O=32bit 2>&1 | tee 32bit/build_output.txt

cd "$SCRIPT_DIR/images"

########################################
# Stage 4: Build UEFI64.img.gz
########################################
echo "=== Stage 4: Building UEFI64.img.gz ==="

BUILDTYPE=UEFI64
BUILDIMG="${BUILDTYPE}-${VERSIONINFO}.img"

# Verify prerequisites
for f in \
    "scratch/${SYSLINUX}/efi64/efi/syslinux.efi" \
    "scratch/${SYSLINUX}/efi64/com32/elflink/ldlinux/ldlinux.e64" \
    "scratch/buildroot/64bit/images/bzImage" \
    "scratch/buildroot/64bit/images/rootfs.cpio.xz" \
    "buildroot/syslinux.cfg"; do
    [ -f "$f" ] || die "Missing prerequisite: $f"
done

sudo rm -rf "${BUILDTYPE}"
mkdir "${BUILDTYPE}"
cd "${BUILDTYPE}"

dd if=/dev/zero of="${BUILDIMG}" bs=1M count=32
printf 'n\n\n\n\nef00\nw\nY\n' | gdisk "${BUILDIMG}"
LOOPDEV=$(sudo losetup --show -f -o 1048576 "${BUILDIMG}")
sudo mkfs.vfat "$LOOPDEV" -n "${BUILDTYPE}"
sudo mkdir image
sudo mount "$LOOPDEV" image
sudo chmod 777 image
sudo mkdir -p image/EFI/boot
sudo cp "../scratch/${SYSLINUX}/efi64/efi/syslinux.efi" image/EFI/boot/bootx64.efi
sudo cp "../scratch/${SYSLINUX}/efi64/com32/elflink/ldlinux/ldlinux.e64" image/EFI/boot/
sudo cp ../scratch/buildroot/64bit/images/bzImage image/EFI/boot/
sudo cp ../scratch/buildroot/64bit/images/rootfs.cpio.xz image/EFI/boot/
sudo cp ../buildroot/syslinux.cfg image/EFI/boot/
sudo umount image
sudo losetup -d "$LOOPDEV"
gzip "${BUILDIMG}"

cd "$SCRIPT_DIR/images"
echo "--- Built ${BUILDTYPE}/${BUILDIMG}.gz ---"

########################################
# Stage 5: Build BIOS32.img.gz (needed by RESCUE64)
########################################
echo "=== Stage 5: Building BIOS32.img.gz ==="

BUILDTYPE=BIOS32
BUILDIMG="${BUILDTYPE}-${VERSIONINFO}.img"

for f in \
    "scratch/${SYSLINUX}/bios/mbr/mbr.bin" \
    "scratch/${SYSLINUX}/bios/extlinux/extlinux" \
    "scratch/buildroot/32bit/images/bzImage" \
    "scratch/buildroot/32bit/images/rootfs.cpio.xz" \
    "buildroot/syslinux.cfg"; do
    [ -f "$f" ] || die "Missing prerequisite: $f"
done

sudo rm -rf "${BUILDTYPE}"
mkdir "${BUILDTYPE}"
cd "${BUILDTYPE}"

dd if=/dev/zero of="${BUILDIMG}" bs=1M count=32
printf 'o\nn\np\n1\n\n\na\n1\nw\n' | fdisk "${BUILDIMG}"
dd if="../scratch/${SYSLINUX}/bios/mbr/mbr.bin" of="${BUILDIMG}" count=1 conv=notrunc bs=512
LOOPDEV=$(sudo losetup --show -f -o 1048576 "${BUILDIMG}")
sudo mkfs.ext4 "$LOOPDEV" -L "${BUILDTYPE}"
mkdir image
sudo mount "$LOOPDEV" image
sudo chmod 777 image
sudo mkdir -p image/boot/extlinux
sudo "../scratch/${SYSLINUX}/bios/extlinux/extlinux" --install image/boot/extlinux
sudo cp ../scratch/buildroot/32bit/images/bzImage image/boot/extlinux/
sudo cp ../scratch/buildroot/32bit/images/rootfs.cpio.xz image/boot/extlinux/
sudo cp ../buildroot/syslinux.cfg image/boot/extlinux/extlinux.conf
sudo umount image
sudo losetup -d "$LOOPDEV"
gzip "${BUILDIMG}"

cd "$SCRIPT_DIR/images"
echo "--- Built ${BUILDTYPE}/${BUILDIMG}.gz ---"

########################################
# Stage 6: Build RESCUE64.img.gz
########################################
echo "=== Stage 6: Building RESCUE64.img.gz ==="

BUILDTYPE=RESCUE64
ROOTDIR=64bit
BUILDIMG="${BUILDTYPE}-${VERSIONINFO}.img"

for f in \
    "scratch/${SYSLINUX}/efi64/efi/syslinux.efi" \
    "scratch/${SYSLINUX}/efi64/com32/elflink/ldlinux/ldlinux.e64" \
    "scratch/buildroot/${ROOTDIR}/images/bzImage" \
    "scratch/buildroot/${ROOTDIR}/images/rootfs.cpio.xz" \
    "buildroot/syslinux.cfg"; do
    [ -f "$f" ] || die "Missing prerequisite: $f"
done
[ -f UEFI64/UEFI64-*.img.gz ] || die "Missing UEFI64 image"
[ -f BIOS32/BIOS32-*.img.gz ] || die "Missing BIOS32 image"

# Remaster rootfs to include rescue tools and boot images
sudo rm -rf scratch/rescuefs
sudo rm -f "scratch/buildroot/${ROOTDIR}/images/rescuefs.cpio.xz"
mkdir scratch/rescuefs
cd scratch/rescuefs
xz --decompress --stdout "../buildroot/${ROOTDIR}/images/rootfs.cpio.xz" | sudo cpio -i -H newc -d

# Customize /etc/issue for rescue image
cat > /tmp/issue <<ISSUEEOF
* ***********************************
* DTA sedutil rescue image ${BUILDIMG}
*
* Login as root, there is no password
*
* ***********************************
ISSUEEOF
sudo mv /tmp/issue etc/issue
sudo rm -f etc/init.d/S99*
sudo mkdir -p usr/sedutil
sudo cp ../../UEFI64/UEFI64-*.img.gz usr/sedutil/
sudo cp ../../BIOS32/BIOS32-*.img.gz usr/sedutil/
sudo find . | sudo cpio -o -H newc | xz -9 -C crc32 -c > "../buildroot/${ROOTDIR}/images/rescuefs.cpio.xz"

cd "$SCRIPT_DIR/images"
sudo rm -rf scratch/rescuefs

# Build the RESCUE64 image (UEFI/GPT)
sudo rm -rf "${BUILDTYPE}"
mkdir "${BUILDTYPE}"
cd "${BUILDTYPE}"

dd if=/dev/zero of="${BUILDIMG}" bs=1M count=75
printf 'n\n\n\n\nef00\nw\nY\n' | gdisk "${BUILDIMG}"
LOOPDEV=$(sudo losetup --show -f -o 1048576 "${BUILDIMG}")
sudo mkfs.vfat "$LOOPDEV" -n "${BUILDTYPE}"
mkdir image
sudo mount "$LOOPDEV" image
sudo chmod 777 image
sudo mkdir -p image/EFI/boot
sudo cp "../scratch/${SYSLINUX}/efi64/efi/syslinux.efi" image/EFI/boot/bootx64.efi
sudo cp "../scratch/${SYSLINUX}/efi64/com32/elflink/ldlinux/ldlinux.e64" image/EFI/boot/
sudo cp "../scratch/buildroot/${ROOTDIR}/images/bzImage" image/EFI/boot/
sudo cp "../scratch/buildroot/${ROOTDIR}/images/rescuefs.cpio.xz" image/EFI/boot/rootfs.cpio.xz
sudo cp ../buildroot/syslinux.cfg image/EFI/boot/
sudo umount image
sudo losetup -d "$LOOPDEV"
gzip "${BUILDIMG}"

cd "$SCRIPT_DIR/images"
echo "--- Built ${BUILDTYPE}/${BUILDIMG}.gz ---"

########################################
# Collect artifacts
########################################
echo "=== Collecting artifacts ==="
cd "$SCRIPT_DIR"
mkdir -p dist

cp "images/UEFI64/UEFI64-${VERSIONINFO}.img.gz" dist/UEFI64.img.gz
cp "images/RESCUE64/RESCUE64-${VERSIONINFO}.img.gz" dist/RESCUE64.img.gz
if [ -f sedutil_LINUX.tgz ]; then
    cp sedutil_LINUX.tgz dist/
elif [ -f linux/sedutil_LINUX.tgz ]; then
    cp linux/sedutil_LINUX.tgz dist/
fi

echo ""
echo "=== Build complete ==="
echo "Artifacts in dist/:"
ls -lh dist/
