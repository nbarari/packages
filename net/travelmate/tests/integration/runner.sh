#!/bin/sh
# tests/integration/runner.sh — Tier-2 travelmate integration test runner.
#
# Boots OpenWrt x86_64 in QEMU via boot-vm.sh (tap networking), installs
# travelmate from source, configures a two-radio mac80211_hwsim environment,
# runs the scenario, and asserts the expected runtime.json output.
#
# Usage: runner.sh [scenario-file]
#   scenario-file: path to scenario YAML (default: scenarios/happy.yml)
#
# Environment:
#   TRAVELMATE_VARIANT  'fork' (default) — installs from source files relative
#                       to this script. 'upstream' requires guest internet
#                       access (deferred to Tier-2 increment-2).
#   OPENWRT_IMAGE       local path or URL for OpenWrt x86_64 img.gz
#   GUEST_IP            OpenWrt LAN IP (default: 192.168.1.1)
#   TAP_IFACE           tap interface name (default: trmtap0)
#   HOST_TAP_IP         host tap address (default: 192.168.1.100/24)
#   WORK_DIR            temp dir for VM state (default: /tmp/trm-tier2)
#   KEEP_VM             '1' to leave VM running after test (default: 0)
#   CONNECT_TIMEOUT     seconds to wait for STA to connect (default: 120)
#
# Design notes:
#   - Travelmate is installed by copying source files directly (no package
#     manager), so the fork variant works without building an .apk.
#   - Wireless config uses 'option phy phyN' (not 'option path ...') because
#     iwinfo's phyname lookup cannot resolve mac80211_hwsim's virtual device
#     path, which causes mac80211.sh to fail to find the PHY.
#   - See boot-vm.sh header for additional QEMU + wireless setup notes.

set -e

INTEGRATION_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="${1:-${INTEGRATION_DIR}/scenarios/happy.yml}"
TRAVELMATE_VARIANT="${TRAVELMATE_VARIANT:-fork}"
GUEST_IP="${GUEST_IP:-192.168.1.1}"
TAP_IFACE="${TAP_IFACE:-trmtap0}"
HOST_TAP_IP="${HOST_TAP_IP:-192.168.1.100/24}"
WORK_DIR="${WORK_DIR:-/tmp/trm-tier2}"
KEEP_VM="${KEEP_VM:-0}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-120}"

die()  { printf "runner: FAIL: %s\n" "$*" >&2; exit 1; }
log()  { printf "runner: %s\n" "$*" >&2; }
pass() { printf "runner: PASS: %s\n" "$*"; }

[ -f "${SCENARIO}" ] || die "scenario file not found: ${SCENARIO}"

# --- parse scenario (flat YAML: 'key: value' lines) ---

