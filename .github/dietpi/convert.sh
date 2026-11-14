#!/usr/bin/env bash
#==========================================================================
# Convert an ophub Armbian image (Amlogic) into a DietPi image.
# Runs natively on an arm64 runner: the image is booted in systemd-nspawn
# and DietPi-Installer is executed non-interactively inside it, the same
# way DietPi's own dietpi-build does it.
#
# Usage: convert.sh <armbian.img.gz> <output_dir> <distro_id 7|8> <dtb_name> <no_hs200 true|false> <name_suffix>
#==========================================================================
set -euo pipefail

IMG_GZ=$1
OUT_DIR=$2
DISTRO=$3
DTB=$4
NO_HS200=$5
SUFFIX=$6

WORK=/builder/dietpi
mkdir -p "$WORK" "$OUT_DIR"
cd "$WORK"

LOOP=''
cleanup() {
	set +e
	mountpoint -q rootfs/boot && umount -R rootfs/boot
	mountpoint -q rootfs && umount -R rootfs
	[[ $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

echo "::group::Prepare image"
gzip -dc "$IMG_GZ" > base.img
# DietPi-Installer needs free space; the rootfs is expanded again on first boot anyway
truncate -s +2G base.img
LOOP=$(losetup -fP --show base.img)
sleep 2
lsblk -o NAME,SIZE,FSTYPE,LABEL "$LOOP"

BOOT_PART=''
ROOT_PART=''
for p in "${LOOP}"p*; do
	fs=$(blkid -s TYPE -o value "$p" || true)
	[[ $fs == vfat && ! $BOOT_PART ]] && BOOT_PART=$p
	[[ $fs == ext4 ]] && ROOT_PART=$p
done
[[ $BOOT_PART && $ROOT_PART ]] || { echo "Error: BOOT (vfat) or ROOTFS (ext4) partition not found"; exit 1; }
echo "BOOT=$BOOT_PART ROOT=$ROOT_PART"

growpart "$LOOP" "${ROOT_PART##*p}" || true
partx -u "$LOOP" || true
e2fsck -fy "$ROOT_PART" || [[ $? -le 1 ]]
resize2fs "$ROOT_PART"

mkdir -p rootfs
mount "$ROOT_PART" rootfs
mkdir -p rootfs/boot
mount "$BOOT_PART" rootfs/boot
ls -la rootfs/boot
echo "::endgroup::"

echo "::group::Device tree"
[[ -f rootfs/boot/uEnv.txt ]] || { echo "Error: /boot/uEnv.txt missing in base image"; exit 1; }
[[ -f "rootfs/boot/dtb/amlogic/$DTB" ]] || { echo "Error: dtb $DTB not found"; ls rootfs/boot/dtb/amlogic | grep s905w; exit 1; }
sed -i "s|^FDT=.*|FDT=/dtb/amlogic/$DTB|" rootfs/boot/uEnv.txt
grep -E '^(FDT|LINUX|INITRD|APPEND)=' rootfs/boot/uEnv.txt

if [[ $NO_HS200 == true ]]; then
	# Some X96 Mini revisions have eMMC chips that fail in HS200/DDR modes with mainline kernels.
	# Drop those modes and cap the eMMC clock at 52 MHz for all S905W device trees.
	for f in rootfs/boot/dtb/amlogic/meson-gxl-s905w-*.dtb; do
		node=$(dtc -q -I dtb -O dts "$f" | awk '
			/\{[[:space:]]*$/ {
				n=$1; if (n ~ /:$/) n=$2
				if (n == "/") { d=0; p[0]="" } else { d++; p[d]=p[d-1] "/" n }
				if (n ~ /^mmc@(d0)?074000$/) print p[d]
				next
			}
			/^[[:space:]]*\};/ { d-- }' | head -1)
		[[ $node ]] || { echo "skip $f: eMMC node not found"; continue; }
		fdtput -d "$f" "$node" mmc-hs200-1_8v 2> /dev/null || true
		fdtput -d "$f" "$node" mmc-ddr-1_8v 2> /dev/null || true
		fdtput -t u "$f" "$node" max-frequency 52000000
		echo "patched $(basename "$f"): $node -> no HS200/DDR, 52 MHz"
	done
fi
echo "::endgroup::"

echo "::group::DietPi-Installer"
ln -sf /dev/null rootfs/etc/systemd/system/console-getty.service
cat << _EOF_ > rootfs/dietpi-build.sh
#!/bin/bash -e
infocmp "\$TERM" > /dev/null 2>&1 || export TERM=dumb
export GITOWNER='MichaIng' GITBRANCH='master' HW_MODEL=22 IMAGE_CREATOR='vector-co-uz' PREIMAGE_INFO='ophub Armbian s905w-x96-mini' WIFI_REQUIRED=1 DISTRO_TARGET=$DISTRO TMPDIR='/tmp'
bash -c "\$(curl -sSf 'https://raw.githubusercontent.com/MichaIng/DietPi/master/.build/images/dietpi-installer' || echo false)" || { echo '[FAILED] DietPi-Installer failed'; journalctl -n 50 --no-pager; df -h; exit 1; }
rm -f /etc/systemd/system/multi-user.target.wants/dietpi-build.service /etc/systemd/system/dietpi-build.service /dietpi-build.sh /etc/systemd/system/console-getty.service
> /success
_EOF_
chmod +x rootfs/dietpi-build.sh
cat << '_EOF_' > rootfs/etc/systemd/system/dietpi-build.service
[Unit]
After=multi-user.target

[Service]
Type=idle
StandardOutput=tty
ExecStart=-/dietpi-build.sh
ExecStopPost=/usr/bin/systemctl --no-block start poweroff.target
_EOF_
mkdir -p rootfs/etc/systemd/system/multi-user.target.wants
ln -sf ../dietpi-build.service rootfs/etc/systemd/system/multi-user.target.wants/dietpi-build.service

abind=("--bind=$LOOP" '--bind=/dev/disk')
for p in "${LOOP}"p*; do abind+=("--bind=$p"); done
systemd-nspawn -bD rootfs "${abind[@]}" < /dev/null || true
[[ -f rootfs/success ]] || { echo "Error: DietPi-Installer did not finish successfully"; exit 1; }
rm rootfs/success
echo "::endgroup::"

echo "::group::Verify boot files"
ls -la rootfs/boot
for f in uEnv.txt "dtb/amlogic/$DTB" dietpi.txt; do
	[[ -e "rootfs/boot/$f" ]] || { echo "Error: /boot/$f missing after DietPi-Installer"; exit 1; }
done
ls rootfs/boot | grep -qE '^(Image|zImage|vmlinuz)' || { echo "Error: kernel missing in /boot"; exit 1; }
ls rootfs/boot | grep -qE '^(uInitrd|initrd)' || { echo "Error: initrd missing in /boot"; exit 1; }
grep -E '^FDT=' rootfs/boot/uEnv.txt
echo "::endgroup::"

echo "::group::Pack"
rm -rf rootfs/var/cache/apt/archives/*.deb rootfs/tmp/* 2> /dev/null || true
fstrim -v rootfs || true
fstrim -v rootfs/boot || true
umount rootfs/boot
umount rootfs
losetup -d "$LOOP"
LOOP=''
name="DietPi_X96-Mini-S905W-ARMv8-${SUFFIX}"
mv base.img "$name.img"
xz -T0 -6 -v "$name.img"
mv "$name.img.xz" "$OUT_DIR/"
(cd "$OUT_DIR" && sha256sum "$name.img.xz" > "$name.img.xz.sha256")
ls -lh "$OUT_DIR"
echo "::endgroup::"
