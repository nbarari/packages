#!/usr/bin/env bats
# Unit tests for f_log and f_log_fatal — the logging contract split (finding 2.1).
#
# Calibration (finding 2.1): upstream f_log exits on class "err" or "emerg" —
# logging and process termination lived in one function. The fork splits them:
# f_log is now pure logging (never exits for any class); f_log_fatal logs, then
# marks status="error" and exits 1. These tests pass on the fork and would FAIL
# on upstream (upstream's f_log "err" exits).
#
# Setup: load_functions installs mock overrides that replace f_log/f_log_fatal
# with no-exit stubs so that callers can be tested without killing the runner.
# For tests of these functions themselves we reinstall the real implementations
# via awk extraction from the source library. trm_logcmd is already "true" (a
# no-op logger), so the real f_log falls through to printf-to-stderr — not an
# error, just silent in bats output.

load test_helper

setup() {
	mocks_reset
	load_functions
	# Reinstall real f_log and f_log_fatal from the source library.
	# awk range: function header to the first standalone '}' (the closing brace).
	eval "$(awk '/^f_log\(\) \{/,/^\}$/' "${FUNCLIB}")"
	eval "$(awk '/^f_log_fatal\(\) \{/,/^\}$/' "${FUNCLIB}")"
}

@test "f_log does not exit on class 'err' (calibration: upstream exits)" {
	# On upstream, f_log "err" / "emerg" terminates via exit 1.
	# On the fork, f_log is pure logging and returns 0 for any class.
	run f_log "err" "something went wrong"
	assert_success
}

@test "f_log_fatal exits with code 1" {
	run f_log_fatal "emerg" "fatal: missing interface"
	assert_failure
	[ "${status}" -eq 1 ]
}

@test "f_log_fatal truncates the pid file" {
	printf '99999' >"${trm_pidfile}"

	run f_log_fatal "emerg" "fatal"
	# Truncation happens inside the subshell but lands on the shared filesystem.
	[ -f "${trm_pidfile}" ] && [ ! -s "${trm_pidfile}" ]
}
