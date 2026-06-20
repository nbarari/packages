#!/bin/sh
# tests/integration/runner.sh — Tier-2 travelmate integration test runner.
#
# Boots OpenWrt x86_64 in QEMU via boot-vm.sh, installs travelmate, configures
# a two-radio mac80211_hwsim environment, runs a scenario, and asserts the
# expected runtime.json output.
#
# Usage: runner.sh <apk-path> [scenario-file]
#   apk-path:      built travelmate .apk (required unless TRAVELMATE_VARIANT=upstream)
#   scenario-file: path to scenario YAML (default: scenarios/happy.yml)
#
# Environment:
#   TRAVELMATE_VARIANT  'fork' (default) or 'upstream'
#                       upstream = install from apk repo (calibration run per roadmap)
#   OPENWRT_IMAGE       local path or URL for OpenWrt x86_64 img.gz (passed to boot-vm.sh)
#   SSH_PORT            host port forwarded to VM SSH (default: 2222)
#   WORK_DIR            temp dir for VM state (default: /tmp/trm-tier2)
#   KEEP_VM             '1' to leave VM running after test (default: 0)

set -e

INTEGRATION_DIR="$(cd "$(dirname "$0")" && pwd)"
APK_PATH="${1:-}"
SCENARIO="${2:-${INTEGRATION_DIR}/scenarios/happy.yml}"
TRAVELMATE_VARIANT="${TRAVELMATE_VARIANT:-fork}"
SSH_PORT="${SSH_PORT:-2222}"
WORK_DIR="${WORK_DIR:-/tmp/trm-tier2}"
KEEP_VM="${KEEP_VM:-0}"
CONNECT_TIMEOUT=120

die()  { printf "runner: FAIL: %s\n" "$*" >&2; exit 1; }
log()  { printf "runner: %s\n" "$*" >&2; }
pass() { printf "runner: PASS: %s\n" "$*"; }

[ -f "${SCENARIO}" ] || die "scenario file not found: ${SCENARIO}"

if [ "${TRAVELMATE_VARIANT}" = "fork" ]; then
	[ -n "${APK_PATH}" ] || die "apk-path required (or set TRAVELMATE_VARIANT=upstream)"
	[ -f "${APK_PATH}" ] || die "apk not found: ${APK_PATH}"
fi

# --- parse scenario (flat YAML: lines of the form 'key: value') ---

