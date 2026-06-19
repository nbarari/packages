# shellcheck shell=bash
# Common bootstrap for travelmate Tier-1 unit tests.
#
# Loads bats-support/bats-assert and the device-command mocks, and provides
# load_functions(): source travelmate-functions.sh with its source-time side
# effects (PATH reset, hardcoded /var/run mkdir) neutralised, then install the
# library-function overrides the mocks depend on.
#
# See docs/decisions/2026-06-19-track5-tier1-bats-harness.md (in the travelmate
# docs repo) for why mocks are shell functions and what Tier-1 does NOT cover.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILES_DIR="$(cd "${TESTS_DIR}/../../files" && pwd)"
FUNCLIB="${PKG_FILES_DIR}/travelmate-functions.sh"

load "${TESTS_DIR}/bats-support/load"
load "${TESTS_DIR}/bats-assert/load"
load "${TESTS_DIR}/helpers/mock-uci"
load "${TESTS_DIR}/helpers/mock-ubus"
load "${TESTS_DIR}/helpers/mock-cmd"

# Source the function library under test in an isolated, sandbox-safe way.
# Marker that begins the library's source-time init tail (util resolution,
# /lib/*.sh sourcing, f_system). Everything before it is function definitions.
LIB_INIT_MARKER='# reference required system utilities'

load_functions() {
	local saved_path="${PATH}"
	local trimmed="${BATS_TEST_TMPDIR}/funclib.defs.sh"

	# The library's tail (from LIB_INIT_MARKER to EOF) resolves device utilities
	# via f_cmd, sources /lib/*.sh, and runs f_system — all of which assume a real
	# OpenWrt host and abort on a CI runner. Source ONLY the function-definition
	# region; we set the trm_*cmd vars ourselves below. Fail loudly if a rebase
	# ever moves the marker (so we never silently truncate real code).
	grep -qF "${LIB_INIT_MARKER}" "${FUNCLIB}" ||
		fail "LIB_INIT_MARKER not found in ${FUNCLIB} — library layout changed"
	awk -v m="${LIB_INIT_MARKER}" 'index($0, m) { exit } { print }' "${FUNCLIB}" >"${trimmed}"

	# The trimmed region still `mkdir -p`s the hardcoded /var/run/travelmate at
	# source time, which EPERM-fails on a non-root runner. Shadow mkdir as a no-op
	# across the source, then drop the shadow for the real sandbox mkdir below.
	mkdir() { :; }
	# shellcheck disable=SC1090
	. "${trimmed}"
	unset -f mkdir

	# The library re-exports a device PATH at source time; restore the runner's
	# PATH so its tools (awk, printf, the bats internals) stay reachable.
	PATH="${saved_path}"

	# trm_rundir is hardcoded to /var/run/travelmate inside the library, so it can
	# only be redirected AFTER sourcing. Repoint it (and every derived path) into
	# the per-test sandbox so nothing tested writes outside BATS_TEST_TMPDIR.
	trm_rundir="${BATS_TEST_TMPDIR}/run"
	trm_ntplock="${trm_rundir}/travelmate.ntp.lock"
	trm_vpnfile="${trm_rundir}/travelmate.vpn"
	trm_mailfile="${trm_rundir}/travelmate.mail"
	trm_refreshfile="${trm_rundir}/travelmate.refresh"
	trm_pidfile="${trm_rundir}/travelmate.pid"
	trm_scanfile="${trm_rundir}/travelmate.scan"
	trm_tmpfile="${trm_rundir}/travelmate.tmp"
	trm_rtfile="${trm_rundir}/travelmate.runtime.json"
	trm_rebindfile="${trm_rundir}/travelmate.rebind"
	mkdir -p "${trm_rundir}"

	# The init tail we skipped normally resolves these via f_cmd. Point the pure
	# utilities at the real host tools and the device-I/O ones at mocks. Tests
	# override trm_ubuscmd/trm_jsoncmd as needed after calling load_functions.
	trm_catcmd="cat"
	trm_awkcmd="awk"
	trm_sortcmd="sort"
	trm_pgrepcmd="pgrep"
	trm_killcmd="kill"
	trm_jsoncmd="json_stub"
	trm_ubuscmd="ubus_stub"
	trm_logcmd="true"
	trm_wificmd="true"
	trm_fetchcmd="true"
	trm_ifstatuscmd="true"
	trm_ipcalccmd="true"
	trm_lookupcmd="true"
	trm_mailcmd="true"

	# Override library functions that reach the device or terminate the process.
	# These must be (re)defined AFTER sourcing, or the real definitions win.
	_install_lib_overrides
}

# Reset all mock state. Call from setup() before load_functions.
mocks_reset() {
	uci_reset
	ubus_reset
	cmd_reset
}

# Invoke a library function in the CURRENT shell, capturing stdout/stderr/status
# into the $output/$stderr/$status vars that bats-assert reads. Unlike bats `run`
# or $(...), this does not fork a subshell, so the mocks' side-effect state
# (UCI_CHANGES, TRM_WIFI_CALLS, ...) survives for post-call assertions.
call() {
	# The production shell (busybox ash) runs the library without errexit; mirror
	# that so a function's internal `[ ... ] && ...` returning false (a normal
	# control-flow idiom in this codebase) doesn't abort the call under bats.
	set +e
	"$@" >"${BATS_TEST_TMPDIR}/stdout" 2>"${BATS_TEST_TMPDIR}/stderr"
	status="$?"
	output="$(cat "${BATS_TEST_TMPDIR}/stdout")"
	stderr="$(cat "${BATS_TEST_TMPDIR}/stderr")"
}
