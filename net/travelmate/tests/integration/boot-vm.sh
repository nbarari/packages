#!/bin/sh
# tests/integration/boot-vm.sh — boot an OpenWrt x86_64 VM under QEMU with KVM,
# install wireless packages, load mac80211_hwsim, and signal readiness.
#
# Uses a Linux tap interface (requires sudo) for L2 connectivity to the guest's
# br-lan so SSH reliably reaches OpenWrt at its static LAN IP without fighting
# SLIRP's address expectations.
#
# Usage: boot-vm.sh [options]
#   --image  URL_OR_PATH   OpenWrt x86_64 generic-ext4-combined.img.gz
#   --work-dir DIR         state dir for image/overlay/pid (default: /tmp/trm-tier2)
#   --tap    IFNAME        tap interface name to create (default: trmtap0)
#   --guest-ip IP          OpenWrt LAN IP to SSH to (default: 192.168.1.1)
#   --host-ip  IP/PREFIX   host-side tap address (default: 192.168.1.100/24)
#   --radios N             mac80211_hwsim radio count (default: 6)
#
# On success: prints GUEST_IP to stdout; QEMU PID written to ${WORK_DIR}/qemu.pid.
# The tap interface is NOT torn down by this script — the caller's exit trap
# is responsible so the interface survives across setup steps.
#
# Design notes (important for maintainers):
#   - OpenWrt x86_64 generic image has no wireless kernel modules or userland.
#   - mac80211_hwsim is loaded via insmod (opkg can't install without internet).
#   - Kmod packages are downloaded from the OpenWrt kmods feed on the HOST.
#   - Wireless userland (wpad, wifi-scripts, iw, iwinfo, etc.) is likewise
#     installed by piping data.tar.gz from .ipk archives into the guest.
#   - wpad's wpa_supplicant instance MUST run without ujail in this test env:
#     ujail sandboxing blocks wpa_supplicant from registering on ubus, which
#     prevents netifd from configuring the STA interface. The fix: kill the
#     ujail-wrapped process and restart wpa_supplicant directly.
#   - Wireless config in runner.sh MUST use 'option phy phyN' (not 'option path
#     virtual/mac80211_hwsim/...') — iwinfo's phyname lookup fails for hwsim's
#     virtual device path, so mac80211.sh can't find the PHY otherwise.

set -e

OPENWRT_URL="https://downloads.openwrt.org/releases/24.10.7/targets/x86/64/openwrt-24.10.7-x86-64-generic-ext4-combined.img.gz"
WORK_DIR="/tmp/trm-tier2"
TAP_IFACE="trmtap0"
GUEST_IP="192.168.1.1"
HOST_TAP_IP="192.168.1.100/24"
HWSIM_RADIOS=6
BOOT_TIMEOUT=180

die() { printf "boot-vm: ERROR: %s\n" "$*" >&2; exit 1; }
log() { printf "boot-vm: %s\n" "$*" >&2; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--image)    OPENWRT_URL="$2";  shift 2 ;;
		--work-dir) WORK_DIR="$2";     shift 2 ;;
		--tap)      TAP_IFACE="$2";    shift 2 ;;
		--guest-ip) GUEST_IP="$2";     shift 2 ;;
		--host-ip)  HOST_TAP_IP="$2";  shift 2 ;;
		--radios)   HWSIM_RADIOS="$2"; shift 2 ;;
		*) die "unknown option: $1" ;;
	esac
done

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"
command -v qemu-img            >/dev/null 2>&1 || die "qemu-img not found"

SSH_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
VM_SSH="ssh ${SSH_OPTS} root@${GUEST_IP}"

mkdir -p "${WORK_DIR}"

# --- prepare base image ---

IMG_GZ="${WORK_DIR}/openwrt.img.gz"
IMG_RAW="${WORK_DIR}/openwrt.img"
IMG_OVERLAY="${WORK_DIR}/run.qcow2"

if [ ! -f "${IMG_RAW}" ]; then
	if [ -f "${OPENWRT_URL}" ]; then
		cp "${OPENWRT_URL}" "${IMG_GZ}"
	else
		log "downloading ${OPENWRT_URL}"
		curl -fSL --progress-bar -o "${IMG_GZ}" "${OPENWRT_URL}"
	fi
	# OpenWrt images have trailing partition data; gunzip exits 2 ("trailing
	# garbage") even though the image itself was fully extracted.
	gunzip -k "${IMG_GZ}" 2>/dev/null || true
	[ -f "${IMG_RAW}" ] || die "decompression failed (no output file)"