_val() { grep -m1 "^${1}:" "${SCENARIO}" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'; }

AP_SSID="$(_val ap_ssid)"
AP_PSK="$(_val ap_psk)"
AP_CHANNEL="$(_val ap_channel)"
AP_ENCRYPTION="$(_val ap_encryption)"
CAPTIVE_MODE="$(_val captive_mode)"
ASSERT_STATUS="$(_val assert_status_contains)"
ASSERT_ESSID="$(_val assert_station_essid)"

[ -n "${AP_SSID}" ] || die "scenario missing ap_ssid"
[ -n "${AP_PSK}"  ] || die "scenario missing ap_psk"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_ENCRYPTION="${AP_ENCRYPTION:-psk2}"
ASSERT_STATUS="${ASSERT_STATUS:-connected}"

# Captive mode state (set below if captive_mode is configured)
TRM_CAPTIVE="0"
TRM_CAPTIVEURL=""

# --- SSH helpers (direct to guest via tap; no port forwarding) ---

SSH_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

_ssh() { ssh ${SSH_OPTS} root@"${GUEST_IP}" "$@"; }

# --- cleanup on exit ---

cleanup() {
	if [ "${KEEP_VM}" != "1" ]; then
		if [ -f "${WORK_DIR}/qemu.pid" ]; then
			pid="$(cat "${WORK_DIR}/qemu.pid")"
			log "stopping VM (pid ${pid})"
			kill "${pid}" 2>/dev/null || true
			rm -f "${WORK_DIR}/qemu.pid"
		fi
		log "removing tap interface ${TAP_IFACE}"
		sudo ip link set "${TAP_IFACE}" down 2>/dev/null || true
		sudo ip tuntap del dev "${TAP_IFACE}" mode tap 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# --- boot ---

log "booting OpenWrt VM"
boot_args="--work-dir ${WORK_DIR} --tap ${TAP_IFACE} --guest-ip ${GUEST_IP} --host-ip ${HOST_TAP_IP}"
[ -n "${OPENWRT_IMAGE:-}" ] && boot_args="${boot_args} --image ${OPENWRT_IMAGE}"
"${INTEGRATION_DIR}/boot-vm.sh" ${boot_args} >/dev/null
log "VM ready at ${GUEST_IP}"

# --- write wireless config ---
# Use 'option phy phyN' instead of 'option path virtual/...' — see header.
# Radio 0 = STA (connects to the uplink AP).
# Radio 1 = AP (simulates the target uplink for this scenario).

_ssh "cat > /etc/config/wireless" <<WEOF
config wifi-device 'radio0'
	option type 'mac80211'
	option phy 'phy0'
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
	option phy 'phy1'
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
WEOF

# --- write network and travelmate config ---

_ssh "uci -q set network.trm_wwan=interface; \
      uci -q set network.trm_wwan.proto=dhcp; \
      uci commit network"

_ssh "cat > /etc/config/travelmate" <<TEOF
config travelmate 'global'
	option trm_enabled '1'
	option trm_iface 'trm_wwan'
	option trm_captive '${TRM_CAPTIVE}'
	option trm_captiveurl '${TRM_CAPTIVEURL}'
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
TEOF

# --- bring up wireless stack ---
# Restart netifd so it reads the wireless config we just wrote. A simple
# 'wifi up' / 'network reload' (SIGHUP) is insufficient: netifd initialises
# its wireless device list once at startup. Config written after that point is
# not picked up by reload alone — a full restart is required.
#
# 'network restart' kills the SSH session briefly (br-lan reconfigures), so
# we run it in the background and reconnect on the next _ssh call after a wait.

log "bringing up wireless stack"
_ssh "/etc/init.d/network restart >/dev/null 2>&1 &" || true
sleep 15

# wait for AP to come up — netifd + mac80211.sh can take 60-90s in QEMU
log "waiting for AP (radio1) to become ready"
elapsed=0
while [ "${elapsed}" -lt 90 ]; do
	ap_up="$(_ssh "ubus call network.wireless status 2>/dev/null" | \
		grep -A3 '"radio1"' | grep '"up"' | head -1 | grep -c 'true')"
	[ "${ap_up}" = "1" ] && break
	sleep 5
	elapsed=$((elapsed + 5))
done
[ "${elapsed}" -lt 90 ] || die "radio1 AP did not come up after 90s"
log "radio1 AP is up"

# wait for STA to associate
log "waiting up to ${CONNECT_TIMEOUT}s for STA (radio0) to associate..."
elapsed=0
while [ "${elapsed}" -lt "${CONNECT_TIMEOUT}" ]; do
	sta_link="$(_ssh "iw dev phy0-sta0 link 2>/dev/null" | grep -c 'Connected')"
	[ "${sta_link}" = "1" ] && break
	sleep 5
	elapsed=$((elapsed + 5))
done
[ "${elapsed}" -lt "${CONNECT_TIMEOUT}" ] \
	|| die "STA (phy0-sta0) did not associate after ${CONNECT_TIMEOUT}s"
log "STA associated after ${elapsed}s"

# wait for trm_wwan to get an IP
elapsed=0
while [ "${elapsed}" -lt 30 ]; do
	trm_up="$(_ssh "ubus call network.interface.trm_wwan status 2>/dev/null" | \
		grep '"up"' | grep -c 'true')"
	[ "${trm_up}" = "1" ] && break
	sleep 3
	elapsed=$((elapsed + 3))
done
[ "${elapsed}" -lt 30 ] || die "trm_wwan interface did not get an IP after 30s"
log "trm_wwan is up"

# --- captive portal simulator setup ---
# Must run before travelmate starts so the sim is listening when f_check probes.

if [ -n "${CAPTIVE_MODE}" ]; then
	case "${CAPTIVE_MODE}" in
	meta-refresh)
		log "starting busybox httpd captive sim (meta-refresh) on guest:8080"
		_ssh "mkdir -p /tmp/captive-www && \
			printf '<html><head><meta http-equiv=\"refresh\" content=\"0;url=http://captive.example.com/login\"></head></html>\n' \
				>/tmp/captive-www/index.html && \
			busybox httpd -p 8080 -h /tmp/captive-www"
		# Resolve the probe hostname to the router's LAN IP (192.168.1.1) so
		# curl --interface trm_wwan reaches the httpd via the wireless STA path.
		_ssh "printf '192.168.1.1 trm-captive.test\n' >>/etc/hosts"
		TRM_CAPTIVE="1"
		TRM_CAPTIVEURL="http://trm-captive.test:8080"
		# brief wait for httpd to bind
		sleep 2
		_ssh "curl -sf http://127.0.0.1:8080/ | grep -q 'meta http-equiv'" \
			|| die "captive-sim httpd did not start (meta-refresh)"
		log "captive-sim ready at ${TRM_CAPTIVEURL}"
		;;
	*)
		die "unsupported captive_mode '${CAPTIVE_MODE}' — implement in runner.sh first"
		;;
	esac