_val() { grep -m1 "^${1}:" "${SCENARIO}" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'; }

AP_SSID="$(_val ap_ssid)"
AP_PSK="$(_val ap_psk)"
AP_CHANNEL="$(_val ap_channel)"
AP_ENCRYPTION="$(_val ap_encryption)"
ASSERT_STATUS="$(_val assert_status_contains)"
ASSERT_ESSID="$(_val assert_station_essid)"

[ -n "${AP_SSID}" ] || die "scenario missing ap_ssid"
[ -n "${AP_PSK}"  ] || die "scenario missing ap_psk"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_ENCRYPTION="${AP_ENCRYPTION:-psk2}"
ASSERT_STATUS="${ASSERT_STATUS:-connected}"

# --- SSH/SCP helpers ---

SSH_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=10 -p ${SSH_PORT}"
SCP_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-P ${SSH_PORT}"

_ssh() { ssh ${SSH_OPTS} root@127.0.0.1 "$@"; }
_scp() { scp ${SCP_OPTS} "$@"; }

# --- cleanup on exit ---

cleanup() {
	[ "${KEEP_VM}" = "1" ] && return
	if [ -f "${WORK_DIR}/qemu.pid" ]; then
		pid="$(cat "${WORK_DIR}/qemu.pid")"
		log "stopping VM (pid ${pid})"
		kill "${pid}" 2>/dev/null || true
		rm -f "${WORK_DIR}/qemu.pid"
	fi
}
trap cleanup EXIT INT TERM

# --- boot ---

boot_args="--port ${SSH_PORT} --work-dir ${WORK_DIR}"
[ -n "${OPENWRT_IMAGE:-}" ] && boot_args="${boot_args} --image ${OPENWRT_IMAGE}"
"${INTEGRATION_DIR}/boot-vm.sh" ${boot_args} >/dev/null
log "VM ready"

# --- discover PHY device paths (host-side, expanded before SSH) ---

PHY0_PATH="$(_ssh "readlink -f /sys/class/ieee80211/phy0/device" | sed 's|/sys/devices/||')"
PHY1_PATH="$(_ssh "readlink -f /sys/class/ieee80211/phy1/device" | sed 's|/sys/devices/||')"
[ -n "${PHY0_PATH}" ] || die "could not read phy0 sysfs path"
[ -n "${PHY1_PATH}" ] || die "could not read phy1 sysfs path"
log "phy0=${PHY0_PATH}  phy1=${PHY1_PATH}"

# --- write wireless config ---
# Variables are expanded here (host shell) then the resulting string is
# piped to the guest's cat. No double-expansion risk.

wireless_cfg=$(cat <<EOF
config wifi-device 'radio0'
	option type 'mac80211'
	option path '${PHY0_PATH}'
	option channel '${AP_CHANNEL}'
	option hwmode '11g'
	option disabled '0'

config wifi-iface 'sta0'
	option device 'radio0'
	option mode 'sta'
	option network 'trm_wwan'
	option ssid '${AP_SSID}'
	option encryption '${AP_ENCRYPTION}'
	option key '${AP_PSK}'
	option disabled '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option path '${PHY1_PATH}'
	option channel '${AP_CHANNEL}'
	option hwmode '11g'
	option disabled '0'

config wifi-iface 'ap1'
	option device 'radio1'
	option mode 'ap'
	option network 'lan'
	option ssid '${AP_SSID}'
	option encryption '${AP_ENCRYPTION}'
	option key '${AP_PSK}'
EOF
)
printf "%s\n" "${wireless_cfg}" | _ssh "cat > /etc/config/wireless"

# add the trm_wwan DHCP interface for the STA's network
_ssh "uci -q set network.trm_wwan=interface; \
      uci -q set network.trm_wwan.proto=dhcp; \
      uci commit network"

# --- write travelmate config ---
# uplink section: device+ssid match the sta0 wifi-iface (f_getcfg key).
# The key lives in wireless config; travelmate uplink carries enabled=1.

trm_cfg=$(cat <<EOF
config travelmate 'global'
	option trm_enabled '1'
	option trm_iface 'trm_wwan'
	option trm_captive '0'
	option trm_proactive '0'
	option trm_netcheck '0'
	option trm_autoadd '0'
	option trm_randomize '0'
	option trm_eviltwin '0'
	option trm_maxwait '30'
	option trm_timeout '60'

config uplink
	option device 'radio0'
	option ssid '${AP_SSID}'
	option enabled '1'
EOF
)
printf "%s\n" "${trm_cfg}" | _ssh "cat > /etc/config/travelmate"

# --- install travelmate ---

if [ "${TRAVELMATE_VARIANT}" = "upstream" ]; then
	log "installing travelmate from upstream apk repo (calibration run)"
	_ssh "apk update && apk add travelmate" \
		|| die "upstream travelmate install failed"
else
	log "installing fork travelmate from ${APK_PATH}"
	_scp "${APK_PATH}" "root@127.0.0.1:/tmp/travelmate.apk"
	_ssh "apk add --allow-untrusted /tmp/travelmate.apk" \
		|| die "apk install failed"
fi

# --- bring up AP and STA, start travelmate ---

log "starting wifi"
_ssh "wifi up"

log "starting travelmate"
_ssh "/etc/init.d/travelmate start"

# --- poll runtime.json ---

RT_FILE="/var/run/travelmate/travelmate.runtime.json"
log "waiting up to ${CONNECT_TIMEOUT}s for '${ASSERT_STATUS}' in travelmate_status..."

status_val=""
elapsed=0
while [ "${elapsed}" -lt "${CONNECT_TIMEOUT}" ]; do
	rt_json="$(_ssh "cat ${RT_FILE}" 2>/dev/null)" || rt_json=""
	if [ -n "${rt_json}" ]; then
		status_val="$(printf "%s" "${rt_json}" | \
			grep -o '"travelmate_status":"[^"]*"' | cut -d'"' -f4)"
		if printf "%s" "${status_val}" | grep -q "${ASSERT_STATUS}"; then
			break
		fi
	fi
	sleep 5
	elapsed=$((elapsed + 5))
done

[ "${elapsed}" -lt "${CONNECT_TIMEOUT}" ] \
	|| die "travelmate did not reach '${ASSERT_STATUS}' after ${CONNECT_TIMEOUT}s (last: '${status_val:-none}')"

# --- assert ---

pass "travelmate_status='${status_val}'"

if [ -n "${ASSERT_ESSID}" ]; then
	actual_essid="$(printf "%s" "${rt_json}" | \
		grep -o '"essid":"[^"]*"' | cut -d'"' -f4)"
	[ "${actual_essid}" = "${ASSERT_ESSID}" ] \
		|| die "station.essid: expected '${ASSERT_ESSID}', got '${actual_essid}'"
	pass "station.essid='${actual_essid}'"
fi

pass "scenario=$(basename "${SCENARIO}" .yml)"