fi

# fresh overlay so every run starts from a clean base image
qemu-img create -q -f qcow2 -b "${IMG_RAW}" -F raw "${IMG_OVERLAY}"

# --- tap interface ---

log "setting up tap interface ${TAP_IFACE} (${HOST_TAP_IP} → ${GUEST_IP})"

sudo ip tuntap add dev "${TAP_IFACE}" mode tap 2>/dev/null || true
sudo ip addr flush dev "${TAP_IFACE}" 2>/dev/null || true
sudo ip addr add "${HOST_TAP_IP}" dev "${TAP_IFACE}"
sudo ip link set "${TAP_IFACE}" up

# --- start QEMU ---

QEMU_PID_FILE="${WORK_DIR}/qemu.pid"

if [ -f "${QEMU_PID_FILE}" ]; then
	old_pid="$(cat "${QEMU_PID_FILE}")"
	kill "${old_pid}" 2>/dev/null || true
	# wait up to 10s for the old process to release the image lock
	_w=0
	while kill -0 "${old_pid}" 2>/dev/null && [ "${_w}" -lt 10 ]; do
		sleep 1; _w=$((_w + 1))
	done
	rm -f "${QEMU_PID_FILE}"
fi

qemu-system-x86_64 \
	-enable-kvm \
	-machine q35 \
	-cpu host \
	-m 256 \
	-display none \
	-serial file:"${WORK_DIR}/serial.log" \
	-drive if=virtio,file="${IMG_OVERLAY}",format=qcow2 \
	-netdev tap,id=net0,ifname="${TAP_IFACE}",script=no,downscript=no \
	-device virtio-net-pci,netdev=net0 \
	>"${WORK_DIR}/qemu.log" 2>&1 &

printf "%s" "$!" >"${QEMU_PID_FILE}"
log "QEMU started (pid $(cat "${QEMU_PID_FILE}")), waiting for SSH at ${GUEST_IP}..."

# --- wait for SSH ---

elapsed=0
while [ "${elapsed}" -lt "${BOOT_TIMEOUT}" ]; do
	if ${VM_SSH} true 2>/dev/null; then
		break
	fi
	sleep 5
	elapsed=$((elapsed + 5))
done

[ "${elapsed}" -lt "${BOOT_TIMEOUT}" ] || \
	die "VM SSH at ${GUEST_IP} did not become ready after ${BOOT_TIMEOUT}s — check ${WORK_DIR}/serial.log"

log "SSH ready after ${elapsed}s"

# --- discover kernel version and feed URLs ---

KERNEL_VER="$(${VM_SSH} "uname -r" 2>/dev/null)"
[ -n "${KERNEL_VER}" ] || die "could not read kernel version from guest"

OWRT_VER="$(printf "%s" "${OPENWRT_URL}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "${OWRT_VER}" ] || die "could not parse OpenWrt version from URL"

