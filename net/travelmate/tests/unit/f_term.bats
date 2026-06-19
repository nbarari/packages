#!/usr/bin/env bats
# Unit tests for f_term — the SIGTERM clean-shutdown handler.
#
# Calibration (finding 2.5): f_term is fork-authored — upstream has no TERM trap
# and relies on procd's grace-period SIGKILL, leaving the runtime/pid files stale.
# The fork unwinds cooperatively: truncate the runtime + pid files and exit 0.
# f_term calls exit, so invoke via `run` (subshell); the file truncations land on
# disk in the sandbox and are visible to the parent shell afterwards.

load test_helper

setup() {
	mocks_reset
	load_functions
}

@test "f_term truncates the runtime and pid files and exits 0" {
	printf 'stale-runtime-json' >"${trm_rtfile}"
	printf '12345' >"${trm_pidfile}"

	run f_term
	assert_success
	[ -f "${trm_rtfile}" ] && [ ! -s "${trm_rtfile}" ]
	[ -f "${trm_pidfile}" ] && [ ! -s "${trm_pidfile}" ]
}

@test "f_term is safe when the files do not yet exist" {
	rm -f "${trm_rtfile}" "${trm_pidfile}"

	run f_term
	assert_success
	[ -f "${trm_rtfile}" ] && [ ! -s "${trm_rtfile}" ]
	[ -f "${trm_pidfile}" ] && [ ! -s "${trm_pidfile}" ]
}