fi

# --- install travelmate ---

if [ "${TRAVELMATE_VARIANT}" = "upstream" ]; then
	log "upstream calibration requires guest internet access (deferred to increment-2)"
	die "upstream variant not yet supported — rerun with TRAVELMATE_VARIANT=fork"
fi

log "installing fork travelmate from source"

TRM_FILES="${INTEGRATION_DIR}/../../files"
trm_init="${TRM_FILES}/travelmate.init"
trm_svc="${TRM_FILES}/travelmate-service.sh"
trm_lib="${TRM_FILES}/travelmate-functions.sh"

[ -f "${trm_init}" ] || die "travelmate.init not found: ${trm_init}"
[ -f "${trm_svc}"  ] || die "travelmate-service.sh not found: ${trm_svc}"
[ -f "${trm_lib}"  ] || die "travelmate-functions.sh not found: ${trm_lib}"

cat "${trm_lib}"  | _ssh "cat > /usr/lib/travelmate-functions.sh"
cat "${trm_svc}"  | _ssh "mkdir -p /usr/bin && cat > /usr/bin/travelmate-service.sh && chmod +x /usr/bin/travelmate-service.sh"
cat "${trm_init}" | _ssh "cat > /etc/init.d/travelmate && chmod +x /etc/init.d/travelmate"

_ssh "mkdir -p /etc/travelmate && /etc/init.d/travelmate enable"
log "travelmate installed and enabled"

# --- start travelmate ---

log "starting travelmate"
_ssh "/etc/init.d/travelmate start"

# --- poll runtime.json ---

RT_FILE="/var/run/travelmate/travelmate.runtime.json"
log "waiting up to ${CONNECT_TIMEOUT}s for '${ASSERT_STATUS}' in travelmate_status..."

status_val=""
rt_json=""
elapsed=0
while [ "${elapsed}" -lt "${CONNECT_TIMEOUT}" ]; do
	rt_json="$(_ssh "cat ${RT_FILE}" 2>/dev/null)" || rt_json=""
	if [ -n "${rt_json}" ]; then
		status_val="$(printf "%s" "${rt_json}" | \
			sed -n 's/.*"travelmate_status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
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
		sed -n 's/.*"essid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
	[ "${actual_essid}" = "${ASSERT_ESSID}" ] \
		|| die "station.essid: expected '${ASSERT_ESSID}', got '${actual_essid}'"
	pass "station.essid='${actual_essid}'"
fi

pass "scenario=$(basename "${SCENARIO}" .yml)"