KMODS_PARENT="https://downloads.openwrt.org/releases/${OWRT_VER}/targets/x86/64/kmods"
KERNEL_DIR="$(curl -s "${KMODS_PARENT}/" | grep -o '"[0-9][^"]*/"' | tr -d '"/' | head -1)"
[ -n "${KERNEL_DIR}" ] || die "could not find kmods directory for OpenWrt ${OWRT_VER}"

KMODS_URL="${KMODS_PARENT}/${KERNEL_DIR}"
PKG_BASE="https://downloads.openwrt.org/releases/${OWRT_VER}/packages/x86_64/base"

PKG_CACHE="${WORK_DIR}/pkg"
mkdir -p "${PKG_CACHE}"

# helper: download .ipk on host (cached) and pipe data.tar.gz into guest root
_install_ipk() {
	local url="$1"
	local cached="${PKG_CACHE}/$(basename "${url}")"
	[ -f "${cached}" ] || curl -fsSL -o "${cached}" "${url}"
	tar -xzf "${cached}" ./data.tar.gz -O 2>/dev/null | \
		${VM_SSH} "cd / && tar -xzf -" 2>/dev/null
}

# discover package filename in a feed directory listing
_find_pkg() {
	local url="$1" pattern="$2"
	curl -s "${url}/" | grep -o "\"${pattern}[^\"]*\"" | tr -d '"' | head -1
}

# --- install kernel modules ---
# mac80211_hwsim and its deps are not in the base x86_64 image.
# Download from the versioned kmods feed; install via insmod (not opkg — opkg
# requires 'opkg update' to populate package hashes, which needs guest internet
# access; the guest firewall blocks outbound TCP in this test setup).

log "installing kmod packages (kernel ${KERNEL_VER})"

for mod in cfg80211 mac80211 mac80211-hwsim; do
	pkg="$(_find_pkg "${KMODS_URL}" "kmod-${mod}_")"
	[ -n "${pkg}" ] || die "kmod-${mod} not found in ${KMODS_URL}"
	_install_ipk "${KMODS_URL}/${pkg}"
done

log "loading mac80211_hwsim in guest"
${VM_SSH} "
	insmod /lib/modules/${KERNEL_VER}/compat.ko 2>/dev/null || true
	insmod /lib/modules/${KERNEL_VER}/cfg80211.ko
	insmod /lib/modules/${KERNEL_VER}/mac80211.ko
	insmod /lib/modules/${KERNEL_VER}/mac80211_hwsim.ko radios=${HWSIM_RADIOS}
" || die "kmod insmod failed in guest"

${VM_SSH} "ls /sys/class/ieee80211/" 2>/dev/null | grep -q "phy" \
	|| die "no ieee80211 PHYs visible after hwsim load"

log "mac80211_hwsim loaded (${HWSIM_RADIOS} radios)"

# --- install wireless userland packages ---
# The x86_64 generic image has no wireless userland (no wpad, iw, wifi-scripts).
# Install by piping .ipk data archives into the guest — same technique as above.

log "installing wireless userland packages"
# wifi-scripts is intentionally NOT installed from the packages feed.
# The feed version overwrites /lib/netifd/netifd-wireless.sh with a variant
# that calls drv_*_init_vlan_config / drv_*_init_station_config — functions
# defined only in a newer mac80211.sh. The base image ships a matching pair;
# installing the feed wifi-scripts alone breaks mac80211.sh silently and
# wifi up returns {} with no errors logged.

for mod_pat in \
	"iw_" \
	"iwinfo_" \
	"libiwinfo20[0-9]" \
	"wireless-regdb_" \
	"hostapd-common_" \
	"libmbedtls21" \
	"ucode-mod-nl80211_" \
	"ucode-mod-rtnl_" \
	"ucode-mod-ubus_" \
	"ucode-mod-uci_" \
	"wpad-basic-mbedtls_"; do
	pkg="$(_find_pkg "${PKG_BASE}" "${mod_pat}")"
	[ -n "${pkg}" ] || die "package matching '${mod_pat}' not found in ${PKG_BASE}"
	_install_ipk "${PKG_BASE}/${pkg}"
done

# --- start wireless global daemons (hostapd + wpa_supplicant) ---
# ujail sandboxes both wpa_supplicant and hostapd under wpad, but ujail's root
# mount in the QEMU environment blocks ubus socket access → neither daemon
# registers on ubus → netifd cannot configure either radio.
# Fix: stop wpad via procd (prevents automatic restart), kill any surviving
# jailed processes, then start both daemons directly without ujail.

log "starting wpad and then replacing with direct daemons (ujail QEMU workaround)"
${VM_SSH} "/etc/init.d/wpad stop 2>/dev/null; sleep 2" 2>/dev/null || true
${VM_SSH} "
	for pid in \$(ps | awk '/usr.sbin.wpa_supplicant/{print \$1}'); do kill \"\${pid}\"; done 2>/dev/null || true
	for pid in \$(ps | awk '/usr.sbin.hostapd/{print \$1}'); do kill \"\${pid}\"; done 2>/dev/null || true
	sleep 1
	mkdir -p /var/run/wpa_supplicant /var/run/hostapd
	/usr/sbin/hostapd -B -s -g /var/run/hostapd/global
	/usr/sbin/wpa_supplicant -B -n -s -g /var/run/wpa_supplicant/global
" 2>/dev/null

# wait for both to register on ubus
elapsed=0
while [ "${elapsed}" -lt 30 ]; do
	if ${VM_SSH} "ubus list | grep -q wpa_supplicant && ubus list | grep -q hostapd" 2>/dev/null; then
		break
	fi
	sleep 2
	elapsed=$((elapsed + 2))
done
[ "${elapsed}" -lt 30 ] || die "hostapd/wpa_supplicant did not register on ubus after 30s"
log "hostapd and wpa_supplicant registered on ubus"

printf "%s\n" "${GUEST_IP}"
