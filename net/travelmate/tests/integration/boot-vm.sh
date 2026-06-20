#!/bin/sh
# tests/integration/boot-vm.sh — boot an OpenWrt x86_64 VM under QEMU with KVM,
# load mac80211_hwsim in the guest, and signal readiness.
#
# Usage: boot-vm.sh [options]
#   --image  URL_OR_PATH   OpenWrt x86_64 combined-ext4.img.gz (URL or local path)
#   --port   N             host port forwarded to guest SSH (default: 2222)
#   --work-dir DIR         state dir for image/overlay/pid (default: /tmp/trm-tier2)
#   --radios N             mac80211_hwsim radio count (default: 6)
#
# On success: prints the SSH port to stdout; QEMU PID written to ${WORK_DIR}/qemu.pid.
# On failure: exits non-zero with a message on stderr.

set -e

OPENWRT_URL="https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/openwrt-24.10.2-x86-64-combined-ext4.img.gz"
SSH_PORT=2222
WORK_DIR="/tmp/trm-tier2"
HWSIM_RADIOS=6
BOOT_TIMEOUT=120

die() { printf "boot-vm: ERROR: %s\n" "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--image)    OPENWRT_URL="$2";  shift 2 ;;
		--port)     SSH_PORT="$2";     shift 2 ;;
		--work-dir) WORK_DIR="$2";     shift 2 ;;
		--radios)   HWSIM_RADIOS="$2"; shift 2 ;;
		*) die "unknown option: $1" ;;
	esac
done

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found"
command -v qemu-img            >/dev/null 2>&1 || die "qemu-img not found"

SSH_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p ${SSH_PORT}"
VM_SSH="ssh ${SSH_OPTS} root@127.0.0.1"

mkdir -p "${WORK_DIR}"

# --- prepare base image ---

IMG_GZ="${WORK_DIR}/openwrt.img.gz"
IMG_RAW="${WORK_DIR}/openwrt.img"
IMG_OVERLAY="${WORK_DIR}/run.qcow2"

if [ ! -f "${IMG_RAW}" ]; then
	if [ -f "${OPENWRT_URL}" ]; then
		cp "${OPENWRT_URL}" "${IMG_GZ}"
	else
		printf "boot-vm: downloading %s\n" "${OPENWRT_URL}" >&2
		curl -fSL --progress-bar -o "${IMG_GZ}" "${OPENWRT_URL}"
	fi
	gunzip -k "${IMG_GZ}"
fi

# fresh overlay on every run so the base image stays clean
qemu-img create -q -f qcow2 -b "${IMG_RAW}" -F raw "${IMG_OVERLAY}"

# --- start QEMU ---

QEMU_PID_FILE="${WORK_DIR}/qemu.pid"

if [ -f "${QEMU_PID_FILE}" ]; then
	old_pid="$(cat "${QEMU_PID_FILE}")"
	kill "${old_pid}" 2>/dev/null || true
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
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
	-device virtio-net-pci,netdev=net0 \
	>"${WORK_DIR}/qemu.log" 2>&1 &

printf "%s" "$!" >"${QEMU_PID_FILE}"
printf "boot-vm: QEMU started (pid %s), waiting for SSH on :%s...\n" \
	"$(cat "${QEMU_PID_FILE}")" "${SSH_PORT}" >&2

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
	die "VM SSH did not become ready after ${BOOT_TIMEOUT}s — check ${WORK_DIR}/serial.log"

printf "boot-vm: SSH ready after %ss\n" "${elapsed}" >&2

# --- load mac80211_hwsim in the guest ---

${VM_SSH} "modprobe mac80211_hwsim radios=${HWSIM_RADIOS}" 2>/dev/null \
	|| die "modprobe mac80211_hwsim failed in guest"

${VM_SSH} "ls /sys/class/ieee80211/" 2>/dev/null | grep -q "phy" \
	|| die "no ieee80211 PHYs visible after hwsim load"

printf "boot-vm: mac80211_hwsim loaded (%s radios)\n" "${HWSIM_RADIOS}" >&2
printf "%s\n" "${SSH_PORT}"
